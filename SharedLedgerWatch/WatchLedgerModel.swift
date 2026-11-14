import Foundation
import WatchConnectivity
import SwiftUI

@MainActor
final class WatchLedgerModel: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var state: WatchLedgerState
    @Published private(set) var isSending = false
    @Published private(set) var isReachable = false
    @Published var message: String?
    private static var stateURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("watch-ledger-state-v1.json")
    }

    override init() {
        state = (try? Data(contentsOf: Self.stateURL))
            .flatMap { try? JSONDecoder().decode(WatchLedgerState.self, from: $0) } ?? WatchLedgerState()
        super.init()
    }

    func start() {
        let session = WCSession.default
        if session.delegate == nil { session.delegate = self; session.activate() }
        isReachable = session.isReachable
        refresh()
    }

    func refresh() { send(WatchLedgerMessage()) }

    func save(_ request: WatchLedgerRequest) {
        guard state.pending == nil, request.isValid else { return }
        state.pending = request
        retry()
    }

    func retry() {
        guard let request = state.pending else { return }
        // Persist the stable ID before any request can reach the phone.
        guard persist() else { return }
        send(WatchLedgerMessage(request: request))
    }

    private func send(_ message: WatchLedgerMessage) {
        guard !isSending else { return }
        let session = WCSession.default
        isReachable = session.isReachable
        guard session.activationState == .activated, session.isReachable else {
            self.message = LedgerStringKey.watchDisconnected.string()
            return
        }
        guard let data = try? JSONEncoder().encode(message) else { return }
        isSending = true
        session.sendMessageData(data, replyHandler: { data in
            let reply = try? JSONDecoder().decode(WatchLedgerReply.self, from: data)
            Task { @MainActor in
                self.isSending = false
                guard let reply, reply.version == 1 else {
                    self.message = LedgerStringKey.watchPending.string(); return
                }
                let pendingID = self.state.pending?.id
                self.state.receive(reply)
                self.persist()
                if let pendingID, reply.savedID == pendingID {
                    self.message = LedgerStringKey.watchSaved.string()
                } else {
                    self.message = reply.error
                }
            }
        }, errorHandler: { _ in
            Task { @MainActor in
                self.isSending = false
                self.message = LedgerStringKey.watchDisconnected.string()
            }
        })
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            try FileManager.default.createDirectory(at: Self.stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: Self.stateURL, options: .atomic)
            return true
        } catch {
            message = LedgerStringKey.watchStorageError.string()
            return false
        }
    }

    private func receive(_ data: Data?) {
        guard let data, let context = try? JSONDecoder().decode(WatchLedgerContext.self, from: data) else { return }
        state.receive(WatchLedgerReply(context: context))
        persist()
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let data = session.receivedApplicationContext["ledger"] as? Data
        Task { @MainActor in self.receive(data); self.start() }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.isReachable = reachable }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let data = applicationContext["ledger"] as? Data
        Task { @MainActor in self.receive(data) }
    }
}
