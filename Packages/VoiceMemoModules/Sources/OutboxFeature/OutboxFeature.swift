import SwiftUI
import VoiceMemoDomain
import VoiceMemoInterfaces
import DesignSystem

public struct OutboxView: View {
    @Environment(\.colorScheme) private var scheme
    let snapshots: [MemoSnapshot]
    let onRetry: (UUID) -> Void
    public init(snapshots: [MemoSnapshot] = [], onRetry: @escaping (UUID) -> Void = { _ in }) { self.snapshots = snapshots; self.onRetry = onRetry }
    public var body: some View {
        List {
            if snapshots.isEmpty {
                Text("未送信の録音はありません")
                    .foregroundStyle(YoinTheme.secondary(scheme))
                    .listRowBackground(YoinTheme.surface(scheme))
            }
            ForEach(snapshots) { memo in
                HStack {
                    VStack(alignment: .leading) {
                        Text(memo.title ?? "未送信の録音")
                        Text(memo.recordedAt, style: .date).font(.caption)
                    }
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing) {
                        Text(status(memo.syncStatus)).font(.caption)
                        if memo.syncStatus != .confirmed {
                            Button("再送") { onRetry(memo.id) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .listRowBackground(YoinTheme.surface(scheme))
        }
        .scrollContentBackground(.hidden)
        .background(YoinTheme.background(scheme).ignoresSafeArea())
        .tint(YoinTheme.action(scheme))
        .navigationTitle("未送信")
    }
    private func status(_ status: SyncStatus) -> String { switch status { case .queued: "同期待ち"; case .transferring: "転送中"; case .awaitingReceipt: "保存確認待ち"; case .confirmed: "iPhoneに保存済み"; case .failed: "再試行が必要" } }
}
