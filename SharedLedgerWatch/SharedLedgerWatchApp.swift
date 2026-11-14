import SwiftUI

@main
struct SharedLedgerWatchApp: App {
    @StateObject private var model = WatchLedgerModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            NavigationStack { WatchLedgerView(model: model) }
                .tint(.mint)
                .onAppear { model.start() }
                .onChange(of: phase) { _, phase in
                    if phase == .active { model.start() }
                }
        }
    }
}
