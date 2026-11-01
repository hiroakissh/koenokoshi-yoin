import Foundation
import VoiceMemoDomain
import VoiceMemoInterfaces

public actor ProcessingCoordinator {
    private let repository: any MemoRepository
    private let transcription: any TranscriptionService
    private let summarization: any SummarizationService
    private var runningMemoID: UUID?

    public init(repository: any MemoRepository, transcription: any TranscriptionService, summarization: any SummarizationService) { self.repository = repository; self.transcription = transcription; self.summarization = summarization }
    public func process(_ snapshot: MemoSnapshot, input: AudioInput) async {
        if case .completed = snapshot.processingState { return }
        guard runningMemoID == nil else { return }
        runningMemoID = snapshot.id
        defer { runningMemoID = nil }
        do {
            let runID = UUID()
            let transcript: String
            if case .queuedSummary = snapshot.processingState, let existing = snapshot.transcript {
                transcript = existing
            } else {
                let capability = await transcription.capability(for: input.descriptor.localeIdentifier)
                switch capability {
                case .available:
                    break
                case .modelNotReady:
                    try? await repository.commit(.setProcessing(snapshot.id, .waiting(stage: "transcription", reason: "modelNotReady")))
                    return
                case .unsupportedDevice, .unsupportedLanguage, .disabled, .insufficientStorage:
                    try? await repository.commit(.setProcessing(snapshot.id, .unavailable(stage: "transcription", reason: String(describing: capability))))
                    return
                }
                try await repository.commit(.setProcessing(snapshot.id, .transcribing))
                let result = try await transcription.transcribe(input, progress: ProgressSink(repository: repository))
                try await repository.commit(.saveTranscript(snapshot.id, result, 1, runID))
                guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { try await repository.commit(.setProcessing(snapshot.id, .noSpeech)); return }
                transcript = result.text
            }
            switch await summarization.capability(for: input.descriptor.localeIdentifier) {
            case .available:
                break
            case .modelNotReady:
                try? await repository.commit(.setProcessing(snapshot.id, .waiting(stage: "summary", reason: "modelNotReady")))
                return
            case .unsupportedDevice, .unsupportedLanguage, .disabled, .insufficientStorage:
                try? await repository.commit(.setProcessing(snapshot.id, .unavailable(stage: "summary", reason: "unavailable")))
                return
            }
            try await repository.commit(.setProcessing(snapshot.id, .summarizing))
            let summary = try await summarization.summarize(.init(memoID: snapshot.id, transcript: transcript, transcriptRevision: 1, runID: runID, completedProgress: snapshot.summaryProgress), progress: SummarySink(repository: repository))
            try await repository.commit(.saveSummary(snapshot.id, summary, 1, runID))
        } catch is CancellationError { try? await repository.commit(.setProcessing(snapshot.id, snapshot.transcript == nil ? .queuedTranscription : .queuedSummary))
        } catch { try? await repository.commit(.setProcessing(snapshot.id, .failed(stage: "processing", code: String(describing: error)))) }
    }
    private struct ProgressSink: TranscriptionProgressSink { let repository: any MemoRepository; func commit(_ progress: SegmentTranscriptProgress) async throws { try await repository.commit(.saveSegmentProgress(progress)) } }
    private struct SummarySink: SummaryProgressSink { let repository: any MemoRepository; func commit(_ progress: SummaryProgress) async throws { try await repository.commit(.saveSummaryProgress(progress)) } }
}
