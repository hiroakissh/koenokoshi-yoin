import Foundation
import VoiceMemoDomain
import VoiceMemoInterfaces
import SyncContract

public actor WatchWorkflowController {
    public private(set) var state = RecordingStateMachine()
    private let recorder: any RecorderService
    private let reminders: any RecordingReminderService
    private let persist: @Sendable (CapturedRecording) async throws -> Void
    private let enqueueTransfer: @Sendable (CapturedRecording) async throws -> Void
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID

    public init(recorder: any RecorderService, reminders: any RecordingReminderService, persist: @escaping @Sendable (CapturedRecording) async throws -> Void = { _ in }, enqueueTransfer: @escaping @Sendable (CapturedRecording) async throws -> Void = { _ in }, now: @escaping @Sendable () -> Date = Date.init, makeID: @escaping @Sendable () -> UUID = UUID.init) { self.recorder = recorder; self.reminders = reminders; self.persist = persist; self.enqueueTransfer = enqueueTransfer; self.now = now; self.makeID = makeID }
    public func start(limit: RecordingLimit) async throws -> UUID {
        guard case .idle = state.state else { throw DomainError.duplicateOperation }
        let memoID = makeID()
        _ = state.send(.startTapped)
        try await recorder.start(id: memoID, selectedLimitSeconds: limit.rawValue)
        _ = state.send(.recordingStarted)
        return memoID
    }
    public func stop() async throws -> CapturedRecording {
        guard case .recording = state.state else { throw DomainError.duplicateOperation }
        _ = state.send(.stopTapped)
        let captured = try await recorder.stop()
        try await persist(captured)
        try await enqueueTransfer(captured)
        _ = state.send(.fileCommitted(captured.descriptor))
        return captured
    }
    public func scheduleReminder(memoID: UUID, interval: ReminderInterval, limit: RecordingLimit) async throws {
        guard interval != .off else { return }
        let fireDate = now().addingTimeInterval(TimeInterval(interval.rawValue))
        guard fireDate < now().addingTimeInterval(TimeInterval(limit.rawValue)) else { return }
        try await reminders.schedule(.init(memoID: memoID, promptID: makeID(), fireDate: fireDate))
    }
    public func handleReminderStop(memoID: UUID, promptID: UUID) async throws { _ = state.send(.reminderStopTapped(promptID)); _ = try await stop() }
}

public struct DefaultReminderService: RecordingReminderService { public init() {} ; public func schedule(_ request: RecordingReminderRequest) async throws {}; public func cancel(memoID: UUID) async {} }
