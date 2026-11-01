import SwiftUI
import DesignSystem
import RecordingFeature
import OutboxFeature
import AudioCapture
import WatchPersistence
import DeviceSync
import RecordingReminders
import VoiceMemoDomain
import VoiceMemoInterfaces
import UserNotifications

private final class WatchNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let handler: @Sendable (UUID, UUID, String) -> Void

    init(handler: @escaping @Sendable (UUID, UUID, String) -> Void) {
        self.handler = handler
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if let memoString = userInfo["memoID"] as? String, let promptString = userInfo["promptID"] as? String, let memoID = UUID(uuidString: memoString), let promptID = UUID(uuidString: promptString) {
            handler(memoID, promptID, response.actionIdentifier == "stop" ? "stop" : "continue")
        }
        completionHandler()
    }
}

@main
struct KoenokoshiYoinWatchApp: App {
    @State private var recordingModel: RecordingViewModel
    @State private var outboxSnapshots: [MemoSnapshot] = []
    @State private var enqueuedMemoIDs: Set<UUID> = []
    private let store: WatchRecordStore
    private let bridge: WatchConnectivityBridge
    private let settingsStore: WatchSettingsStore
    private let reminderService: LocalRecordingReminderService
    private let notificationDelegate: WatchNotificationDelegate
    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VoiceMemoInbox", isDirectory: true)
        let store = try! WatchRecordStore(root: root)
        let bridge = WatchConnectivityBridge(inbox: store, controlInbox: store)
        let settingsStore = try! WatchSettingsStore(root: root)
        let reminderService = LocalRecordingReminderService()
        bridge.activate()
        let model = RecordingViewModel(recorder: AudioCaptureService(), reminders: reminderService, loadSettings: {
            await settingsStore.load()
        }, saveSettings: { settings in
            await settingsStore.save(settings)
        }, afterCapture: { capture in
            try await store.save(capture)
        })
        let notificationDelegate = WatchNotificationDelegate { memoID, promptID, action in
            Task { @MainActor in
                await model.handleReminderAction(memoID: memoID, promptID: promptID, action: action)
            }
        }
        UNUserNotificationCenter.current().delegate = notificationDelegate
        self.store = store
        self.bridge = bridge
        self.settingsStore = settingsStore
        self.reminderService = reminderService
        self.notificationDelegate = notificationDelegate
        _recordingModel = State(initialValue: model)
    }
    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack {
                    RecordingView(model: recordingModel)
                        .toolbar(.hidden, for: .navigationBar)
                }
                    .tabItem { Label("録音", systemImage: "mic.fill") }
                NavigationStack {
                    OutboxView(snapshots: outboxSnapshots) { memoID in
                        Task {
                            if let requests = try? await store.transferRequests(for: memoID) {
                                for request in requests {
                                    bridge.enqueue(file: request.url, metadata: request.metadata)
                                }
                            }
                        }
                    }
                }
                    .tabItem { Label("未送信", systemImage: "arrow.up.circle") }
            }
            .modifier(YoinTint())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.ignoresSafeArea())
            .task {
                await recordingModel.loadPersistedSettings()
                while !Task.isCancelled {
                    try? await store.processPendingControls { requests in
                        for request in requests {
                            bridge.enqueue(file: request.url, metadata: request.metadata)
                        }
                    }
                    if let records = try? await store.loadAll() {
                        for record in records where !enqueuedMemoIDs.contains(record.id) {
                            if let requests = try? await store.transferRequests(for: record.id) {
                                for request in requests {
                                    bridge.enqueue(file: request.url, metadata: request.metadata)
                                }
                                enqueuedMemoIDs.insert(record.id)
                            }
                        }
                    }
                    outboxSnapshots = (try? await store.loadOutboxSnapshots()) ?? []
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }
}
