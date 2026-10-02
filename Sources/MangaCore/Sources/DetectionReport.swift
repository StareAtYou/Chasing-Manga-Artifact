import Foundation
public enum DetectionStatus: String, Codable, Sendable { case verified, limited, ambiguous, needsSamples, accessFailure, unsupported, cancelled }
public struct DetectedWork: Sendable { public let work: SourceWork; public let chapters: [Chapter] }
public struct DetectionCandidate: Sendable, Identifiable {
    public var id: String { binding.parserID }
    public let binding: ParserBinding
    public let works: [DetectedWork]
    public let previewPages: [URL]
    public let fingerprint: [String]
}
public struct DetectionReport: Sendable {
    public var detectionID: UUID = UUID()
    public let sourceID: SourceID
    public let sourceRevision: Int
    public let status: DetectionStatus
    public let candidates: [DetectionCandidate]
    public let error: MangaError?
    public var binding: ParserBinding? { [.verified, .limited].contains(status) ? candidates.first?.binding : nil }
    public init(source: Source, status: DetectionStatus, candidates: [DetectionCandidate] = [], error: MangaError? = nil) {
        sourceID = source.id; sourceRevision = source.revision; self.status = status; self.candidates = candidates; self.error = error
    }
}
