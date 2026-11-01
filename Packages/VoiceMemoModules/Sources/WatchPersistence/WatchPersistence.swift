import Foundation
import VoiceMemoDomain
import VoiceMemoInterfaces
import SyncContract

public actor WatchRecordStore: InboxStaging, ControlInboxStaging {
    public struct TransferFileRequest: Sendable {
        public let url: URL
        public let metadata: [String: String]
        public init(url: URL, metadata: [String: String]) { self.url = url; self.metadata = metadata }
    }
    public let root: URL
    private let fileManager = FileManager.default
    public init(root: URL) throws { self.root = root; try fileManager.createDirectory(at: root, withIntermediateDirectories: true) }
    public func save(_ descriptor: RecordingDescriptor) throws {
        try descriptor.validate()
        let directory = root.appendingPathComponent(descriptor.id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try atomicWrite(descriptor, to: directory.appendingPathComponent("record.json"))
        try atomicWrite(descriptor, to: directory.appendingPathComponent("manifest.json"))
    }

    public func save(_ capture: CapturedRecording) throws {
        guard capture.descriptor.segments.count == capture.segmentURLs.count else { throw DomainError.invalidSegments }
        try save(capture.descriptor)
        let directory = root.appendingPathComponent(capture.descriptor.id.uuidString, isDirectory: true)
        let segmentsDirectory = directory.appendingPathComponent("segments", isDirectory: true)
        try fileManager.createDirectory(at: segmentsDirectory, withIntermediateDirectories: true)
        for (descriptor, source) in zip(capture.descriptor.segments, capture.segmentURLs) {
            let destination = segmentsDirectory.appendingPathComponent("\(descriptor.segmentID.uuidString).m4a")
            if fileManager.fileExists(atPath: destination.path) { continue }
            try fileManager.copyItem(at: source, to: destination)
        }
    }

    public func loadAll() throws -> [RecordingDescriptor] { try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).compactMap { directory in let url = directory.appendingPathComponent("record.json"); guard fileManager.fileExists(atPath: url.path), let data = try? Data(contentsOf: url), let value = try? JSONDecoder.voiceMemo.decode(RecordingDescriptor.self, from: data) else { return nil }; return value }.sorted { $0.recordedAt > $1.recordedAt } }
    public func loadOutboxSnapshots() throws -> [MemoSnapshot] { try loadAll().map { .init(id: $0.id, recordedAt: $0.recordedAt, durationSeconds: $0.durationSeconds, syncStatus: .queued, processingState: .receiving, selectedLimitSeconds: $0.selectedLimitSeconds) } }

    public func transferRequests(for memoID: UUID) throws -> [TransferFileRequest] {
        let directory = root.appendingPathComponent(memoID.uuidString, isDirectory: true)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let descriptor = try JSONDecoder.voiceMemo.decode(RecordingDescriptor.self, from: data)
        try descriptor.validate()
        let attemptID = UUID()
        let manifestHash = try ManifestFile(descriptor: descriptor).manifestHash
        var requests = [TransferFileRequest(url: manifestURL, metadata: ["schemaVersion": "2", "kind": "manifest", "memoID": descriptor.id.uuidString, "transferAttemptID": attemptID.uuidString, "manifestHash": manifestHash, "byteCount": String(descriptor.totalByteCount)])]
        for segment in descriptor.segments {
            let url = segmentURL(for: descriptor.id, segmentID: segment.segmentID)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            requests.append(.init(url: url, metadata: ["schemaVersion": "2", "kind": "segment", "memoID": descriptor.id.uuidString, "segmentID": segment.segmentID.uuidString, "index": String(segment.index), "sha256": segment.sha256, "byteCount": String(segment.byteCount), "transferAttemptID": attemptID.uuidString]))
        }
        return requests
    }
    public nonisolated func stageFile(at url: URL, metadata: [String : String]) throws -> UUID { let id = UUID(); let inbox = root.appendingPathComponent("Inbox", isDirectory: true); try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true); try FileManager.default.copyItem(at: url, to: inbox.appendingPathComponent(id.uuidString)); return id }
    public nonisolated func stageControl(_ data: Data) throws { let inbox = root.appendingPathComponent("ControlInbox", isDirectory: true); try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true); try data.write(to: inbox.appendingPathComponent(UUID().uuidString), options: .atomic) }
    public nonisolated func manifestURL(for memoID: UUID) -> URL { root.appendingPathComponent(memoID.uuidString, isDirectory: true).appendingPathComponent("manifest.json") }
    public nonisolated func segmentURL(for memoID: UUID, segmentID: UUID) -> URL { root.appendingPathComponent(memoID.uuidString, isDirectory: true).appendingPathComponent("segments", isDirectory: true).appendingPathComponent("\(segmentID.uuidString).m4a") }

    public func processPendingControls(resend: @Sendable ([TransferFileRequest]) -> Void = { _ in }) throws {
        let directory = root.appendingPathComponent("ControlInbox", isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        for file in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard let data = try? Data(contentsOf: file), let envelope = try? SyncContractCodec.decode(data) else { continue }
            switch envelope.kind {
            case .storedReceipt where envelope.scope == .memo:
                let memoDirectory = root.appendingPathComponent(envelope.memoID.uuidString, isDirectory: true)
                let manifestURL = memoDirectory.appendingPathComponent("manifest.json")
                let matches = if let data = try? Data(contentsOf: manifestURL), let descriptor = try? JSONDecoder.voiceMemo.decode(RecordingDescriptor.self, from: data), let manifest = try? ManifestFile(descriptor: descriptor) { manifest.manifestHash == envelope.digest } else { false }
                if matches, fileManager.fileExists(atPath: memoDirectory.path) {
                    try fileManager.removeItem(at: memoDirectory)
                }
                try? fileManager.removeItem(at: file)
            case .deletedReceipt:
                let memoDirectory = root.appendingPathComponent(envelope.memoID.uuidString, isDirectory: true)
                if fileManager.fileExists(atPath: memoDirectory.path) { try fileManager.removeItem(at: memoDirectory) }
                try? fileManager.removeItem(at: file)
            case .missingReceipt:
                let directory = root.appendingPathComponent(envelope.memoID.uuidString, isDirectory: true)
                let manifestURL = directory.appendingPathComponent("manifest.json")
                guard let data = try? Data(contentsOf: manifestURL), let descriptor = try? JSONDecoder.voiceMemo.decode(RecordingDescriptor.self, from: data) else { continue }
                let requestedIDs = Set((envelope.metadata["missingSegmentIDs"] ?? "").split(separator: ",").compactMap { UUID(uuidString: String($0)) })
                let attemptID = UUID()
                let manifestHash = (try? ManifestFile(descriptor: descriptor).manifestHash) ?? ""
                var requests = [TransferFileRequest(url: manifestURL, metadata: ["schemaVersion": "2", "kind": "manifest", "memoID": descriptor.id.uuidString, "transferAttemptID": attemptID.uuidString, "manifestHash": manifestHash, "byteCount": String(descriptor.totalByteCount)])]
                for segment in descriptor.segments where requestedIDs.contains(segment.segmentID) {
                    let url = segmentURL(for: descriptor.id, segmentID: segment.segmentID)
                    if fileManager.fileExists(atPath: url.path) {
                        requests.append(.init(url: url, metadata: ["schemaVersion": "2", "kind": "segment", "memoID": descriptor.id.uuidString, "segmentID": segment.segmentID.uuidString, "index": String(segment.index), "sha256": segment.sha256, "byteCount": String(segment.byteCount), "transferAttemptID": attemptID.uuidString]))
                    }
                }
                resend(requests)
                try? fileManager.removeItem(at: file)
            case .rejectedReceipt:
                try? fileManager.removeItem(at: file)
            default:
                break
            }
        }
    }

    private func atomicWrite(_ descriptor: RecordingDescriptor, to url: URL) throws { let temporary = url.appendingPathExtension("tmp"); try JSONEncoder.voiceMemo.encode(descriptor).write(to: temporary, options: .atomic); if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }; try fileManager.moveItem(at: temporary, to: url) }
}

public actor WatchSettingsStore {
    private let url: URL

    public init(root: URL) throws {
        self.url = root.appendingPathComponent("recording-settings.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func load() -> RecordingSettings {
        guard let data = try? Data(contentsOf: url), let settings = try? JSONDecoder.voiceMemo.decode(RecordingSettings.self, from: data) else { return RecordingSettings() }
        return settings
    }

    public func save(_ settings: RecordingSettings) {
        let temporary = url.appendingPathExtension("tmp")
        guard let data = try? JSONEncoder.voiceMemo.encode(settings) else { return }
        try? data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            _ = try? FileManager.default.moveItem(at: temporary, to: url)
        }
    }
}
