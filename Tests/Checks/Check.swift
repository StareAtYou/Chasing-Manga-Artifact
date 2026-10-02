import Foundation
public struct Check: Sendable, CustomStringConvertible {
    public let name: String
    public let body: @Sendable () async throws -> Void
    public var description: String { name }
    public init(_ name: String, _ body: @escaping @Sendable () async throws -> Void) { self.name = name; self.body = body }
}
public struct CheckFailure: Error, CustomStringConvertible, Sendable { public let description: String }
public func expect(_ condition: Bool, _ message: String) throws { if !condition { throw CheckFailure(description: message) } }
public func expectError(_ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw CheckFailure(description: "Expected an error")
}
public func allChecks() -> [Check] { identityChecks + libraryStoreChecks + httpClientChecks + templateParserChecks + imageVerifierChecks + sourceDetectorChecks + webAccessPolicyChecks + guaziAdapterChecks + dm5AdapterChecks + manhuazhanAdapterChecks + searchServiceChecks + associationChecks + resumeMatcherChecks + imagePipelineChecks + downloadManagerChecks + updateServiceChecks }
