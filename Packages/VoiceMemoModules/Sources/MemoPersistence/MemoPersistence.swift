import Foundation
import VoiceMemoDomain
import VoiceMemoInterfaces

#if canImport(SwiftData)
import SwiftData
#endif

public actor InMemoryMemoRepository: MemoRepository {
    private var values: [UUID: MemoSnapshot] = [:]
    private var deleted: Set<UUID> = []
    public init() {}
    public func snapshot(id: UUID) async throws -> MemoSnapshot? { values[id] }
    public func snapshots() async throws -> [MemoSnapshot] { values.values.sorted { $0.recordedAt > $1.recordedAt } }
    public func commit(_ command: MemoCommand) async throws {
        switch command {
        case .create(let descriptor): guard !deleted.contains(descriptor.id) else { return }; values[descriptor.id] = .init(id: descriptor.id, recordedAt: descriptor.recordedAt, durationSeconds: descriptor.durationSeconds, syncStatus: .queued, processingState: .receiving, selectedLimitSeconds: descriptor.selectedLimitSeconds)
        case .setSync(let id, let status): try update(id) { value in copy(value, syncStatus: status) }
        case .setProcessing(let id, let state): try update(id) { value in copy(value, processingState: state) }
        case .saveTranscript(let id, let result, _, _): try update(id) { value in copy(value, transcript: result.text, processingState: .queuedSummary, summaryProgress: []) }
        case .saveSummary(let id, let result, _, _): try update(id) { value in copy(value, title: result.title, summaryPoints: result.points, processingState: .completed, summaryProgress: []) }
        case .saveSegmentProgress(let progress):
            try update(progress.memoID) { value in
                var transcripts = value.segmentTranscripts
                transcripts[progress.segmentID] = progress.text
                return copy(value, segmentTranscripts: transcripts)
            }
        case .saveSummaryProgress(let progress):
            try update(progress.memoID) { value in
                var entries = value.summaryProgress
                entries.removeAll { $0.sourceRanges == progress.sourceRanges }
                entries.append(progress)
                return copy(value, summaryProgress: entries)
            }
        case .delete(let id): deleted.insert(id); values.removeValue(forKey: id)
        }
    }
    private func update(_ id: UUID, _ transform: (MemoSnapshot) -> MemoSnapshot) throws { guard !deleted.contains(id), let value = values[id] else { throw DomainError.deleted }; values[id] = transform(value) }
    private func copy(_ value: MemoSnapshot, title: String? = nil, summaryPoints: [String]? = nil, transcript: String? = nil, syncStatus: SyncStatus? = nil, processingState: ProcessingState? = nil, segmentTranscripts: [UUID: String]? = nil, summaryProgress: [SummaryProgress]? = nil) -> MemoSnapshot {
        .init(id: value.id, recordedAt: value.recordedAt, durationSeconds: value.durationSeconds, title: title ?? value.title, summaryPoints: summaryPoints ?? value.summaryPoints, transcript: transcript ?? value.transcript, syncStatus: syncStatus ?? value.syncStatus, processingState: processingState ?? value.processingState, selectedLimitSeconds: value.selectedLimitSeconds, segmentTranscripts: segmentTranscripts ?? value.segmentTranscripts, summaryProgress: summaryProgress ?? value.summaryProgress)
    }
}

#if canImport(SwiftData)
@Model public final class VoiceMemoModel {
    @Attribute(.unique) public var id: UUID
    public var recordedAt: Date
    public var durationSeconds: Double
    public var title: String?
    public var summaryPoints: [String]
    public var transcript: String?
    public var syncStatusRaw: String
    public var processingStateRaw: String
    public var selectedLimitSeconds: Int
    public var deleted: Bool
    public var segmentTranscriptsData: Data?
    public var summaryProgressData: Data?

    public init(id: UUID, recordedAt: Date, durationSeconds: Double, selectedLimitSeconds: Int) {
        self.id = id; self.recordedAt = recordedAt; self.durationSeconds = durationSeconds; self.selectedLimitSeconds = selectedLimitSeconds; self.summaryPoints = []; self.syncStatusRaw = SyncStatus.queued.rawValue; self.processingStateRaw = "receiving"; self.deleted = false; self.segmentTranscriptsData = nil; self.summaryProgressData = nil
    }
}

public enum VoiceMemoSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)
    public static var models: [any PersistentModel.Type] { [VoiceMemoModel.self] }
}

@ModelActor public actor SwiftDataMemoRepository: MemoRepository {
    public init(container: ModelContainer) { self.init(modelContainer: container) }

    public func isDeleted(id: UUID) throws -> Bool {
        let descriptor = FetchDescriptor<VoiceMemoModel>(predicate: #Predicate { $0.id == id })
        return try modelContext.fetch(descriptor).first?.deleted == true
    }

    public func snapshot(id: UUID) async throws -> MemoSnapshot? {
        let descriptor = FetchDescriptor<VoiceMemoModel>(predicate: #Predicate { $0.id == id && !$0.deleted })
        guard let value = try modelContext.fetch(descriptor).first else { return nil }
        return makeSnapshot(value)
    }

    public func snapshots() async throws -> [MemoSnapshot] {
        let descriptor = FetchDescriptor<VoiceMemoModel>(predicate: #Predicate { !$0.deleted }, sortBy: [SortDescriptor(\.recordedAt, order: .reverse)])
        return try modelContext.fetch(descriptor).map(makeSnapshot)
    }

    public func commit(_ command: MemoCommand) async throws {
        switch command {
        case .create(let descriptor):
            let existing = try modelContext.fetch(FetchDescriptor<VoiceMemoModel>(predicate: #Predicate { $0.id == descriptor.id })).first
            guard existing == nil else { return }
            modelContext.insert(VoiceMemoModel(id: descriptor.id, recordedAt: descriptor.recordedAt, durationSeconds: descriptor.durationSeconds, selectedLimitSeconds: descriptor.selectedLimitSeconds))
        case .setSync(let id, let status): try update(id) { $0.syncStatusRaw = status.rawValue }
        case .setProcessing(let id, let state): try update(id) { $0.processingStateRaw = encode(state) }
        case .saveTranscript(let id, let result, _, _): try update(id) { $0.transcript = result.text; $0.processingStateRaw = "queuedSummary"; $0.summaryProgressData = nil }
        case .saveSummary(let id, let result, _, _): try update(id) { $0.title = result.title; $0.summaryPoints = result.points; $0.processingStateRaw = "completed"; $0.summaryProgressData = nil }
        case .saveSegmentProgress(let progress):
            try update(progress.memoID) { value in
                var entries = decodeSegmentProgress(value.segmentTranscriptsData)
                entries.removeAll { $0.segmentID == progress.segmentID }
                entries.append(progress)
                value.segmentTranscriptsData = try? JSONEncoder().encode(entries)
            }
        case .saveSummaryProgress(let progress):
            try update(progress.memoID) { value in
                var entries = decodeSummaryProgress(value.summaryProgressData)
                entries.removeAll { $0.sourceRanges == progress.sourceRanges }
                entries.append(progress)
                value.summaryProgressData = try? JSONEncoder().encode(entries)
            }
        case .delete(let id): try update(id) { $0.deleted = true }
        }
        try modelContext.save()
    }

    private func update(_ id: UUID, _ body: (VoiceMemoModel) -> Void) throws {
        let descriptor = FetchDescriptor<VoiceMemoModel>(predicate: #Predicate { $0.id == id && !$0.deleted })
        guard let value = try modelContext.fetch(descriptor).first else { throw DomainError.deleted }
        body(value)
    }

    private func makeSnapshot(_ value: VoiceMemoModel) -> MemoSnapshot {
        let segmentProgress = decodeSegmentProgress(value.segmentTranscriptsData)
        return .init(id: value.id, recordedAt: value.recordedAt, durationSeconds: value.durationSeconds, title: value.title, summaryPoints: value.summaryPoints, transcript: value.transcript, syncStatus: SyncStatus(rawValue: value.syncStatusRaw) ?? .queued, processingState: decode(value.processingStateRaw), selectedLimitSeconds: value.selectedLimitSeconds, segmentTranscripts: Dictionary(uniqueKeysWithValues: segmentProgress.map { ($0.segmentID, $0.text) }), summaryProgress: decodeSummaryProgress(value.summaryProgressData))
    }
    private func decodeSegmentProgress(_ data: Data?) -> [SegmentTranscriptProgress] { guard let data else { return [] }; return (try? JSONDecoder().decode([SegmentTranscriptProgress].self, from: data)) ?? [] }
    private func decodeSummaryProgress(_ data: Data?) -> [SummaryProgress] { guard let data else { return [] }; return (try? JSONDecoder().decode([SummaryProgress].self, from: data)) ?? [] }
    private func encode(_ state: ProcessingState) -> String { switch state { case .receiving: "receiving"; case .queuedTranscription: "queuedTranscription"; case .transcribing: "transcribing"; case .queuedSummary: "queuedSummary"; case .summarizing: "summarizing"; case .completed: "completed"; case .noSpeech: "noSpeech"; case .waiting(_, let reason): "waiting:\(reason)"; case .unavailable(_, let reason): "unavailable:\(reason)"; case .failed(_, let code): "failed:\(code)" } }
    private func decode(_ raw: String) -> ProcessingState { if raw == "receiving" { return .receiving }; if raw == "queuedTranscription" { return .queuedTranscription }; if raw == "transcribing" { return .transcribing }; if raw == "queuedSummary" { return .queuedSummary }; if raw == "summarizing" { return .summarizing }; if raw == "completed" { return .completed }; if raw == "noSpeech" { return .noSpeech }; if raw.hasPrefix("waiting:") { return .waiting(stage: "processing", reason: String(raw.dropFirst(8))) }; if raw.hasPrefix("unavailable:") { return .unavailable(stage: "processing", reason: String(raw.dropFirst(12))) }; if raw.hasPrefix("failed:") { return .failed(stage: "processing", code: String(raw.dropFirst(7))) }; return .receiving }
}
#endif

public actor FileInboxStaging: InboxStaging, ControlInboxStaging {
    public struct StagedFile: Sendable, Equatable { public let id: UUID; public let url: URL; public let metadata: [String: String]; public init(id: UUID, url: URL, metadata: [String: String]) { self.id = id; self.url = url; self.metadata = metadata } }
    private let root: URL
    public init(root: URL) throws { self.root = root; try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    public nonisolated func stageFile(at url: URL, metadata: [String : String]) throws -> UUID { let id = UUID(); let destination = root.appendingPathComponent(id.uuidString); try FileManager.default.copyItem(at: url, to: destination); let metadataURL = root.appendingPathComponent("\(id.uuidString).metadata.json"); try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic); return id }
    public nonisolated func stageControl(_ data: Data) throws { try data.write(to: root.appendingPathComponent("control-\(UUID().uuidString)"), options: .atomic) }
    public func pendingFiles() throws -> [StagedFile] { try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]).compactMap { url in guard !url.lastPathComponent.hasSuffix(".metadata.json"), let id = UUID(uuidString: url.lastPathComponent), let data = try? Data(contentsOf: root.appendingPathComponent("\(id.uuidString).metadata.json")), let metadata = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }; return StagedFile(id: id, url: url, metadata: metadata) } }
    public func remove(_ file: StagedFile) throws { try? FileManager.default.removeItem(at: file.url); try? FileManager.default.removeItem(at: root.appendingPathComponent("\(file.id.uuidString).metadata.json")) }
}
