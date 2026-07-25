import CloudKit
import UIKit

/// 純 SwiftUI 生命週期的 App 仍以「場景（scene）」為單位運作，
/// CloudKit 共享邀請被接受時，系統會呼叫場景層的
/// `windowScene(_:userDidAcceptCloudKitShareWith:)`，而非 App delegate。
/// 少了這個 SceneDelegate，點開邀請會開了 App 卻沒真正加入共享群組。
///
/// 這裡刻意「不」實作 `scene(_:willConnectTo:)` 或自行建立 window，
/// 讓 SwiftUI 的 `WindowGroup` 繼續負責畫面，SceneDelegate 只負責
/// 接住共享邀請的回呼。
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func windowScene(
        _ windowScene: UIWindowScene,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        PersistenceController.shared.acceptShare(metadata: cloudKitShareMetadata)
    }
}
