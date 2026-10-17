import Foundation
import CommonCrypto

// Public reader-format constants shipped in the sites' JavaScript, not account
// credentials. The app never evaluates downloaded JavaScript.
enum CMSReaderData {
    static func decrypt(_ cipher: Data, key: String, iv: Data) throws -> Data {
        let key = Array(key.utf8)
        guard [16,24,32].contains(key.count), iv.count == 16, !cipher.isEmpty,
              cipher.count.isMultiple(of: 16), cipher.count <= 64 * 1024 * 1024 else {
            throw MangaError.parseMismatch("阅读数据格式无效")
        }
        var output = [UInt8](repeating: 0, count: cipher.count + 16)
        var written = 0
        let status = output.withUnsafeMutableBytes { destination in
            key.withUnsafeBytes { key in
                iv.withUnsafeBytes { iv in
                    cipher.withUnsafeBytes { input in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                key.baseAddress, key.count, iv.baseAddress, input.baseAddress, input.count,
                                destination.baseAddress, destination.count, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw MangaError.parseMismatch("阅读数据格式已变化，请重新检测来源") }
        return Data(output.prefix(written))
    }
    static func envelope(html: String, key: String) throws -> [String: Any] {
        guard let literal = try DM5ReaderData.stringVariable("params", in: html), literal.utf8.count <= 12 * 1024 * 1024,
              let data = Data(base64Encoded: literal), data.count > 16 else { throw MangaError.parseMismatch("缺少有效阅读数据") }
        let plain = try decrypt(Data(data.dropFirst(16)), key: key, iv: Data(data.prefix(16)))
        guard let value = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else { throw MangaError.parseMismatch("阅读数据不是有效目录") }
        return value
    }
}

public enum ImageResourceDecoder {
    public static func decode(_ data: Data, request: ResourceRequest) throws -> Data {
        try decode(data, encoding: request.imageEncoding)
    }
    public static func decode(_ data: Data, encoding: ImageEncoding?) throws -> Data {
        guard encoding == .fengcheAES else { return data }
        let key = "my2ecret782ecret"
        do { return try CMSReaderData.decrypt(data, key: key, iv: Data(key.utf8)) }
        catch { throw MangaError.invalidImage }
    }
}
