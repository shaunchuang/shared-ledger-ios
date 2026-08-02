import SwiftUI

@main
struct SharedLedgerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    private let persistence = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(\.managedObjectContext, persistence.container.viewContext)
                .environmentObject(LedgerNotificationCoordinator.shared)
                .tint(LedgerTheme.primary)
                // 通知協調器要在 App 層啟動，而不是設定頁：它靠遠端變更通知得知其他成員
                // 做了什麼，只有在使用者剛好停在設定頁時才監看，等於幾乎收不到通知。
                .onAppear { LedgerNotificationCoordinator.shared.start() }
                .onChange(of: scenePhase) { _, phase in
                    // 回到前景時再跑一次：背景期間 CloudKit 仍會匯入資料，但 App 沒有
                    // 機會把它翻成通知。`start()` 可以重複呼叫。
                    guard phase == .active else { return }
                    LedgerNotificationCoordinator.shared.start()
                }
        }
    }
}
