import XCTest
@testable import VoiceMemoDomain

final class DomainTests: XCTestCase {
    func testRecordingLimitDefaultsAndRemindersAreIndependent() {
        XCTAssertEqual(RecordingLimit.default, .fourHours)
        XCTAssertEqual(ReminderInterval.default, .thirtyMinutes)
        XCTAssertNotEqual(RecordingLimit.default.rawValue, ReminderInterval.default.rawValue + 1)
    }

    func testDescriptorRejectsNonContiguousSegments() throws {
        let first = AudioSegmentDescriptor(segmentID: UUID(), index: 0, startSample: 0, sampleCount: 24_000, sampleRate: 24_000, byteCount: 100, sha256: String(repeating: "a", count: 64))
        let second = AudioSegmentDescriptor(segmentID: UUID(), index: 1, startSample: 24_001, sampleCount: 24_000, sampleRate: 24_000, byteCount: 100, sha256: String(repeating: "b", count: 64))
        let value = RecordingDescriptor(id: UUID(), recordedAt: Date(), recordingTimeZoneID: "Asia/Tokyo", selectedLimitSeconds: 1_800, stopReason: .manual, segments: [first, second])
        XCTAssertThrowsError(try value.validate())
    }
}
