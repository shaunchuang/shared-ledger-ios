import CloudKit
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
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

