import SwiftUI
import VoiceMemoInterfaces
import DesignSystem

public struct MemoDetailView: View {
    let memo: MemoSnapshot
    let playback: any AudioPlaybackService
    let onDelete: () async -> Void
    let onRetry: () async -> Void
    @Environment(\.colorScheme) private var scheme
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
                VStack(alignment: .leading, spacing: 6) {
                    Text(memo.title ?? "整理待ち").font(.title2.weight(.semibold))
                    Text(memo.recordedAt, format: .dateTime.year().month().day().hour().minute())
                        .font(.subheadline).foregroundStyle(YoinTheme.secondary(scheme))
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("録音").font(.headline)
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
                            Label(isPlaying ? "一時停止" : "再生", systemImage: isPlaying ? "pause.fill" : "play.fill")
                                .foregroundStyle(YoinTheme.onAction(scheme))
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityHint("録音音声を再生または一時停止")
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
                        Text(errorMessage).font(.footnote).foregroundStyle(YoinTheme.secondary(scheme))
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(YoinTheme.surface(scheme), in: RoundedRectangle(cornerRadius: 16))
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
                    Text("要約").font(.headline).padding(.top, 4)
                    ForEach(memo.summaryPoints, id: \.self) { Text("・\($0)") }
                }
                if let transcript = memo.transcript {
                    Text("全文").font(.headline).padding(.top, 4)
                    Text(transcript)
                } else {
                    Text("文字起こし待ち").foregroundStyle(YoinTheme.secondary(scheme))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
            .foregroundStyle(YoinTheme.text(scheme))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(YoinTheme.background(scheme).ignoresSafeArea())
        .tint(YoinTheme.action(scheme))
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
