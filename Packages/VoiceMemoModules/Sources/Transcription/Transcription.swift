import Foundation
import VoiceMemoDomain
import VoiceMemoInterfaces

#if canImport(Speech)
import Speech
import AVFoundation
#endif

public struct UnavailableTranscriptionService: TranscriptionService {
    public init() {}
    public func capability(for locale: String) async -> Capability { .unsupportedDevice }
    public func transcribe(_ input: AudioInput, progress: any TranscriptionProgressSink) async throws -> TranscriptResult { throw DomainError.unavailable }
}

#if canImport(Speech)
@available(iOS 26.0, macOS 26.0, *)
public struct SpeechAnalyzerTranscriptionService: TranscriptionService {
    public let locale: Locale
    public init(locale: Locale = Locale(identifier: "ja-JP")) { self.locale = locale }

    public func capability(for localeIdentifier: String) async -> Capability {
        guard SpeechTranscriber.isAvailable else { return .unsupportedDevice }
        let requested = Locale(identifier: localeIdentifier)
        guard await SpeechTranscriber.supportedLocale(equivalentTo: requested) != nil else { return .unsupportedLanguage }
        let module = SpeechTranscriber(locale: requested, preset: .timeIndexedTranscriptionWithAlternatives)
        switch await AssetInventory.status(forModules: [module]) {
        case .installed: return .available
        case .supported, .downloading: return .modelNotReady
        case .unsupported: return .unsupportedDevice
        @unknown default: return .modelNotReady
        }
    }

    public func transcribe(_ input: AudioInput, progress: any TranscriptionProgressSink) async throws -> TranscriptResult {
        var fullText = ""
        let pairs = zip(input.descriptor.segments.sorted { $0.index < $1.index }, input.segmentURLs)
        for (segment, url) in pairs {
            if input.completedSegmentIDs.contains(segment.segmentID) {
                if let text = input.completedSegmentTexts[segment.segmentID] {
                    fullText += text
                }
                continue
            }
            let file = try AVAudioFile(forReading: url)
            let module = SpeechTranscriber(locale: Locale(identifier: input.descriptor.localeIdentifier), preset: .timeIndexedTranscriptionWithAlternatives)
            let analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [module], options: .init(priority: .userInitiated, modelRetention: .whileInUse), finishAfterFile: true)
            let resultTask = Task { () throws -> String in
                var text = ""
                for try await result in module.results where result.isFinal {
                    text += String(result.text.characters)
                }
                return text
            }
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            let segmentText = try await resultTask.value
            fullText += segmentText
            try await progress.commit(.init(memoID: input.descriptor.id, segmentID: segment.segmentID, inputHash: segment.sha256, text: segmentText, runID: UUID(), revision: 1))
        }
        return TranscriptResult(text: fullText, engineIdentifier: "SpeechTranscriber")
    }
}
#endif
