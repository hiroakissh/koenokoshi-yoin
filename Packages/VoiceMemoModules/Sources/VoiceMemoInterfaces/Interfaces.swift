import Foundation
import VoiceMemoDomain

public struct CapturedRecording: Sendable, Equatable { public let descriptor: RecordingDescriptor; public let segmentURLs: [URL]; public init(descriptor: RecordingDescriptor, segmentURLs: [URL]) { self.descriptor = descriptor; self.segmentURLs = segmentURLs } }
public enum RecorderEvent: Sendable, Equatable { case started, segmentCommitted(AudioSegmentDescriptor), interrupted, storageCritical, failed(String) }
public struct RecordingReminderRequest: Sendable, Equatable { public let memoID: UUID; public let promptID: UUID; public let fireDate: Date; public init(memoID: UUID, promptID: UUID, fireDate: Date) { self.memoID = memoID; self.promptID = promptID; self.fireDate = fireDate } }
public enum Capability: Sendable, Equatable { case available, modelNotReady, unsupportedDevice, unsupportedLanguage, disabled, insufficientStorage }
public struct AudioInput: Sendable, Equatable {
    public let descriptor: RecordingDescriptor
    public let segmentURLs: [URL]
    public let completedSegmentIDs: Set<UUID>
    public let completedSegmentTexts: [UUID: String]
    public init(descriptor: RecordingDescriptor, segmentURLs: [URL], completedSegmentIDs: Set<UUID> = [], completedSegmentTexts: [UUID: String] = [:]) {
        self.descriptor = descriptor
        self.segmentURLs = segmentURLs
        self.completedSegmentIDs = completedSegmentIDs
        self.completedSegmentTexts = completedSegmentTexts
    }
}
public struct SegmentTranscriptProgress: Sendable, Equatable, Codable {
    public let memoID: UUID
    public let segmentID: UUID
    public let inputHash: String
    public let text: String
    public let runID: UUID
    public let revision: Int
    public init(memoID: UUID, segmentID: UUID, inputHash: String, text: String, runID: UUID, revision: Int) { self.memoID = memoID; self.segmentID = segmentID; self.inputHash = inputHash; self.text = text; self.runID = runID; self.revision = revision }
}
public struct TranscriptResult: Sendable, Equatable { public let text: String; public let engineIdentifier: String; public init(text: String, engineIdentifier: String) { self.text = text; self.engineIdentifier = engineIdentifier } }
public struct SummaryInput: Sendable, Equatable {
    public let memoID: UUID
    public let transcript: String
    public let transcriptRevision: Int
    public let runID: UUID
    public let completedProgress: [SummaryProgress]
    public init(memoID: UUID, transcript: String, transcriptRevision: Int, runID: UUID, completedProgress: [SummaryProgress] = []) {
        self.memoID = memoID
        self.transcript = transcript
        self.transcriptRevision = transcriptRevision
        self.runID = runID
        self.completedProgress = completedProgress
    }
}
public struct SummaryProgress: Sendable, Equatable, Codable {
    public let memoID: UUID
    public let nodeID: UUID
    public let sourceRanges: [Range<Int>]
    public let points: [String]
    public let runID: UUID
    public let validated: Bool
    public init(memoID: UUID, nodeID: UUID, sourceRanges: [Range<Int>], points: [String], runID: UUID, validated: Bool) { self.memoID = memoID; self.nodeID = nodeID; self.sourceRanges = sourceRanges; self.points = points; self.runID = runID; self.validated = validated }
}
public struct SummaryResult: Sendable, Equatable { public let title: String; public let points: [String]; public let engineIdentifier: String; public init(title: String, points: [String], engineIdentifier: String) { self.title = title; self.points = points; self.engineIdentifier = engineIdentifier } }

@MainActor public protocol RecorderService: AnyObject, Sendable { func start(id: UUID, selectedLimitSeconds: Int) async throws; func stop() async throws -> CapturedRecording; func events() -> AsyncStream<RecorderEvent> }
public protocol RecordingReminderService: Sendable { func schedule(_ request: RecordingReminderRequest) async throws; func cancel(memoID: UUID) async; func requestAuthorization() async -> Bool }
public extension RecordingReminderService { func requestAuthorization() async -> Bool { true } }
public protocol TranscriptionProgressSink: Sendable { func commit(_ progress: SegmentTranscriptProgress) async throws }
public protocol TranscriptionService: Sendable { func capability(for locale: String) async -> Capability; func transcribe(_ input: AudioInput, progress: any TranscriptionProgressSink) async throws -> TranscriptResult }
public protocol SummaryProgressSink: Sendable { func commit(_ progress: SummaryProgress) async throws }
public protocol SummarizationService: Sendable { func capability(for locale: String) async -> Capability; func summarize(_ input: SummaryInput, progress: any SummaryProgressSink) async throws -> SummaryResult }

public struct MemoSnapshot: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let recordedAt: Date
    public let durationSeconds: Double
    public let title: String?
    public let summaryPoints: [String]
    public let transcript: String?
    public let syncStatus: SyncStatus
    public let processingState: ProcessingState
    public let selectedLimitSeconds: Int
    public let segmentTranscripts: [UUID: String]
    public let summaryProgress: [SummaryProgress]
    public init(id: UUID, recordedAt: Date, durationSeconds: Double, title: String? = nil, summaryPoints: [String] = [], transcript: String? = nil, syncStatus: SyncStatus = .confirmed, processingState: ProcessingState = .receiving, selectedLimitSeconds: Int = RecordingLimit.default.rawValue, segmentTranscripts: [UUID: String] = [:], summaryProgress: [SummaryProgress] = []) {
        self.id = id
        self.recordedAt = recordedAt
        self.durationSeconds = durationSeconds
        self.title = title
        self.summaryPoints = summaryPoints
        self.transcript = transcript
        self.syncStatus = syncStatus
        self.processingState = processingState
        self.selectedLimitSeconds = selectedLimitSeconds
        self.segmentTranscripts = segmentTranscripts
        self.summaryProgress = summaryProgress
    }
    public var completedSegmentIDs: Set<UUID> { Set(segmentTranscripts.keys) }
}
public enum MemoCommand: Sendable { case create(RecordingDescriptor); case setSync(UUID, SyncStatus); case setProcessing(UUID, ProcessingState); case saveTranscript(UUID, TranscriptResult, Int, UUID); case saveSummary(UUID, SummaryResult, Int, UUID); case delete(UUID); case saveSegmentProgress(SegmentTranscriptProgress); case saveSummaryProgress(SummaryProgress) }
public protocol MemoRepository: Sendable { func snapshot(id: UUID) async throws -> MemoSnapshot?; func snapshots() async throws -> [MemoSnapshot]; func commit(_ command: MemoCommand) async throws }
public protocol InboxStaging: Sendable { func stageFile(at url: URL, metadata: [String: String]) throws -> UUID }
public protocol ControlInboxStaging: Sendable { func stageControl(_ data: Data) throws }
public protocol AudioPlaybackService: Sendable { func play(memoID: UUID, from seconds: Double) async throws; func pause() async; func seek(memoID: UUID, to seconds: Double) async throws }
public actor UnavailableAudioPlaybackService: AudioPlaybackService {
    public init() {}
    public func play(memoID: UUID, from seconds: Double) async throws { throw DomainError.unavailable }
    public func pause() async {}
    public func seek(memoID: UUID, to seconds: Double) async throws { throw DomainError.unavailable }
}
