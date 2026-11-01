import SwiftUI
import VoiceMemoDomain
import VoiceMemoInterfaces

public struct MemoListView: View {
    let snapshots: [MemoSnapshot]
    public init(snapshots: [MemoSnapshot] = []) { self.snapshots = snapshots }
    public var body: some View {
        List {
            if snapshots.isEmpty {
                ContentUnavailableView("録音はありません", systemImage: "waveform", description: Text("Apple Watchで録音すると、ここに表示されます。"))
            } else {
                ForEach(groupedSnapshots, id: \.key) { day, memos in
                    Section(day.formatted(date: .abbreviated, time: .omitted)) {
                        ForEach(memos) { memo in
                            NavigationLink(value: memo.id) {
                                VStack(alignment: .leading) {
                                    Text(memo.title ?? "整理待ち").font(.headline)
                                    Text(memo.recordedAt, style: .time)
                                    Text(state(memo.processingState)).font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
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
