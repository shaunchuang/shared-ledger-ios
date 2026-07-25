import CloudKit
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
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
        assertionFailure(
            "Remote notification registration failed: \(error.localizedDescription)"
        )
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

