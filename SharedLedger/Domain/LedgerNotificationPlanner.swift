import Foundation

/// 這台裝置已經通知過什麼。
///
/// 只存在本機（不同步）：同一個人的兩台裝置各自收自己的通知，才不會因為 iPad 先收到
/// 就讓 iPhone 靜悄悄。
struct LedgerNotificationDigest: Equatable, Codable, Sendable {
    /// 已經納入判斷的稽核事件裡最新的時間。`nil` 代表這台裝置還沒跑過任何一次，
    /// 第一次只取基準、不通知。
    var lastEventDate: Date?
    /// 最近處理過的稽核事件識別碼，用來擋掉重複遞送。
    ///
    /// 依處理順序排列，超過上限時從最舊的開始丟——判斷本身另有 24 小時的年齡上限，
    /// 被丟掉的識別碼早就不可能再進入判斷了。
    var handledEventIDs: [UUID]
    /// 每個帳本上一次「已經提醒過」的待結算指紋，key 是 `bookID.uuidString`。
    var settlementFingerprints: [String: String]
    /// 每個帳本上一次送出待結算提醒的時間。
    var settlementRemindedAt: [String: Date]

    init(
        lastEventDate: Date? = nil,
        handledEventIDs: [UUID] = [],
        settlementFingerprints: [String: String] = [:],
        settlementRemindedAt: [String: Date] = [:]
    ) {
        self.lastEventDate = lastEventDate
        self.handledEventIDs = handledEventIDs
        self.settlementFingerprints = settlementFingerprints
        self.settlementRemindedAt = settlementRemindedAt
    }
}

/// 決定現在該送出哪些通知。
///
/// 全部是純函式：通知最容易出錯的地方不是怎麼送，而是「該不該送」——自己做的事、
/// 遲到的舊事件、第一次同步整段歷史、關掉的種類、沒授權卻仍累積待補的通知。這些
/// 組合在真機上幾乎無法穩定重現，所以判斷邏輯不碰 Core Data 也不碰
/// `UNUserNotificationCenter`。
enum LedgerNotificationPlanner {
    /// 保留多少已處理識別碼。以 24 小時的判斷窗口來說遠遠夠用。
    static let handledEventLimit = 300
    /// 超過這個年齡的稽核事件不再通知。
    ///
    /// CloudKit 匯入的順序不保證跟事件時間一致，一筆三天前的交易可能今天才同步進來；
    /// 為它跳出通知只會讓人以為現在有人在動帳。
    static let maximumEventAge: TimeInterval = 24 * 60 * 60
    /// 同一個帳本兩則待結算提醒之間至少要隔多久。
    static let minimumSettlementInterval: TimeInterval = 12 * 60 * 60

    struct Inputs {
        var events: [LedgerAuditEventSummary]
        var settlements: [LedgerSettlementReminder]
        /// 各群組裡「目前這位使用者」的成員識別碼，key 是 `groupID`。
        var currentActorIDs: [UUID: UUID]
        /// 各群組裡「目前這位使用者」的顯示名稱，key 是 `groupID`。
        /// 只在事件沒有帶成員識別碼時才派上用場，見 `isOwnAction`。
        var currentActorNames: [UUID: String]
        var preferences: LedgerNotificationPreferences
        var authorization: LedgerNotificationAuthorization
        var digest: LedgerNotificationDigest
        var now: Date

        init(
            events: [LedgerAuditEventSummary] = [],
            settlements: [LedgerSettlementReminder] = [],
            currentActorIDs: [UUID: UUID] = [:],
            currentActorNames: [UUID: String] = [:],
            preferences: LedgerNotificationPreferences = .default,
            authorization: LedgerNotificationAuthorization = .authorized,
            digest: LedgerNotificationDigest = LedgerNotificationDigest(),
            now: Date = Date()
        ) {
            self.events = events
            self.settlements = settlements
            self.currentActorIDs = currentActorIDs
            self.currentActorNames = currentActorNames
            self.preferences = preferences
            self.authorization = authorization
            self.digest = digest
            self.now = now
        }
    }

    struct Plan: Equatable {
        var requests: [LedgerNotificationRequest]
        /// 呼叫端必須保存這份 digest，即使一則通知都沒送出。
        var digest: LedgerNotificationDigest
    }

    static func plan(_ inputs: Inputs) -> Plan {
        var digest = inputs.digest
        var requests = auditRequests(inputs, digest: &digest)
        requests.append(contentsOf: settlementRequests(inputs, digest: &digest))
        return Plan(requests: requests, digest: digest)
    }

    /// 稽核事件轉成通知。
    ///
    /// 不論最後有沒有送出，事件都會記進 digest：沒授權時仍推進基準線，使用者之後才
    /// 授權時，才不會一次收到這段期間累積的所有舊事件。
    private static func auditRequests(
        _ inputs: Inputs,
        digest: inout LedgerNotificationDigest
    ) -> [LedgerNotificationRequest] {
        // 第一次執行只取基準：剛裝好 App、或剛接受一個共享群組時，整段歷史都是新
        // 匯入的，逐筆通知等於開場就洗版。
        let isFirstPass = digest.lastEventDate == nil
        var handled = Set(digest.handledEventIDs)
        var requests: [LedgerNotificationRequest] = []

        for event in inputs.events.sorted(by: { $0.createdAt < $1.createdAt }) {
            digest.lastEventDate = max(digest.lastEventDate ?? .distantPast, event.createdAt)
            guard !handled.contains(event.id) else { continue }
            handled.insert(event.id)
            digest.handledEventIDs.append(event.id)

            guard !isFirstPass,
                  inputs.authorization.allowsDelivery,
                  inputs.now.timeIntervalSince(event.createdAt) <= maximumEventAge,
                  let category = event.category,
                  inputs.preferences.isEnabled(category),
                  let body = event.notificationBody,
                  !isOwnAction(event, in: inputs)
            else { continue }

            requests.append(
                LedgerNotificationRequest(
                    id: "audit.\(event.id.uuidString)",
                    category: category,
                    title: category.title,
                    body: body,
                    threadIdentifier: threadIdentifier(forGroup: event.groupID)
                )
            )
        }

        if digest.handledEventIDs.count > handledEventLimit {
            digest.handledEventIDs.removeFirst(digest.handledEventIDs.count - handledEventLimit)
        }
        return requests
    }

    /// 待結算提醒。
    ///
    /// 和稽核事件相反，這裡第一次執行就會提醒：待結算講的是「現在的狀態」而不是「剛剛
    /// 發生的事」，一筆放了三個月沒人付的款不會再產生任何新事件，等狀態變動才提醒等於
    /// 永遠不提醒。也因此，只有真的送出去才記進 digest——沒授權或使用者把這個種類關著
    /// 時先不留紀錄，之後打開才提得動。
    private static func settlementRequests(
        _ inputs: Inputs,
        digest: inout LedgerNotificationDigest
    ) -> [LedgerNotificationRequest] {
        var requests: [LedgerNotificationRequest] = []

        for reminder in inputs.settlements {
            let key = reminder.bookID.uuidString

            guard reminder.outstandingTransferCount > 0 else {
                // 全部結清了。忘掉紀錄，下次再欠時才能立刻提醒。
                digest.settlementFingerprints[key] = nil
                digest.settlementRemindedAt[key] = nil
                continue
            }

            guard inputs.authorization.allowsDelivery,
                  inputs.preferences.isEnabled(.settlementReminder),
                  digest.settlementFingerprints[key] != reminder.fingerprint
            else { continue }

            if let remindedAt = digest.settlementRemindedAt[key],
               inputs.now.timeIntervalSince(remindedAt) < minimumSettlementInterval {
                // 狀況變了，但剛提醒過。跳過而不記下指紋，等冷卻時間過了會再提一次。
                continue
            }

            digest.settlementFingerprints[key] = reminder.fingerprint
            digest.settlementRemindedAt[key] = inputs.now
            requests.append(
                LedgerNotificationRequest(
                    // 每個帳本只留一則：新的提醒取代舊的，通知中心不會堆一排講同一
                    // 件事、金額卻已經過期的提醒。
                    id: "settlement.\(key)",
                    category: .settlementReminder,
                    title: LedgerNotificationCategory.settlementReminder.title,
                    body: reminder.notificationBody,
                    threadIdentifier: threadIdentifier(forGroup: reminder.groupID)
                )
            )
        }

        return requests
    }

    /// 自己做的事不通知。
    ///
    /// 事件帶得出成員識別碼時就只認識別碼：同一個群組裡兩位同名成員不會再互相蓋掉對方
    /// 的通知，成員改名之後也不會突然開始收到自己每一筆操作的通知。此時名稱一律不看
    /// ——識別碼已經明確回答了「是不是我」，再拿名稱補一次只會把同名的問題放回來。
    ///
    /// 只有事件沒有識別碼時才退回名稱比對：V10 之前寫下的事件，以及還沒更新的裝置寫出
    /// 來的事件，都不會有 `actorMemberID`。把「沒有識別碼」當成「不是我做的」，會讓那些
    /// 事件反過來變成使用者自己操作的通知，比同名誤判更吵。
    private static func isOwnAction(
        _ event: LedgerAuditEventSummary,
        in inputs: Inputs
    ) -> Bool {
        if let actorMemberID = event.actorMemberID {
            return inputs.currentActorIDs[event.groupID] == actorMemberID
        }
        guard let name = inputs.currentActorNames[event.groupID] else { return false }
        return name == event.actorDisplayName
    }

    private static func threadIdentifier(forGroup groupID: UUID) -> String {
        "group.\(groupID.uuidString)"
    }
}
