import Foundation
import VoiceMemoInterfaces

#if canImport(UserNotifications)
import UserNotifications
#endif

public actor LocalRecordingReminderService: RecordingReminderService {
    private var promptIDs: [UUID: Set<String>] = [:]

    public init() {}
    public func schedule(_ request: RecordingReminderRequest) async throws {
        #if canImport(UserNotifications)
        let content = UNMutableNotificationContent(); content.title = "録音を続けますか？"; content.body = "まだ録音を続けますか？"; content.sound = nil; content.userInfo = ["memoID": request.memoID.uuidString, "promptID": request.promptID.uuidString]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, request.fireDate.timeIntervalSinceNow), repeats: false)
        let action = UNNotificationAction(identifier: "continue", title: "続ける", options: []); let stop = UNNotificationAction(identifier: "stop", title: "停止して保存", options: [.destructive]); let category = UNNotificationCategory(identifier: "recording-reminder", actions: [action, stop], intentIdentifiers: []); let center = UNUserNotificationCenter.current(); center.setNotificationCategories([category]); content.categoryIdentifier = "recording-reminder"; try await center.add(.init(identifier: request.promptID.uuidString, content: content, trigger: trigger))
        promptIDs[request.memoID, default: []].insert(request.promptID.uuidString)
        #endif
    }
    public func cancel(memoID: UUID) async {
        #if canImport(UserNotifications)
        let identifiers = Array(promptIDs.removeValue(forKey: memoID) ?? [])
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        #endif
    }

    #if canImport(UserNotifications)
    public func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }
    #endif
}
