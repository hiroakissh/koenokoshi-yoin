import Foundation
import VoiceMemoDomain
import VoiceMemoInterfaces

#if canImport(AVFoundation)
@preconcurrency import AVFoundation
import CryptoKit

private struct WrittenSegment: Sendable {
    let descriptor: AudioSegmentDescriptor
    let url: URL
}

private final class CaptureWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "jp.hiroakissh.koenokoshiyoin.audio-writer", qos: .userInitiated)
    private let directory: URL
    private let sampleRate: Double
    private let limitSamples: Int64
    private var file: AVAudioFile?
    private var currentURL: URL?
    private var currentIndex = 0
    private var currentStartSample: Int64 = 0
    private var currentSampleCount: Int64 = 0
    private var totalSampleCount: Int64 = 0
    private var segments: [WrittenSegment] = []
    private var stopped = false

    init(directory: URL, format: AVAudioFormat, limitSamples: Int64) throws {
        self.directory = directory; self.sampleRate = format.sampleRate; self.limitSamples = limitSamples
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try openNext(format: format)
    }

    func append(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat) -> Bool {
        queue.sync {
            guard !stopped, let file else { return false }
            do {
                try file.write(from: buffer)
                currentSampleCount += Int64(buffer.frameLength)
                totalSampleCount += Int64(buffer.frameLength)
                if currentSampleCount >= Int64(sampleRate * 300) || totalSampleCount >= limitSamples { try commitCurrent(format: format); return totalSampleCount < limitSamples }
            } catch {
                stopped = true
                return false
            }
            return true
        }
    }

    func finish(format: AVAudioFormat) -> [WrittenSegment] { queue.sync { guard !stopped || file != nil else { return segments }; try? commitCurrent(format: format); stopped = true; return segments } }

    private func openNext(format: AVAudioFormat) throws {
        let url = directory.appendingPathComponent(String(format: "segment-%03d.m4a", currentIndex))
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: max(1, Int(format.channelCount)), AVEncoderBitRateKey: 64_000]
        file = try AVAudioFile(forWriting: url, settings: settings)
        currentURL = url
        currentSampleCount = 0
        currentStartSample = totalSampleCount
    }

    private func commitCurrent(format: AVAudioFormat) throws {
        guard file != nil, let url = currentURL, currentSampleCount > 0 else { return }
        self.file = nil
        let data = try Data(contentsOf: url)
        let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        segments.append(.init(descriptor: .init(segmentID: UUID(), index: currentIndex, startSample: currentStartSample, sampleCount: currentSampleCount, sampleRate: sampleRate, byteCount: Int64(data.count), sha256: hash), url: url))
        currentIndex += 1
        guard totalSampleCount < limitSamples else { return }
        try openNext(format: format)
    }
}

@MainActor
public final class AudioCaptureService: RecorderService {
    private let root: URL
    private var engine: AVAudioEngine?
    private var writer: CaptureWriter?
    private var currentID: UUID?
    private var currentLimit: Int = RecordingLimit.default.rawValue
    private var currentFormat: AVAudioFormat?
    private var continuation: AsyncStream<RecorderEvent>.Continuation?
    private var stopReason: RecordingStopReason = .manual
    private var recordedAt = Date()

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VoiceMemoAudio", isDirectory: true)
    }

    public func start(id: UUID, selectedLimitSeconds: Int) async throws {
        guard currentID == nil else { throw DomainError.duplicateOperation }
        guard let limit = RecordingLimit(rawValue: selectedLimitSeconds) else { throw DomainError.invalidLimit }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let available = (try? FileManager.default.attributesOfFileSystem(forPath: root.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard available >= 50 * 1024 * 1024 else { throw DomainError.insufficientStorage }
        #if os(iOS) || os(watchOS)
        let session = AVAudioSession.sharedInstance()
        switch AVAudioApplication.shared.recordPermission {
        case .denied:
            throw DomainError.unavailable
        case .undetermined:
            let granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
            guard granted else { throw DomainError.unavailable }
        case .granted:
            break
        @unknown default:
            throw DomainError.unavailable
        }
        try session.setCategory(.record, mode: .default, options: [])
        try session.setActive(true)
        #endif
        let localEngine = AVAudioEngine()
        let input = localEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw DomainError.unavailable }
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        let localWriter = try CaptureWriter(directory: directory, format: format, limitSamples: Int64(Double(limit.rawValue) * format.sampleRate))
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self, weak localEngine] buffer, _ in
            let shouldContinue = localWriter.append(buffer, format: format)
            if !shouldContinue {
                Task { @MainActor [weak self, weak localEngine] in
                    guard let self, self.currentID != nil else { return }
                    self.stopReason = .limitReached
                    localEngine?.stop()
                    _ = try? await self.finishCapture()
                }
            }
        }
        localEngine.prepare()
        do { try localEngine.start() } catch { input.removeTap(onBus: 0); throw error }
        currentID = id; currentLimit = selectedLimitSeconds; currentFormat = format; engine = localEngine; writer = localWriter; stopReason = .manual; recordedAt = Date(); continuation?.yield(.started)
    }

    public func stop() async throws -> CapturedRecording { try await finishCapture() }

    public func events() -> AsyncStream<RecorderEvent> { AsyncStream { continuation = $0 } }

    private func finishCapture() async throws -> CapturedRecording {
        guard let id = currentID, let engine, let writer, let format = currentFormat else { throw DomainError.duplicateOperation }
        currentID = nil
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        let segments = writer.finish(format: format)
        #if os(iOS) || os(watchOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        self.engine = nil; self.writer = nil; self.currentFormat = nil
        guard !segments.isEmpty else { throw DomainError.tooShort }
        let descriptor = RecordingDescriptor(id: id, recordedAt: recordedAt, recordingTimeZoneID: TimeZone.current.identifier, selectedLimitSeconds: currentLimit, stopReason: stopReason, wasInterrupted: stopReason == .interrupted, segments: segments.map(\.descriptor))
        try descriptor.validate()
        return CapturedRecording(descriptor: descriptor, segmentURLs: segments.map(\.url))
    }
}
#else
@MainActor public final class AudioCaptureService: RecorderService {
    public init(root: URL? = nil) {}
    public func start(id: UUID, selectedLimitSeconds: Int) async throws { throw DomainError.unavailable }
    public func stop() async throws -> CapturedRecording { throw DomainError.unavailable }
    public func events() -> AsyncStream<RecorderEvent> { AsyncStream { _ in } }
}
#endif
