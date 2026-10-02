import Foundation
// Reads string literals from the site's known data template. Never evaluates JavaScript.
public enum DM5ReaderData {
    static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]), let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in Range(match.range(at: index), in: text).map { String(text[$0]) } ?? "" }
    }
    static let quoted = #"('(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*")"#
    static func literal(_ input: String) throws -> String {
        let chars = Array(input); guard chars.count >= 2, ["'", "\""].contains(chars[0]), chars.first == chars.last else { throw MangaError.parseMismatch("无效字符串") }
        var result = ""; var index = 1
        while index < chars.count - 1 {
            let char = chars[index]; index += 1
            if char != "\\" { result.append(char); continue }
            guard index < chars.count - 1 else { throw MangaError.parseMismatch("字符串截断") }
            let escaped = chars[index]; index += 1
            switch escaped {
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "'", "\"", "\\", "/": result.append(escaped)
            case "x", "u":
                let count = escaped == "x" ? 2 : 4
                guard index + count <= chars.count - 1, let number = UInt32(String(chars[index..<index+count]), radix: 16), let scalar = UnicodeScalar(number) else { throw MangaError.parseMismatch("无效转义") }
                result.unicodeScalars.append(scalar); index += count
            default: throw MangaError.parseMismatch("不支持的字符串转义")
            }
        }
        return result
    }
    static func stringVariable(_ name: String, in text: String) throws -> String? {
        guard let values = captures("\\b" + NSRegularExpression.escapedPattern(for: name) + "\\s*=\\s*" + quoted, in: text) else { return nil }
        return try literal(values[0])
    }
    static func unpack(_ input: String) throws -> String {
        guard input.utf8.count <= 1_000_000 else { throw MangaError.parseMismatch("接口响应过大") }
        guard input.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("eval(function(") else { return input }
        let pattern = #"\}\(\s*"# + quoted + #"\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*"# + quoted + #"\.split\('\|'\)"#
        guard let values = captures(pattern, in: input), let base = Int(values[1]), (2...62).contains(base), let count = Int(values[2]), count <= 10_000 else { throw MangaError.parseMismatch("未知压缩数据格式") }
        var payload = try literal(values[0]); let words = try literal(values[3]).components(separatedBy: "|")
        guard words.count >= count else { throw MangaError.parseMismatch("压缩字典不完整") }
        let digits = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let regex = try NSRegularExpression(pattern: #"\b[0-9A-Za-z]+\b"#)
        for match in regex.matches(in: payload, range: NSRange(payload.startIndex..., in: payload)).reversed() {
            guard let range = Range(match.range, in: payload) else { continue }
            var index = 0; var valid = true
            for char in payload[range] {
                guard let digit = digits.firstIndex(of: char), digit < base, index <= 10_000 else { valid = false; break }
                index = index * base + digit
            }
            if valid, index < words.count, !words[index].isEmpty { payload.replaceSubrange(range, with: words[index]) }
        }
        return payload
    }
    public static func urls(from script: String, base: URL) throws -> [URL] {
        let text = try unpack(script)
        guard text.contains("dm5imagefun"), let prefix = try stringVariable("pix", in: text), let array = captures(#"\bpvalue\s*=\s*\[([^\]]*)\]"#, in: text)?.first,
              let suffixLiteral = captures(#"pvalue\[i\]\s*=\s*pix\s*\+\s*pvalue\[i\]\s*\+\s*"# + quoted, in: text)?.first else { throw MangaError.parseMismatch("未知正文数据模板") }
        let suffix = try literal(suffixLiteral)
        let expression = try NSRegularExpression(pattern: quoted)
        let matches = expression.matches(in: array, range: NSRange(array.startIndex..., in: array))
        var remainder = array
        for match in matches.reversed() { if let range = Range(match.range, in: remainder) { remainder.removeSubrange(range) } }
        guard remainder.allSatisfy({ $0.isWhitespace || $0 == "," }), !matches.isEmpty else { throw MangaError.parseMismatch("正文数组含未知表达式") }
        return try matches.map { match in
            let value = try literal(String(array[Range(match.range, in: array)!]))
            let combined = value.hasPrefix("https://") || value.hasPrefix("http://") || value.hasPrefix("//") ? value : prefix + value + suffix
            guard let url = resolvedWebURL(combined, relativeTo: base) else { throw MangaError.parseMismatch("无效正文地址") }
            return url
        }
    }
}
