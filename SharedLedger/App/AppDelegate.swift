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

    func application(
        _ application: UIApplication,
        userDidAcceptCloudKitShareWith metadata: CKShare.Metadata
    ) {
        let persistence = PersistenceController.shared

        persistence.container.acceptShareInvitations(
            from: [metadata],
            into: persistence.sharedStore
        ) { _, error in
            if let error {
                assertionFailure("Unable to accept CloudKit share: \(error.localizedDescription)")
            }
        }
    }
}

