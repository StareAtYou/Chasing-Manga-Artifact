import Foundation
public enum ResumeMatcher {
    private static func components(_ title: String) -> (String?, String) {
        let expression = try! NSRegularExpression(pattern: #"(?:第\s*)?(\d+(?:\.\d+)?)\s*[话章回]"#)
        guard let match = expression.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)), let number = Range(match.range(at: 1), in: title), let whole = Range(match.range, in: title) else { return (nil, MangaTitle.normalized(title)) }
        var content = title; content.removeSubrange(whole)
        content = content.replacingOccurrences(of: #"[（(]\s*[上下中]\s*[）)]"#, with: "", options: .regularExpression)
        return (String(title[number]), MangaTitle.normalized(content))
    }
    public static func candidates(progress: ReadingProgress, from old: [Chapter], to new: [Chapter]) -> [ChapterID] {
        guard let previous = old.first(where: { $0.id == progress.chapterID }) else { return [] }
        let (number, title) = components(previous.title)
        return new.filter { chapter in
            let (candidateNumber, candidateTitle) = components(chapter.title)
            if let number { return candidateNumber == number && (title.isEmpty || candidateTitle.isEmpty || title == candidateTitle) }
            return !title.isEmpty && title == candidateTitle
        }.map(\.id)
    }
}
