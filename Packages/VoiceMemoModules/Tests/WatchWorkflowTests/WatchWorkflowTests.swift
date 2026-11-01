import XCTest
@testable import WatchWorkflow
import VoiceMemoDomain
import VoiceMemoInterfaces
import WatchPersistence

@MainActor private final class FakeRecorder: RecorderService {
    var started: (UUID, Int)?
    func start(id: UUID, selectedLimitSeconds: Int) async throws { started = (id, selectedLimitSeconds) }
    func stop() async throws -> CapturedRecording { let id = started?.0 ?? UUID(); return CapturedRecording(descriptor: RecordingDescriptor(id: id, recordedAt: Date(), recordingTimeZoneID: "Asia/Tokyo", selectedLimitSeconds: started?.1 ?? 1_800, stopReason: .manual, segments: [AudioSegmentDescriptor(segmentID: UUID(), index: 0, startSample: 0, sampleCount: 24_000, sampleRate: 24_000, byteCount: 100, sha256: String(repeating: "a", count: 64))]), segmentURLs: []) }
    func events() -> AsyncStream<RecorderEvent> { AsyncStream { _ in } }
}

final class WatchWorkflowTests: XCTestCase {
    func testLimitIsSnapshottedWhenStarting() async throws {
        let recorder = await MainActor.run { FakeRecorder() }
        let workflow = WatchWorkflowController(recorder: recorder, reminders: DefaultReminderService(), now: { Date(timeIntervalSince1970: 0) }, makeID: { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! })
        _ = try await workflow.start(limit: .oneHour)
        let selected = await MainActor.run { recorder.started?.1 }
        XCTAssertEqual(selected, RecordingLimit.oneHour.rawValue)
    }

    func testWatchRecordStoreRoundTripsAtomically() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WatchRecordStore(root: root)
        let descriptor = RecordingDescriptor(id: UUID(), recordedAt: Date(), recordingTimeZoneID: "Asia/Tokyo", selectedLimitSeconds: 1_800, stopReason: .manual, segments: [AudioSegmentDescriptor(segmentID: UUID(), index: 0, startSample: 0, sampleCount: 24_000, sampleRate: 24_000, byteCount: 100, sha256: String(repeating: "a", count: 64))])
        try await store.save(descriptor)
        let loaded = try await store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, descriptor.id)
        XCTAssertEqual(loaded[0].segments, descriptor.segments)
        XCTAssertLessThan(abs(loaded[0].recordedAt.timeIntervalSince(descriptor.recordedAt)), 0.001)
    }
}
