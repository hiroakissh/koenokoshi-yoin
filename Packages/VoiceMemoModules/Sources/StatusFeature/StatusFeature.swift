import Foundation
import SwiftUI
import VoiceMemoInterfaces

public struct StatusView: View {
    let watchConnected: Bool
    let transcription: Capability
    let summarization: Capability
    let freeStorageBytes: Int64?
    let audioStorageBytes: Int64?
    public init(watchConnected: Bool = false, transcription: Capability = .unsupportedDevice, summarization: Capability = .unsupportedDevice, freeStorageBytes: Int64? = nil, audioStorageBytes: Int64? = nil) { self.watchConnected = watchConnected; self.transcription = transcription; self.summarization = summarization; self.freeStorageBytes = freeStorageBytes; self.audioStorageBytes = audioStorageBytes }
    public var body: some View {
        List {
            LabeledContent("Watch連携", value: watchConnected ? "接続済み" : "未接続")
            LabeledContent("文字起こし", value: label(transcription))
            LabeledContent("要約", value: label(summarization))
            if let freeStorageBytes { LabeledContent("iPhone空き容量", value: ByteCountFormatter.string(fromByteCount: freeStorageBytes, countStyle: .file)) }
            if let audioStorageBytes { LabeledContent("音声使用量", value: ByteCountFormatter.string(fromByteCount: audioStorageBytes, countStyle: .file)) }
            Text("音声はiPhoneに保存されます。標準バックアップは端末設定に従います。アプリを削除すると端末上のデータが消えます。").font(.footnote)
        }
        .navigationTitle("利用状況")
    }
    private func label(_ value: Capability) -> String { switch value { case .available: "利用可能"; case .modelNotReady: "モデル準備待ち"; case .unsupportedDevice: "端末非対応"; case .unsupportedLanguage: "言語非対応"; case .disabled: "無効"; case .insufficientStorage: "容量不足" } }
}
