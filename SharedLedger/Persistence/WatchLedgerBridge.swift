import Combine
import CoreData
import Foundation
import WatchConnectivity

/// iPhone endpoint. Messages are decoded as value types before main-actor work.
@MainActor
final class WatchLedgerBridge: NSObject, WCSessionDelegate {
    static let shared = WatchLedgerBridge()
    private var observer: AnyCancellable?
    private let persistence: PersistenceController
    private let service: WatchLedgerService
    private let saveRequest: (WatchLedgerRequest) throws -> UUID
    private let widgetCoordinator: LedgerWidgetCoordinator

    init(persistence: PersistenceController = .shared,
         defaults: UserDefaults = .standard,
         widgetStore: LedgerWidgetStore = .shared,
         saveRequest: ((WatchLedgerRequest) throws -> UUID)? = nil) {
        self.persistence = persistence
        let service = WatchLedgerService(persistence: persistence, defaults: defaults)
        self.service = service
        self.saveRequest = saveRequest ?? service.save
        self.widgetCoordinator = LedgerWidgetCoordinator(persistence: persistence, store: widgetStore)
        super.init()
    }

    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        if session.delegate == nil { session.delegate = self; session.activate() }
        if observer == nil {
            let context = persistence.container.viewContext
            observer = Publishers.Merge3(
                NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave, object: context),
                NotificationCenter.default.publisher(for: .NSManagedObjectContextDidMergeChangesObjectIDs, object: context),
                // Permission resolution may update its UserDefaults cache. A
                // broad defaults observer would turn publishing into a loop.
                NotificationCenter.default.publisher(for: WatchLedgerService.selectionChanged)
            ).debounce(for: .milliseconds(400), scheduler: RunLoop.main)
                .sink { [weak self] _ in Task { @MainActor [weak self] in self?.publish() } }
        }
        publish()
    }

    func publish() {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isPaired, WCSession.default.isWatchAppInstalled,
              !persistence.container.viewContext.hasChanges else { return }
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

    /// Shared by the live message delegate and integration tests. It does not
    /// require a foreground scene or a running WidgetKit notification observer.
    func reply(to message: WatchLedgerMessage) -> WatchLedgerReply {
        var reply = WatchLedgerReply()
        if let request = message.request {
            do {
                reply.savedID = try saveRequest(request)
                // Refresh before replying: a background launch may suspend soon
                // afterwards and never run the scene's onAppear/debounced work.
                widgetCoordinator.refresh()
            } catch {
                if Self.isDefinitiveRejection(error) { reply.rejectedID = request.id }
                reply.error = error.localizedDescription
            }
        }
        do {
            reply.context = try JSONDecoder().decode(WatchLedgerContext.self, from: contextData())
        } catch {
            // A refresh error never discards a successful save acknowledgement.
            if reply.savedID == nil && reply.error == nil { reply.error = error.localizedDescription }
        }
        return reply
    }

    private static func isDefinitiveRejection(_ error: Error) -> Bool {
        if let error = error as? WatchLedgerError {
            switch error {
            case .busy: return false
            case .invalid, .changed, .setup: return true
            }
        }
        if let error = error as? PermissionError {
            return error != .cloudPermissionUnknown
        }
        // Only known input/permission failures may release the pending UUID.
        // Storage, lookup and unknown failures leave the outcome unconfirmed.
        return error is EntryRepository.EntryError || error is AllocationCalculator.AllocationError
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
            let reply = self.reply(to: message)
            replyHandler((try? JSONEncoder().encode(reply)) ?? Data())
            self.publish()
        }
    }
}
