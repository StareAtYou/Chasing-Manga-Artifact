import Foundation
public struct ParserRegistry: Sendable {
    public let adapters: [any SourceAdapter]
    public init(adapters: [any SourceAdapter] = [HTMLTemplateAdapter(), JSONTemplateAdapter()]) { self.adapters = adapters }
    public func adapter(id: String) -> (any SourceAdapter)? { adapters.first { $0.id == id } }
    public func adapter(for source: Source) throws -> any SourceAdapter {
        guard let binding = source.binding, !binding.needsRetest, let adapter = adapter(id: binding.parserID) else { throw MangaError.parseMismatch("来源尚未绑定有效解析方式") }
        return adapter
    }
}
