import Foundation
import CryptoKit
import MangaCore
public actor PageFileStore {
    public let cacheDirectory: URL
    private let limit: Int
    private let verifier: any ImageVerifying
    public init(root: URL, limit: Int = 256 * 1024 * 1024, verifier: any ImageVerifying = ImageVerifier()) throws {
        cacheDirectory = root.appendingPathComponent("cache", isDirectory: true); self.limit = max(1, limit); self.verifier = verifier
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
    public static func filename(for pageID: PageID) -> String { SHA256.hash(data: Data(pageID.key.utf8)).map { String(format: "%02x", $0) }.joined() + ".image" }
    public func cachedFile(for pageID: PageID) -> URL? {
        let url = cacheDirectory.appendingPathComponent(Self.filename(for: pageID))
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }
    public func writeCache(data: Data, pageID: PageID) throws -> URL {
        try Task.checkCancellation(); _ = try verifier.verify(data)
        guard data.count <= limit else { throw MangaError.storage("单张图片超过缓存容量上限") }
        let url = cacheDirectory.appendingPathComponent(Self.filename(for: pageID))
        do { try data.write(to: url, options: .atomic); try trim(excluding: url) }
        catch let error as CocoaError where error.code == .fileWriteOutOfSpace { throw MangaError.diskFull }
        return url
    }
    public func remove(pageID: PageID) throws { if let url = cachedFile(for: pageID) { try FileManager.default.removeItem(at: url) } }
    public func clearCache() throws {
        for url in try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) { try FileManager.default.removeItem(at: url) }
    }
    private func trim(excluding protected: URL) throws {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let entries = try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: Array(keys)).map { url in (url, try url.resourceValues(forKeys: keys)) }
        var total = entries.reduce(0) { $0 + ($1.1.fileSize ?? 0) }
        for (url, values) in entries.sorted(by: { ($0.1.contentModificationDate ?? .distantPast) < ($1.1.contentModificationDate ?? .distantPast) }) where total > limit && url != protected {
            try FileManager.default.removeItem(at: url); total -= values.fileSize ?? 0
        }
    }
}
