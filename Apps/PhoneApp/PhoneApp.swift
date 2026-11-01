import SwiftUI
import Observation
import SwiftData
import CryptoKit
import MemoListFeature
import MemoDetailFeature
import StatusFeature
import MemoPersistence
import DeviceSync
import MemoProcessing
import Transcription
import Summarization
import VoiceMemoDomain
import VoiceMemoInterfaces
import SyncContract
import AudioPlayback
import WatchConnectivity

@main
struct KoenokoshiYoinPhoneApp: App {
    @State private var snapshots: [MemoSnapshot] = []
    @State private var watchConnected = false
    @State private var transcriptionCapability: Capability = .unsupportedDevice
    @State private var summarizationCapability: Capability = .unsupportedDevice
    @State private var freeStorageBytes: Int64?
    @State private var audioStorageBytes: Int64?
    private let container: ModelContainer
    private let repository: SwiftDataMemoRepository
    private let bridge: WatchConnectivityBridge
    private let inboxCoordinator: PhoneInboxCoordinator
    private let audioRoot: URL
    private let playback: AVAudioPlaybackService
    private let transcriptionService: SpeechAnalyzerTranscriptionService
    private let summarizationService: FoundationModelsSummarizationService

    init() {
        let container = try! ModelContainer(for: VoiceMemoModel.self)
        self.container = container
        self.repository = SwiftDataMemoRepository(container: container)
        let inbox = try! FileInboxStaging(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Inbox", isDirectory: true))
        let audioRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Audio", isDirectory: true)
        try! FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        let bridge = WatchConnectivityBridge(inbox: inbox, controlInbox: inbox)
        bridge.activate()
        self.bridge = bridge
        self.audioRoot = audioRoot
        self.playback = AVAudioPlaybackService(root: audioRoot)
        let transcriptionService = SpeechAnalyzerTranscriptionService()
        let summarizationService = FoundationModelsSummarizationService()
        self.transcriptionService = transcriptionService
        self.summarizationService = summarizationService
        self.inboxCoordinator = PhoneInboxCoordinator(inbox: inbox, audioRoot: audioRoot, repository: repository, processing: ProcessingCoordinator(repository: repository, transcription: transcriptionService, summarization: summarizationService), sendReceipt: { envelope in
            bridge.enqueue(control: envelope)
        })
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack {
                    MemoListView(snapshots: snapshots)
                        .navigationDestination(for: UUID.self) { id in
                            if let memo = snapshots.first(where: { $0.id == id }) {
                                MemoDetailView(memo: memo, playback: playback, onDelete: {
                                    try? await repository.commit(.delete(id))
                                    try? FileManager.default.removeItem(at: audioRoot.appendingPathComponent(id.uuidString, isDirectory: true))
                                    bridge.enqueue(control: .init(kind: .deletedReceipt, memoID: id, scope: .memo, metadata: ["status": "deleted"]))
                                    snapshots = (try? await repository.snapshots()) ?? []
                                }, onRetry: {
                                    await inboxCoordinator.retry(memoID: id)
                                    snapshots = (try? await repository.snapshots()) ?? []
                                })
                            } else {
                                ContentUnavailableView("メモが見つかりません", systemImage: "questionmark.folder")
                            }
                        }
                }
                    .tabItem { Label("履歴", systemImage: "list.bullet") }
                NavigationStack { StatusView(watchConnected: watchConnected, transcription: transcriptionCapability, summarization: summarizationCapability, freeStorageBytes: freeStorageBytes, audioStorageBytes: audioStorageBytes) }
                    .tabItem { Label("利用状況", systemImage: "info.circle") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .modelContainer(container)
            .task {
                watchConnected = WCSession.isSupported() && WCSession.default.activationState == .activated
                transcriptionCapability = await transcriptionService.capability(for: "ja-JP")
                summarizationCapability = await summarizationService.capability(for: "ja-JP")
                while !Task.isCancelled {
                    await inboxCoordinator.poll()
                    await inboxCoordinator.resumePending()
                    snapshots = (try? await repository.snapshots()) ?? []
                    freeStorageBytes = Self.freeStorageBytes(at: audioRoot)
                    audioStorageBytes = Self.directorySize(at: audioRoot)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    private static func freeStorageBytes(at url: URL) -> Int64? {
        (try? FileManager.default.attributesOfFileSystem(forPath: url.path)[.systemFreeSize] as? NSNumber)?.int64Value
    }

    private static func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        return enumerator.reduce(into: Int64(0)) { total, item in
            guard let fileURL = item as? URL, let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return }
            total += Int64(size)
        }
    }
}

actor PhoneInboxCoordinator {
    private let inbox: FileInboxStaging
    private let audioRoot: URL
    private let repository: SwiftDataMemoRepository
    private let processing: ProcessingCoordinator
    private let sendReceipt: @Sendable (SyncEnvelope) -> Void
    private var inFlight: Set<UUID> = []
    private var handled: Set<UUID> = []
    private var missingNotified: Set<UUID> = []
    private var retryAfter: [UUID: Date] = [:]

    init(inbox: FileInboxStaging, audioRoot: URL, repository: SwiftDataMemoRepository, processing: ProcessingCoordinator, sendReceipt: @escaping @Sendable (SyncEnvelope) -> Void) {
        self.inbox = inbox
        self.audioRoot = audioRoot
        self.repository = repository
        self.processing = processing
        self.sendReceipt = sendReceipt
    }

    func poll() async {
        guard let files = try? await inbox.pendingFiles() else { return }
        let groups = Dictionary(grouping: files) { UUID(uuidString: $0.metadata["memoID"] ?? "") }
        for (key, group) in groups {
            guard let memoID = key, !inFlight.contains(memoID), !handled.contains(memoID) else { continue }
            if (try? await repository.isDeleted(id: memoID)) == true {
                sendReceipt(.init(kind: .rejectedReceipt, memoID: memoID, reasonCode: .deleted))
                for file in group { try? await inbox.remove(file) }
                continue
            }
            guard let manifestFile = group.first(where: { $0.metadata["kind"] == "manifest" }) else {
                continue
            }
            guard let data = try? Data(contentsOf: manifestFile.url), let descriptor = try? JSONDecoder.voiceMemo.decode(RecordingDescriptor.self, from: data), (try? descriptor.validate()) != nil else {
                if !missingNotified.contains(memoID) {
                    sendReceipt(.init(kind: .rejectedReceipt, memoID: memoID, reasonCode: .invalidMetadata))
                    missingNotified.insert(memoID)
                }
                for file in group { try? await inbox.remove(file) }
                continue
            }
            let segmentFiles: [URL]
            do {
                segmentFiles = try validatedSegmentFiles(for: descriptor, in: group)
            } catch {
                if !missingNotified.contains(memoID) {
                    let receivedIDs = Set(group.compactMap { UUID(uuidString: $0.metadata["segmentID"] ?? "") })
                    let missingIDs = descriptor.segments.map(\.segmentID).filter { !receivedIDs.contains($0) }
                    sendReceipt(.init(kind: missingIDs.isEmpty ? .rejectedReceipt : .missingReceipt, memoID: memoID, reasonCode: missingIDs.isEmpty ? .invalidAudio : .missing, metadata: ["missingSegmentIDs": missingIDs.map(\.uuidString).joined(separator: ",")]))
                    missingNotified.insert(memoID)
                }
                continue
            }
            missingNotified.remove(memoID)
            inFlight.insert(memoID)
            defer { inFlight.remove(memoID) }
            let persistedFiles: [URL]
            do {
                persistedFiles = try persistAudio(descriptor: descriptor, manifestURL: manifestFile.url, segmentFiles: segmentFiles)
            } catch DomainError.idConflict {
                sendReceipt(.init(kind: .rejectedReceipt, memoID: memoID, reasonCode: .idConflict))
                for file in group { try? await inbox.remove(file) }
                continue
            } catch {
                sendReceipt(.init(kind: .rejectedReceipt, memoID: memoID, reasonCode: .invalidAudio))
                continue
            }
            try? await repository.commit(.create(descriptor))
            try? await repository.commit(.setSync(memoID, .confirmed))
            if let manifest = try? ManifestFile(descriptor: descriptor) {
                sendReceipt(.init(kind: .storedReceipt, memoID: memoID, scope: .memo, digest: manifest.manifestHash, metadata: ["status": "stored"]))
            }
            for file in group { try? await inbox.remove(file) }
            guard let snapshot = try? await repository.snapshot(id: memoID) else { continue }
            await processing.process(snapshot, input: .init(descriptor: descriptor, segmentURLs: persistedFiles))
            handled.insert(memoID)
        }
    }

    func resumePending() async {
        guard let snapshots = try? await repository.snapshots() else { return }
        for snapshot in snapshots where shouldResume(snapshot.processingState) {
            guard !inFlight.contains(snapshot.id), retryAfter[snapshot.id, default: .distantPast] <= Date() else { continue }
            if case .transcribing = snapshot.processingState {
                try? await repository.commit(.setProcessing(snapshot.id, .queuedTranscription))
            } else if case .summarizing = snapshot.processingState {
                try? await repository.commit(.setProcessing(snapshot.id, .queuedSummary))
            }
            guard let current = try? await repository.snapshot(id: snapshot.id), let input = try? await persistedInput(for: snapshot.id) else { continue }
            inFlight.insert(snapshot.id)
            await processing.process(current, input: input)
            inFlight.remove(snapshot.id)
            if let updated = try? await repository.snapshot(id: snapshot.id), case .waiting = updated.processingState {
                retryAfter[snapshot.id] = Date().addingTimeInterval(30)
            } else {
                retryAfter.removeValue(forKey: snapshot.id)
            }
        }
    }

    func retry(memoID: UUID) async {
        guard let snapshot = try? await repository.snapshot(id: memoID) else { return }
        let nextState: ProcessingState
        switch snapshot.processingState {
        case .waiting(let stage, _), .unavailable(let stage, _), .failed(let stage, _):
            nextState = stage == "summary" && snapshot.transcript != nil ? .queuedSummary : .queuedTranscription
        default:
            return
        }
        try? await repository.commit(.setProcessing(memoID, nextState))
        retryAfter.removeValue(forKey: memoID)
        handled.remove(memoID)
        await resumePending()
    }

    private func validatedSegmentFiles(for descriptor: RecordingDescriptor, in group: [FileInboxStaging.StagedFile]) throws -> [URL] {
        try descriptor.segments.sorted { $0.index < $1.index }.map { segment in
            guard let file = group.first(where: { $0.metadata["segmentID"] == segment.segmentID.uuidString }) else { throw DomainError.invalidSegments }
            let data = try Data(contentsOf: file.url)
            let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
            guard Int64(data.count) == segment.byteCount, hash == segment.sha256 else { throw DomainError.invalidSegments }
            return file.url
        }
    }

    private func persistAudio(descriptor: RecordingDescriptor, manifestURL: URL, segmentFiles: [URL]) throws -> [URL] {
        let memoDirectory = audioRoot.appendingPathComponent(descriptor.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: memoDirectory, withIntermediateDirectories: true)
        let permanentManifest = memoDirectory.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: permanentManifest.path) {
            let existingData = try Data(contentsOf: permanentManifest)
            let existingDescriptor = try JSONDecoder.voiceMemo.decode(RecordingDescriptor.self, from: existingData)
            let existingHash = try ManifestFile(descriptor: existingDescriptor).manifestHash
            let incomingHash = try ManifestFile(descriptor: descriptor).manifestHash
            guard existingHash == incomingHash else { throw DomainError.idConflict }
        } else {
            try FileManager.default.copyItem(at: manifestURL, to: permanentManifest)
        }
        return try zip(descriptor.segments.sorted { $0.index < $1.index }, segmentFiles).map { segment, source in
            let destination = memoDirectory.appendingPathComponent("segment-\(String(format: "%03d", segment.index)).m4a")
            if FileManager.default.fileExists(atPath: destination.path) {
                let existingData = try Data(contentsOf: destination)
                let hash = SHA256.hash(data: existingData).compactMap { String(format: "%02x", $0) }.joined()
                guard Int64(existingData.count) == segment.byteCount, hash == segment.sha256 else { throw DomainError.idConflict }
            } else {
                try FileManager.default.copyItem(at: source, to: destination)
            }
            return destination
        }
    }

    private func persistedInput(for memoID: UUID) async throws -> AudioInput {
        let directory = audioRoot.appendingPathComponent(memoID.uuidString, isDirectory: true)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let descriptor = try JSONDecoder.voiceMemo.decode(RecordingDescriptor.self, from: Data(contentsOf: manifestURL))
        try descriptor.validate()
        let urls = try descriptor.segments.sorted { $0.index < $1.index }.map { segment in
            let url = directory.appendingPathComponent("segment-\(String(format: "%03d", segment.index)).m4a")
            guard FileManager.default.fileExists(atPath: url.path) else { throw DomainError.invalidSegments }
            return url
        }
        guard let snapshot = try? await repository.snapshot(id: memoID) else {
            return AudioInput(descriptor: descriptor, segmentURLs: urls)
        }
        return AudioInput(descriptor: descriptor, segmentURLs: urls, completedSegmentIDs: snapshot.completedSegmentIDs, completedSegmentTexts: snapshot.segmentTranscripts)
    }

    private func shouldResume(_ state: ProcessingState) -> Bool {
        switch state {
        case .queuedTranscription, .transcribing, .queuedSummary, .summarizing, .waiting:
            return true
        default:
            return false
        }
    }
}
