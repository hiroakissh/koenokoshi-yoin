import Foundation

public enum RecordingLimit: Int, Codable, CaseIterable, Sendable, Identifiable {
    case thirtyMinutes = 1_800
    case oneHour = 3_600
    case twoHours = 7_200
    case fourHours = 14_400

    public var id: Int { rawValue }
    public static let `default`: Self = .fourHours
    public var label: String {
        switch self { case .thirtyMinutes: "30分"; case .oneHour: "1時間"; case .twoHours: "2時間"; case .fourHours: "4時間" }
    }
}

public enum ReminderInterval: Int, Codable, CaseIterable, Sendable, Identifiable {
    case fifteenMinutes = 900
    case thirtyMinutes = 1_800
    case oneHour = 3_600
    case off = 0

    public var id: Int { rawValue }
    public static let `default`: Self = .thirtyMinutes
    public var label: String {
        switch self { case .fifteenMinutes: "15分"; case .thirtyMinutes: "30分"; case .oneHour: "60分"; case .off: "オフ" }
    }
}

public struct RecordingSettings: Codable, Sendable, Equatable {
    public var limit: RecordingLimit
    public var reminder: ReminderInterval

    public init(limit: RecordingLimit = .default, reminder: ReminderInterval = .default) {
        self.limit = limit
        self.reminder = reminder
    }
}

public enum RecordingStopReason: String, Codable, Sendable { case manual, limitReached, interrupted, storageCritical, inputFailure, recovered }
public enum CaptureStatus: String, Codable, Sendable { case idle, preparing, recording, finalizing, committed, failed }
public enum SyncStatus: String, Codable, Sendable { case queued, transferring, awaitingReceipt, confirmed, failed }
public enum ProcessingState: Codable, Sendable, Equatable {
    case receiving
    case queuedTranscription
    case transcribing
    case queuedSummary
    case summarizing
    case waiting(stage: String, reason: String)
    case unavailable(stage: String, reason: String)
    case failed(stage: String, code: String)
    case noSpeech
    case completed
}

public struct AudioSegmentDescriptor: Codable, Sendable, Equatable, Identifiable {
    public let segmentID: UUID
    public let index: Int
    public let startSample: Int64
    public let sampleCount: Int64
    public let sampleRate: Double
    public let byteCount: Int64
    public let sha256: String

    public var id: UUID { segmentID }
    public init(segmentID: UUID, index: Int, startSample: Int64, sampleCount: Int64, sampleRate: Double, byteCount: Int64, sha256: String) {
        self.segmentID = segmentID; self.index = index; self.startSample = startSample; self.sampleCount = sampleCount; self.sampleRate = sampleRate; self.byteCount = byteCount; self.sha256 = sha256
    }
}

public struct RecordingDescriptor: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let recordedAt: Date
    public let recordingTimeZoneID: String
    public let localeIdentifier: String
    public let selectedLimitSeconds: Int
    public let stopReason: RecordingStopReason
    public let wasInterrupted: Bool
    public let hasLostTail: Bool
    public let segments: [AudioSegmentDescriptor]
    public let schemaVersion: Int

    public init(id: UUID, recordedAt: Date, recordingTimeZoneID: String, localeIdentifier: String = "ja-JP", selectedLimitSeconds: Int, stopReason: RecordingStopReason, wasInterrupted: Bool = false, hasLostTail: Bool = false, segments: [AudioSegmentDescriptor], schemaVersion: Int = 2) {
        self.id = id; self.recordedAt = recordedAt; self.recordingTimeZoneID = recordingTimeZoneID; self.localeIdentifier = localeIdentifier; self.selectedLimitSeconds = selectedLimitSeconds; self.stopReason = stopReason; self.wasInterrupted = wasInterrupted; self.hasLostTail = hasLostTail; self.segments = segments; self.schemaVersion = schemaVersion
    }

    public var totalSampleCount: Int64 { segments.reduce(0) { $0 + $1.sampleCount } }
    public var durationSeconds: Double { guard let rate = segments.first?.sampleRate, rate > 0 else { return 0 }; return Double(totalSampleCount) / rate }
    public var totalByteCount: Int64 { segments.reduce(0) { $0 + $1.byteCount } }
    public var manifestHashInput: Data { (try? JSONEncoder.voiceMemo.encode(self)) ?? Data() }
    public func validate() throws {
        guard RecordingLimit(rawValue: selectedLimitSeconds) != nil else { throw DomainError.invalidLimit }
        guard schemaVersion == 2 else { throw DomainError.unsupportedSchema }
        guard !segments.isEmpty, durationSeconds >= 1 || segments.count > 1 else { throw DomainError.tooShort }
        guard segments.enumerated().allSatisfy({ $0.offset == $0.element.index }) else { throw DomainError.invalidSegments }
        guard Set(segments.map(\.segmentID)).count == segments.count else { throw DomainError.invalidSegments }
        guard segments.allSatisfy({ $0.byteCount > 0 && $0.sampleCount > 0 && $0.sampleRate.isFinite && $0.sampleRate > 0 && $0.sha256.count == 64 }) else { throw DomainError.invalidSegments }
        guard durationSeconds <= Double(selectedLimitSeconds) + 1 else { throw DomainError.limitExceeded }
        for pair in zip(segments, segments.dropFirst()) where pair.0.startSample + pair.0.sampleCount != pair.1.startSample { throw DomainError.invalidSegments }
    }
}

public enum DomainError: Error, Codable, Sendable, Equatable { case invalidLimit, unsupportedSchema, tooShort, invalidSegments, idConflict, limitExceeded, duplicateOperation, staleEvent, deleted, unavailable, insufficientStorage }

public enum RecordingEvent: Sendable, Equatable { case startTapped, recordingStarted, preparationFailed(String), segmentCommitted(AudioSegmentDescriptor), stopTapped, limitReached, interrupted, storageCritical, fileCommitted(RecordingDescriptor), commitFailed(String), reminderDue(UUID), continueTapped(UUID), reminderStopTapped(UUID), resetTapped }
public enum RecordingState: Sendable, Equatable { case idle, preparing, recording(RecordingDescriptor), finalizing(RecordingDescriptor), failed(String) }

public struct RecordingTransition: Sendable, Equatable { public let state: RecordingState; public let effects: [RecordingEffect]; public init(state: RecordingState, effects: [RecordingEffect] = []) { self.state = state; self.effects = effects } }
public enum RecordingEffect: Sendable, Equatable { case requestPermission, prepareAudio, stopAudio, scheduleReminder(Date, UUID), cancelReminder(UUID), persist, enqueueTransfer(UUID) }

public struct RecordingStateMachine: Sendable {
    public private(set) var state: RecordingState = .idle
    public init() {}
    @discardableResult public mutating func send(_ event: RecordingEvent) -> RecordingTransition {
        switch (state, event) {
        case (.idle, .startTapped): state = .preparing; return .init(state: state, effects: [.requestPermission, .prepareAudio])
        case (.preparing, .recordingStarted): state = .recording(Self.placeholder); return .init(state: state)
        case (.preparing, .preparationFailed(let reason)): state = .failed(reason); return .init(state: state)
        case (.recording(let descriptor), .segmentCommitted(let segment)): state = .recording(Self.updated(descriptor, adding: segment)); return .init(state: state, effects: [.persist])
        case (.recording(let descriptor), .stopTapped), (.recording(let descriptor), .limitReached), (.recording(let descriptor), .interrupted), (.recording(let descriptor), .storageCritical): state = .finalizing(descriptor); return .init(state: state, effects: [.stopAudio])
        case (.recording, .reminderDue), (.recording, .continueTapped): return .init(state: state)
        case (.finalizing, .fileCommitted(let descriptor)): state = .idle; return .init(state: state, effects: [.persist, .enqueueTransfer(descriptor.id)])
        case (.finalizing, .commitFailed(let reason)): state = .failed(reason); return .init(state: state, effects: [.persist])
        case (.failed, .resetTapped): state = .idle; return .init(state: state)
        default: return .init(state: state)
        }
    }
    private static let placeholder = RecordingDescriptor(id: UUID(), recordedAt: Date(), recordingTimeZoneID: TimeZone.current.identifier, selectedLimitSeconds: RecordingLimit.default.rawValue, stopReason: .manual, segments: [])
    private static func updated(_ descriptor: RecordingDescriptor, adding segment: AudioSegmentDescriptor) -> RecordingDescriptor { RecordingDescriptor(id: descriptor.id, recordedAt: descriptor.recordedAt, recordingTimeZoneID: descriptor.recordingTimeZoneID, localeIdentifier: descriptor.localeIdentifier, selectedLimitSeconds: descriptor.selectedLimitSeconds, stopReason: descriptor.stopReason, wasInterrupted: descriptor.wasInterrupted, hasLostTail: descriptor.hasLostTail, segments: descriptor.segments + [segment], schemaVersion: descriptor.schemaVersion) }
}

public extension JSONEncoder {
    static var voiceMemo: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .custom { date, encoder in var container = encoder.singleValueContainer(); try container.encode(date.timeIntervalSince1970) }; return encoder }
}
public extension JSONDecoder {
    static var voiceMemo: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .custom { decoder in Date(timeIntervalSince1970: try decoder.singleValueContainer().decode(Double.self)) }; return decoder }
}
