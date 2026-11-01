import Foundation
import VoiceMemoInterfaces
import SyncContract

#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

public actor SyncOutbox { private var envelopes: [UUID: SyncEnvelope] = [:]; public init() {}; public func insert(_ envelope: SyncEnvelope) { envelopes[envelope.eventID] = envelope }; public func all() -> [SyncEnvelope] { Array(envelopes.values) } }

#if canImport(WatchConnectivity)
public final class WatchConnectivityBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
    private let inbox: any InboxStaging
    private var controlInbox: (any ControlInboxStaging)?
    public init(inbox: any InboxStaging) { self.inbox = inbox; self.controlInbox = nil; super.init() }
    public convenience init(inbox: any InboxStaging, controlInbox: any ControlInboxStaging) { self.init(inbox: inbox); self.controlInbox = controlInbox }
    public func activate() { guard WCSession.isSupported() else { return }; WCSession.default.delegate = self; WCSession.default.activate() }
    public func enqueue(file url: URL, metadata: [String: String]) { WCSession.default.transferFile(url, metadata: metadata.reduce(into: [String: Any]()) { $0[$1.key] = $1.value }) }
    public func enqueue(control envelope: SyncEnvelope) { guard let data = try? SyncContractCodec.encode(envelope) else { return }; WCSession.default.transferUserInfo(["schemaVersion": 2, "payload": data]) }
    public func session(_ session: WCSession, didReceive file: WCSessionFile) { do { _ = try inbox.stageFile(at: file.fileURL, metadata: file.metadata?.reduce(into: [:]) { $0[$1.key] = String(describing: $1.value) } ?? [:]) } catch {} }
    public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) { guard let data = userInfo["payload"] as? Data else { return }; try? controlInbox?.stageControl(data) }
    public func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    #if os(iOS)
    public func sessionDidBecomeInactive(_ session: WCSession) {}
    public func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif
}
#endif
