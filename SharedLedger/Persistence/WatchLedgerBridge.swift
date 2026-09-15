import Combine
import CoreData
import WatchConnectivity

/// iPhone endpoint. Messages are decoded as value types before main-actor work.
@MainActor
final class WatchLedgerBridge: NSObject, WCSessionDelegate {
    static let shared = WatchLedgerBridge()
    private var observer: AnyCancellable?
    private let service = WatchLedgerService(persistence: .shared)

    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        if session.delegate == nil { session.delegate = self; session.activate() }
        if observer == nil {
            let context = PersistenceController.shared.container.viewContext
            observer = Publishers.Merge3(
                NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave, object: context),
                NotificationCenter.default.publisher(for: .NSManagedObjectContextDidMergeChangesObjectIDs, object: context),
                NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            ).debounce(for: .milliseconds(400), scheduler: RunLoop.main)
                .sink { [weak self] _ in Task { @MainActor [weak self] in self?.publish() } }
        }
        publish()
    }

    func publish() {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isPaired, WCSession.default.isWatchAppInstalled,
              !PersistenceController.shared.container.viewContext.hasChanges else { return }
        do {
            let data = try contextData()
            try WCSession.default.updateApplicationContext(["ledger": data])
        } catch { /* The watch keeps the dated last successful context. */ }
    }

    private func contextData() throws -> Data {
        let data = try JSONEncoder().encode(service.context())
        if data.count <= 55_000 { return data }
        return try JSONEncoder().encode(WatchLedgerContext(restriction: LedgerStringKey.watchTooLarge.string()))
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.publish() }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.publish() }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessageData data: Data, replyHandler: @escaping (Data) -> Void) {
        guard data.count < 55_000,
              let message = try? JSONDecoder().decode(WatchLedgerMessage.self, from: data), message.version == 1 else {
            replyHandler(Data()); return
        }
        Task { @MainActor in
            var reply = WatchLedgerReply()
            if let request = message.request {
                do { reply.savedID = try self.service.save(request) }
                catch {
                    reply.rejectedID = request.id
                    reply.error = error.localizedDescription
                }
            }
            // A refresh error after a successful save must never turn its ack
            // into a rejection (and encourage another transaction).
            if let contextData = try? self.contextData() {
                reply.context = try? JSONDecoder().decode(WatchLedgerContext.self, from: contextData)
            }
            replyHandler((try? JSONEncoder().encode(reply)) ?? Data())
            self.publish()
        }
    }
}
