import SwiftUI
import VoiceMemoDomain
import VoiceMemoInterfaces
import DesignSystem

public struct MemoListView: View {
    let snapshots: [MemoSnapshot]
    @Environment(\.colorScheme) private var scheme

    public init(snapshots: [MemoSnapshot] = []) { self.snapshots = snapshots }

    public var body: some View {
        List {
            if snapshots.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "waveform")
                        .font(.title)
                        .foregroundStyle(YoinTheme.action(scheme))
                        .accessibilityHidden(true)
                    Text("まだ録音がありません")
                        .font(.headline)
                        .foregroundStyle(YoinTheme.text(scheme))
                    Text("Apple Watchで録音すると、ここに表示されます。")
                        .font(.subheadline)
                        .foregroundStyle(YoinTheme.secondary(scheme))
                }
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowBackground(YoinTheme.surface(scheme))
            } else {
                ForEach(groupedSnapshots, id: \.key) { day, memos in
                    Section(day.formatted(date: .abbreviated, time: .omitted)) {
                        ForEach(memos) { memo in
                            NavigationLink(value: memo.id) {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(memo.title ?? "整理待ち")
                                        .font(.headline)
                                        .foregroundStyle(YoinTheme.text(scheme))
                                    HStack(spacing: 8) {
                                        Text(memo.recordedAt, style: .time)
                                        Text("·").accessibilityHidden(true)
                                        Text(state(memo.processingState))
                                    }
                                    .font(.caption)
                                    .foregroundStyle(YoinTheme.secondary(scheme))
                                }
                                .padding(.vertical, 7)
                            }
                            .listRowBackground(YoinTheme.surface(scheme))
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(YoinTheme.background(scheme))
        .tint(YoinTheme.action(scheme))
        .navigationTitle("音声メモ")
    }

    private var groupedSnapshots: [(key: Date, value: [MemoSnapshot])] {
        let calendar = Calendar.current
        return Dictionary(grouping: snapshots) { calendar.startOfDay(for: $0.recordedAt) }
            .sorted { $0.key > $1.key }
            .map { ($0.key, $0.value.sorted { $0.recordedAt > $1.recordedAt }) }
    }
    private func state(_ value: ProcessingState) -> String { switch value { case .receiving: "受信中"; case .queuedTranscription: "文字起こし待ち"; case .transcribing: "文字起こし中"; case .queuedSummary: "要約待ち"; case .summarizing: "要約中"; case .completed: "整理完了"; case .noSpeech: "音声のみ"; case .waiting(_, let reason): "待機中: \(reason)"; case .unavailable(_, let reason): "利用不可: \(reason)"; case .failed(_, let code): "再試行が必要: \(code)" } }
}
