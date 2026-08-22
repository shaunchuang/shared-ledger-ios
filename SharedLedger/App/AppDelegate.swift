import CloudKit
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // 沒有 delegate 時，App 在前景收到的本機通知會被系統直接丟掉——連通知中心都
        // 不會留。共享帳本的變更多半正好發生在使用者開著 App 的時候，少了這行等於
        // 大部分通知都不會出現。設定 delegate 不需要通知權限，也不會跳出任何詢問。
        UNUserNotificationCenter.current().delegate = self
        // NSPersistentCloudKitContainer 透過遠端推播接收其他成員的變更。
        // 明確註冊 remote notification，避免出現
        // "BUG IN CLIENT OF CLOUDKIT: ... 'remote-notification' background mode"
        // 而導致共享帳本無法即時同步。
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // 註冊失敗是可以復原的狀況：模擬器、或沒有 aps-environment entitlement 的
        // Debug build 都會走到這裡。此時 CloudKit 只是收不到即時推播，退回下次啟動
        // 或手動重新整理時同步，因此只記錄而不中止 App。
        NSLog("Remote notification registration failed: \(error.localizedDescription)")
    }

    // 指定自訂的 SceneDelegate。SwiftUI 生命週期的 App 若採用場景（scene），
    // 系統會把 userDidAcceptCloudKitShareWith 傳給「場景層」的 delegate，
    // 而不是 App delegate；沒有 SceneDelegate 時，點開共享邀請會開了 App
    // 卻沒真正加入群組。這裡明確註冊 SceneDelegate 以接住該回呼。
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    // 保留 App delegate 版本作為後備：某些啟動情境（例如尚未建立場景時）
    // 系統仍可能改呼叫這個方法。
    func application(
        _ application: UIApplication,
        userDidAcceptCloudKitShareWith metadata: CKShare.Metadata
    ) {
        PersistenceController.shared.acceptShare(metadata: metadata)
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// App 在前景時怎麼呈現通知。
    ///
    /// 給橫幅與通知中心，但不出聲：使用者正盯著畫面，聲音只是打擾；完全不呈現又會讓
    /// 「其他成員剛剛改了什麼」這件事在最需要知道的時候消失。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

