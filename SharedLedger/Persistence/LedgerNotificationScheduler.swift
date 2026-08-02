import Foundation
import UserNotifications

/// 送出本機通知的能力。
///
/// 抽成協定不是為了替換實作，而是為了讓「什麼情況下會送出什麼」可以被測試：
/// `UNUserNotificationCenter` 的授權狀態沒辦法在測試裡擺弄，而通知最需要驗證的正是
/// 未授權、被拒絕與已授權之間的行為差異。
protocol LedgerNotificationScheduling {
    func authorizationStatus() async -> LedgerNotificationAuthorization
    /// 向使用者詢問一次通知權限，回傳詢問後的狀態。
    func requestAuthorization() async -> LedgerNotificationAuthorization
    func schedule(_ requests: [LedgerNotificationRequest]) async
}

/// `UNUserNotificationCenter` 的轉接層。
///
/// 這裡只做翻譯，不做判斷：要不要送、送幾則，全部由 `LedgerNotificationPlanner` 決定。
struct SystemNotificationScheduler: LedgerNotificationScheduling {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationStatus() async -> LedgerNotificationAuthorization {
        await Self.authorization(from: center.notificationSettings().authorizationStatus)
    }

    func requestAuthorization() async -> LedgerNotificationAuthorization {
        // 只要 alert 與 sound：這個 App 不會在圖示上掛未讀數字，多要一個 badge 權限
        // 等於為了用不到的東西擴大授權範圍。
        // 詢問失敗（例如系統暫時不可用）不該讓呼叫端停在半途：重新讀一次目前狀態，
        // 畫面就會照實顯示「仍未開啟」，使用者可以再試一次。
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        return await authorizationStatus()
    }

    func schedule(_ requests: [LedgerNotificationRequest]) async {
        for request in requests {
            let content = UNMutableNotificationContent()
            content.title = request.title
            content.body = request.body
            content.threadIdentifier = request.threadIdentifier
            content.sound = .default
            content.userInfo = ["category": request.category.rawValue]

            // trigger 為 nil 代表立刻遞送。這些通知講的都是「剛剛發生的事」或「現在
            // 的狀態」，排程到未來只會讓內容在送達時已經過期。
            let notification = UNNotificationRequest(
                identifier: request.id,
                content: content,
                trigger: nil
            )
            // 單則失敗就跳過那一則。通知送不出去從來不是中斷記帳的理由。
            try? await center.add(notification)
        }
    }

    private static func authorization(
        from status: UNAuthorizationStatus
    ) -> LedgerNotificationAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional: return .provisional
        // 臨時 App clip 授權在遞送行為上等同已授權。
        case .ephemeral: return .authorized
        @unknown default: return .unavailable
        }
    }
}
