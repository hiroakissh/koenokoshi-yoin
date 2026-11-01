import Foundation
import VoiceMemoInterfaces

#if canImport(AVFoundation)
@preconcurrency import AVFoundation

@MainActor
public final class AVAudioPlaybackService: NSObject, AudioPlaybackService, AVAudioPlayerDelegate, @unchecked Sendable {
    private let root: URL
    private var player: AVAudioPlayer?
    private var currentMemoID: UUID?
    private var files: [URL] = []
    private var segmentIndex = 0

    public init(root: URL) {
        self.root = root
    }

    public func play(memoID: UUID, from seconds: Double) async throws {
        let directory = root.appendingPathComponent(memoID.uuidString, isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "m4a" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw NSError(domain: "AudioPlayback", code: 1, userInfo: [NSLocalizedDescriptionKey: "音声ファイルが見つかりません"]) }
        self.files = files
        var remaining = max(0, seconds)
        var selectedIndex = 0
        for (index, file) in files.enumerated() {
            let duration = try AVAudioPlayer(contentsOf: file).duration
            if remaining <= duration {
                selectedIndex = index
                break
            }
            remaining -= duration
            selectedIndex = index
        }
        try startSegment(at: selectedIndex, offset: remaining)
        self.currentMemoID = memoID
    }

    public func pause() async {
        player?.pause()
    }

    public func seek(memoID: UUID, to seconds: Double) async throws {
        guard currentMemoID == memoID, let player else {
            try await play(memoID: memoID, from: seconds)
            return
        }
        _ = player
        try await play(memoID: memoID, from: seconds)
    }

    private func startSegment(at index: Int, offset: Double) throws {
        guard files.indices.contains(index) else {
            player = nil
            return
        }
        let next = try AVAudioPlayer(contentsOf: files[index])
        next.delegate = self
        next.currentTime = max(0, min(offset, next.duration))
        next.prepareToPlay()
        guard next.play() else { throw NSError(domain: "AudioPlayback", code: 2, userInfo: [NSLocalizedDescriptionKey: "音声を再生できません"]) }
        segmentIndex = index
        player = next
    }

    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let nextIndex = self.segmentIndex + 1
            guard self.files.indices.contains(nextIndex) else { self.player = nil; return }
            try? self.startSegment(at: nextIndex, offset: 0)
        }
    }

}
#else
public typealias AVAudioPlaybackService = NoopAudioPlaybackService
#endif

public actor NoopAudioPlaybackService: AudioPlaybackService { public init() {}; public func play(memoID: UUID, from seconds: Double) async throws {}; public func pause() async {}; public func seek(memoID: UUID, to seconds: Double) async throws {} }
