import Foundation
public struct SourceCapabilities: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let browse = Self(rawValue: 1)
    public static let search = Self(rawValue: 2)
    public static let details = Self(rawValue: 4)
    public static let chapters = Self(rawValue: 8)
    public static let pages = Self(rawValue: 16)
    public static let readable: Self = [.details, .chapters, .pages]
}
public enum ValidationLevel: String, Codable, Sendable { case verified, limited }
public struct ParserBinding: Codable, Hashable, Sendable {
    public var parserID: String
    public var version: Int
    public var configuration: [String: String]
    public var level: ValidationLevel
    public var validatedAt: Date
    public var sampledWorks: Int
    public var sampledChapters: Int
    public var needsRetest: Bool
    public var structureFailures: Int
    public init(parserID: String, version: Int = 1, configuration: [String: String] = [:], level: ValidationLevel = .limited, sampledWorks: Int = 0, sampledChapters: Int = 0) {
        self.parserID = parserID; self.version = version; self.configuration = configuration; self.level = level
        validatedAt = Date(); self.sampledWorks = sampledWorks; self.sampledChapters = sampledChapters; needsRetest = false; structureFailures = 0
    }
}
public struct Source: Codable, Hashable, Sendable, Identifiable {
    public let id: SourceID
    public var name: String
    public var baseURL: URL
    public var enabled: Bool
    public var revision: Int
    public var capabilities: SourceCapabilities
    public var binding: ParserBinding?
    public var removed: Bool
    public init(id: SourceID = SourceID(), name: String, baseURL: URL, enabled: Bool = true, capabilities: SourceCapabilities = [], binding: ParserBinding? = nil) {
        self.id = id; self.name = name; self.baseURL = baseURL; self.enabled = enabled; self.capabilities = capabilities; self.binding = binding; revision = 0; removed = false
    }
}
