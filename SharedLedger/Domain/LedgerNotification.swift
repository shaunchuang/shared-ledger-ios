import Foundation

/// 使用者可以個別關閉的通知種類。
///
/// 切分的依據是「使用者會為了什麼理由把它關掉」，不是資料從哪裡來：多人群組裡交易
/// 改動可能一天好幾則，成員異動少見卻幾乎都要立刻知道。綁在同一個開關上，等於逼
/// 使用者為了少收幾則交易通知連邀請一起關掉。
enum LedgerNotificationCategory: String, CaseIterable, Identifiable, Sendable {
    /// 群組邀請與成員異動。
    case groupInvitation
    /// 其他成員新增、修改或作廢交易。
    case transactionChange
    /// 還沒結清的款項。
    case settlementReminder

    var id: String { rawValue }

    var titleKey: LedgerStringKey {
        switch self {
        case .groupInvitation: return .notificationCategoryGroupInvitationTitle
        case .transactionChange: return .notificationCategoryTransactionChangeTitle
        case .settlementReminder: return .notificationCategorySettlementReminderTitle
        }
    }

    var detailKey: LedgerStringKey {
        switch self {
        case .groupInvitation: return .notificationCategoryGroupInvitationDetail
        case .transactionChange: return .notificationCategoryTransactionChangeDetail
        case .settlementReminder: return .notificationCategorySettlementReminderDetail
        }
    }

    var title: String { titleKey.string() }

    var detail: String { detailKey.string() }

    var systemImage: String {
        switch self {
        case .groupInvitation: return "person.2.badge.plus"
        case .transactionChange: return "list.bullet.rectangle"
        case .settlementReminder: return "arrow.left.arrow.right.circle"
        }
    }

    /// 稽核動作對應的通知種類；`nil` 代表這個動作不值得打斷使用者。
    ///
    /// 稽核紀錄是共享資料裡唯一會跟著 CloudKit 同步過來、而且明確記下「誰做了什麼」
    /// 的東西，所以通知直接以它為來源。反過來說，這裡沒列到的動作（帳戶對帳、餘額
    /// 調整、資料遷移⋯⋯）就是刻意不通知：它們仍完整留在稽核紀錄裡可以查。
    init?(auditAction: String) {
        switch auditAction {
        case "member.invitation.resent",
             "member.invitation.revoked",
             "member.identity.confirmed",
             "member.removed",
             "member.left",
             "group.ownership.transferred":
            self = .groupInvitation
        case "transaction.created", "transaction.updated", "transaction.voided":
            self = .transactionChange
        case "settlement.recorded", "settlement.reversed":
            self = .settlementReminder
        default:
            return nil
        }
    }
}

/// 一則稽核事件裡，決定要不要通知、以及通知怎麼寫所需要的全部資訊。
///
/// 收成純值而不是直接傳 `AuditEvent`：通知的規則（誰做的、多久以前、要不要重複送）
/// 才能在沒有 Core Data、沒有 CloudKit 的情況下完整測試，而這些規則正是最難在真機
/// 上重現的部分。
struct LedgerAuditEventSummary: Equatable, Sendable, Identifiable {
    let id: UUID
    let groupID: UUID
    let groupName: String
    let action: String
    /// 做這件事的成員。V10 之前的事件、以及還沒更新的裝置寫出來的事件是 `nil`，
    /// 那時只能退回顯示名稱比對。
    let actorMemberID: UUID?
    let actorDisplayName: String
    let createdAt: Date

    init(
        id: UUID,
        groupID: UUID,
        groupName: String,
        action: String,
        actorMemberID: UUID? = nil,
        actorDisplayName: String,
        createdAt: Date
    ) {
        self.id = id
        self.groupID = groupID
        self.groupName = groupName
        self.action = action
        self.actorMemberID = actorMemberID
        self.actorDisplayName = actorDisplayName
        self.createdAt = createdAt
    }

    var category: LedgerNotificationCategory? {
        LedgerNotificationCategory(auditAction: action)
    }

    /// 通知內文。
    ///
    /// 刻意不帶金額與交易備註：通知會顯示在鎖定畫面上，而共享帳本的金額是這個 App
    /// 裡最敏感的資料。要看細節就打開 App，那裡本來就有完整的稽核紀錄。
    /// 稽核 `summary` 同樣不直接拿來用——交易與結算的 summary 是 JSON payload。
    var notificationBody: String? { localizedNotificationBody(locale: nil) }

    func localizedNotificationBody(locale: Locale?) -> String? {
        guard let descriptor = bodyDescriptor else { return nil }
        return descriptor.key.string(arguments: descriptor.arguments, locale: locale)
    }

    /// 擁有權移轉只提群組，因為「誰把擁有權給了誰」在通知這個長度裡講不清楚，
    /// 講一半反而容易誤會；其餘動作都是「誰對哪個群組做了什麼」。
    private var bodyDescriptor: (key: LedgerStringKey, arguments: [CVarArg])? {
        switch action {
        case "transaction.created":
            return (.notificationBodyTransactionCreated, [actorDisplayName, groupName])
        case "transaction.updated":
            return (.notificationBodyTransactionUpdated, [actorDisplayName, groupName])
        case "transaction.voided":
            return (.notificationBodyTransactionVoided, [actorDisplayName, groupName])
        case "member.invitation.resent":
            return (.notificationBodyMemberInvitationResent, [actorDisplayName, groupName])
        case "member.invitation.revoked":
            return (.notificationBodyMemberInvitationRevoked, [actorDisplayName, groupName])
        case "member.identity.confirmed":
            return (.notificationBodyMemberIdentityConfirmed, [actorDisplayName, groupName])
        case "member.removed":
            return (.notificationBodyMemberRemoved, [actorDisplayName, groupName])
        case "member.left":
            return (.notificationBodyMemberLeft, [actorDisplayName, groupName])
        case "group.ownership.transferred":
            return (.notificationBodyGroupOwnershipTransferred, [groupName])
        case "settlement.recorded":
            return (.notificationBodySettlementRecorded, [actorDisplayName, groupName])
        case "settlement.reversed":
            return (.notificationBodySettlementReversed, [actorDisplayName, groupName])
        default:
            return nil
        }
    }
}

/// 一個帳本目前的待結算狀態。
struct LedgerSettlementReminder: Equatable, Sendable {
    enum Direction: String, Equatable, Sendable {
        /// 目前使用者要付錢給別人。
        case owes
        /// 別人要付錢給目前使用者。
        case owed
        /// 兩個方向都有。
        case both
    }

    let groupID: UUID
    let bookID: UUID
    let groupName: String
    let bookName: String
    let direction: Direction
    /// 與目前使用者有關的建議結算筆數。
    let outstandingTransferCount: Int

    init(
        groupID: UUID,
        bookID: UUID,
        groupName: String,
        bookName: String,
        direction: Direction,
        outstandingTransferCount: Int
    ) {
        self.groupID = groupID
        self.bookID = bookID
        self.groupName = groupName
        self.bookName = bookName
        self.direction = direction
        self.outstandingTransferCount = outstandingTransferCount
    }

    /// 用來判斷「狀況有沒有變」的指紋。
    ///
    /// 只有方向或筆數變了才值得再提醒一次；金額不列入，否則每記一筆共同支出就會多
    /// 一則內容幾乎相同的提醒。
    var fingerprint: String {
        "\(direction.rawValue)#\(outstandingTransferCount)"
    }

    var notificationBody: String { localizedNotificationBody(locale: nil) }

    /// 筆數是複數規則的來源，所以整句話交給 catalog 處理，不在這裡把群組、帳本與
    /// 筆數串起來——英文的單複數會改寫動詞，中文不會，串接就沒有兩邊都對的寫法。
    func localizedNotificationBody(locale: Locale?) -> String {
        let key: LedgerStringKey
        switch direction {
        case .owes: key = .notificationBodySettlementReminderOwes
        case .owed: key = .notificationBodySettlementReminderOwed
        case .both: key = .notificationBodySettlementReminderBoth
        }
        return key.string(
            arguments: [groupName, bookName, Int64(outstandingTransferCount)],
            locale: locale
        )
    }
}

/// 排定一則通知所需要的一切。
struct LedgerNotificationRequest: Equatable, Sendable, Identifiable {
    /// 通知識別碼。重複使用同一個識別碼會取代尚未讀取的舊通知，待結算提醒就是靠這個
    /// 特性維持「每個帳本最多一則」。
    let id: String
    let category: LedgerNotificationCategory
    let title: String
    let body: String
    /// 同一個群組的通知在系統上收合成一串。
    let threadIdentifier: String
}

/// 系統層級的通知授權狀態。
enum LedgerNotificationAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    /// 安靜遞送（使用者尚未明確同意，通知只進通知中心）。
    case provisional
    /// 系統回報了無法解讀的狀態，一律當成不能送。
    case unavailable

    var allowsDelivery: Bool {
        switch self {
        case .authorized, .provisional: return true
        case .notDetermined, .denied, .unavailable: return false
        }
    }

    /// 還可以由 App 出面詢問；`denied` 之後只剩下系統設定能改。
    var canRequest: Bool { self == .notDetermined }

    var titleKey: LedgerStringKey {
        switch self {
        case .notDetermined: return .notificationAuthorizationNotDeterminedTitle
        case .denied: return .notificationAuthorizationDeniedTitle
        case .authorized: return .notificationAuthorizationAuthorizedTitle
        case .provisional: return .notificationAuthorizationProvisionalTitle
        case .unavailable: return .notificationAuthorizationUnavailableTitle
        }
    }

    /// 每個狀態都要明講「App 仍然完全可用」。通知是輔助功能，不能讓沒授權的使用者
    /// 以為自己少了帳務資料。
    var detailKey: LedgerStringKey {
        switch self {
        case .notDetermined: return .notificationAuthorizationNotDeterminedDetail
        case .denied: return .notificationAuthorizationDeniedDetail
        case .authorized: return .notificationAuthorizationAuthorizedDetail
        case .provisional: return .notificationAuthorizationProvisionalDetail
        case .unavailable: return .notificationAuthorizationUnavailableDetail
        }
    }

    var title: String { titleKey.string() }

    var detail: String { detailKey.string() }
}

/// 每個種類的開關。
///
/// 存「關掉的」而不是「開著的」：日後新增種類時，舊裝置上已經存下來的設定不會把新
/// 種類誤判成關閉，預設一律是開。
struct LedgerNotificationPreferences: Equatable, Sendable, Codable {
    private var disabledCategories: Set<String>

    static let `default` = LedgerNotificationPreferences()

    init(disabled: Set<LedgerNotificationCategory> = []) {
        disabledCategories = Set(disabled.map(\.rawValue))
    }

    func isEnabled(_ category: LedgerNotificationCategory) -> Bool {
        !disabledCategories.contains(category.rawValue)
    }

    mutating func setEnabled(_ isEnabled: Bool, for category: LedgerNotificationCategory) {
        if isEnabled {
            disabledCategories.remove(category.rawValue)
        } else {
            disabledCategories.insert(category.rawValue)
        }
    }

    var enabledCategories: [LedgerNotificationCategory] {
        LedgerNotificationCategory.allCases.filter(isEnabled)
    }

    var isAnyCategoryEnabled: Bool { !enabledCategories.isEmpty }
}
