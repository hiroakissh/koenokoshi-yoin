import XCTest
@testable import MemoProcessing
import MemoPersistence
import Transcription
import Summarization
import VoiceMemoDomain
import VoiceMemoInterfaces

final class MemoProcessingTests: XCTestCase {
    func testUnavailableTranscriptionDoesNotDeleteMemo() async throws {
        let repository = InMemoryMemoRepository()
        let descriptor = RecordingDescriptor(id: UUID(), recordedAt: Date(), recordingTimeZoneID: "Asia/Tokyo", selectedLimitSeconds: 1_800, stopReason: .manual, segments: [AudioSegmentDescriptor(segmentID: UUID(), index: 0, startSample: 0, sampleCount: 24_000, sampleRate: 24_000, byteCount: 100, sha256: String(repeating: "a", count: 64))])
        try await repository.commit(.create(descriptor))
        let coordinator = ProcessingCoordinator(repository: repository, transcription: UnavailableTranscriptionService(), summarization: DeterministicSummarizationService())
        let storedSnapshot = try await repository.snapshot(id: descriptor.id)
        let snapshot = try XCTUnwrap(storedSnapshot)
        await coordinator.process(snapshot, input: .init(descriptor: descriptor, segmentURLs: []))
        let storedResult = try await repository.snapshot(id: descriptor.id)
        let result = try XCTUnwrap(storedResult)
        XCTAssertEqual(result.processingState, .unavailable(stage: "transcription", reason: "unsupportedDevice"))
    }

    func testSegmentAndSummaryProgressSurviveStateUpdates() async throws {
        let repository = InMemoryMemoRepository()
        let memoID = UUID()
        let segmentID = UUID()
        let descriptor = RecordingDescriptor(id: memoID, recordedAt: Date(), recordingTimeZoneID: "Asia/Tokyo", selectedLimitSeconds: 1_800, stopReason: .manual, segments: [AudioSegmentDescriptor(segmentID: segmentID, index: 0, startSample: 0, sampleCount: 24_000, sampleRate: 24_000, byteCount: 100, sha256: String(repeating: "a", count: 64))])
        try await repository.commit(.create(descriptor))
        try await repository.commit(.saveSegmentProgress(.init(memoID: memoID, segmentID: segmentID, inputHash: descriptor.segments[0].sha256, text: "保存済み区間", runID: UUID(), revision: 1)))
        try await repository.commit(.saveSummaryProgress(.init(memoID: memoID, nodeID: UUID(), sourceRanges: [0..<10], points: ["要点"], runID: UUID(), validated: true)))
        try await repository.commit(.setProcessing(memoID, .waiting(stage: "summary", reason: "modelNotReady")))
        let storedSnapshot = try await repository.snapshot(id: memoID)
        let snapshot = try XCTUnwrap(storedSnapshot)
        XCTAssertEqual(snapshot.segmentTranscripts[segmentID], "保存済み区間")
        XCTAssertEqual(snapshot.completedSegmentIDs, Set([segmentID]))
        XCTAssertEqual(snapshot.summaryProgress.count, 1)
        XCTAssertEqual(snapshot.processingState, .waiting(stage: "summary", reason: "modelNotReady"))
    }
}
