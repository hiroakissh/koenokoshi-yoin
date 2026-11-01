import SwiftUI
import VoiceMemoInterfaces

public struct MemoDetailView: View {
    let memo: MemoSnapshot
    let playback: any AudioPlaybackService
    let onDelete: () async -> Void
    let onRetry: () async -> Void
    @State private var isPlaying = false
    @State private var seekPosition = 0.0
    @State private var showingDeleteConfirmation = false
    @State private var isRetrying = false
    @State private var errorMessage: String?

    public init(memo: MemoSnapshot, playback: any AudioPlaybackService = UnavailableAudioPlaybackService(), onDelete: @escaping () async -> Void = {}, onRetry: @escaping () async -> Void = {}) {
        self.memo = memo
        self.playback = playback
        self.onDelete = onDelete
        self.onRetry = onRetry
    }

    public var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                Text(memo.title ?? "整理待ち").font(.title2)
                Text("長さ: \(Int(memo.durationSeconds))秒")
                HStack {
                    Button {
                        Task {
                            do {
                                if isPlaying {
                                    await playback.pause()
                                } else {
                                    try await playback.play(memoID: memo.id, from: seekPosition)
                                }
                                isPlaying.toggle()
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    } label: {
                        Label(isPlaying ? "停止" : "再生", systemImage: isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("録音音声を再生または停止")
                }
                VStack(spacing: 4) {
                    Slider(value: $seekPosition, in: 0...max(1, memo.durationSeconds), onEditingChanged: { editing in
                        if !editing {
                            Task { try? await playback.seek(memoID: memo.id, to: seekPosition) }
                        }
                    })
                    .accessibilityLabel("再生位置")
                    HStack {
                        Text(formatTime(seekPosition))
                        Spacer()
                        Text(formatTime(memo.durationSeconds))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.secondary)
                }
                if canRetry {
                    Button {
                        Task {
                            isRetrying = true
                            await onRetry()
                            isRetrying = false
                        }
                    } label: {
                        Label(isRetrying ? "再試行中…" : "この工程を再試行", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRetrying)
                }
                if !memo.summaryPoints.isEmpty {
                    Text("要約").font(.headline)
                    ForEach(memo.summaryPoints, id: \.self) { Text("・\($0)") }
                }
                if let transcript = memo.transcript {
                    Text("全文").font(.headline)
                    Text(transcript)
                } else {
                    Text("文字起こし待ち").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("詳細")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("削除", role: .destructive) { showingDeleteConfirmation = true }
            }
        }
        .confirmationDialog("このメモを削除しますか？", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                Task { await onDelete() }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("音声、文字起こし、要約を削除します。この操作は取り消せません。")
        }
    }

    private var canRetry: Bool {
        switch memo.processingState {
        case .waiting, .unavailable, .failed: return true
        default: return false
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
