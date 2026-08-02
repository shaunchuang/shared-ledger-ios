import CloudKit
import Foundation

/// 使用者看得到的 iCloud 同步狀態。
enum LedgerSyncState: Equatable, Sendable {
    /// 這台裝置沒有登入 iCloud，帳務只會留在本機。
    case signedOut
    /// iCloud 被家長控制或裝置管理停用。
    case restricted
    /// 問不到帳號狀態，通常是暫時性的。
    case undetermined
    case offline
    case syncing
    case upToDate
    /// 最近一次同步失敗，附上可以顯示給使用者的原因。
    case failed(String)
}

/// 推導同步狀態所需的全部輸入。
///
/// 收成一個值型別，狀態機才能在沒有 CloudKit、沒有網路、沒有 Core Data 的情況下
/// 被完整測試——同步狀態最需要驗證的正是那些難以在真機上重現的組合。
struct LedgerSyncInputs: Equatable, Sendable {
    /// `nil` 代表還沒問到結果，例如 App 剛啟動。
    var accountStatus: CKAccountStatus?
    var isNetworkAvailable: Bool
    /// 目前有沒有進行中的匯入或匯出事件。
    var hasActiveEvent: Bool
    /// 最近一次結束的事件是否失敗，附上錯誤描述。
    var lastEventError: String?
    var lastSuccessfulSync: Date?

    init(
        accountStatus: CKAccountStatus? = nil,
        isNetworkAvailable: Bool = true,
        hasActiveEvent: Bool = false,
        lastEventError: String? = nil,
        lastSuccessfulSync: Date? = nil
    ) {
        self.accountStatus = accountStatus
        self.isNetworkAvailable = isNetworkAvailable
        self.hasActiveEvent = hasActiveEvent
        self.lastEventError = lastEventError
        self.lastSuccessfulSync = lastSuccessfulSync
    }
}

/// 把 CloudKit 錯誤翻成使用者看得懂、而且照著做得到的說明。
///
/// 和其他同步文案放在一起，是因為它們要一起讀才看得出語氣是否一致；
/// `CKError.localizedDescription` 多半是給開發者看的英文技術訊息。
enum LedgerSyncErrorMessage {
    static func text(for error: Error) -> String {
        guard let ckError = error as? CKError else {
            return error.localizedDescription
        }
        switch ckError.code {
        case .networkUnavailable, .networkFailure:
            return "無法連線到 iCloud，請確認網路後再試。"
        case .notAuthenticated:
            return "iCloud 尚未完成登入，請到「設定 → Apple 帳號」確認登入狀態。"
        case .quotaExceeded:
            return "iCloud 儲存空間不足，請釋出空間後再同步。"
        case .zoneBusy, .serviceUnavailable, .requestRateLimited:
            return "iCloud 服務忙碌中，稍後會自動重試。"
        case .permissionFailure:
            return "沒有這筆共享資料的寫入權限，請確認分享設定。"
        default:
            return ckError.localizedDescription
        }
    }
}

/// 累積 CloudKit 匯入／匯出事件，維護推導狀態所需的輸入。
///
/// 一次同步會先送出開始事件（尚無結束時間）再送出結束事件，而匯入與匯出可能重疊。
/// 以識別碼記錄進行中的事件，才不會在其中一項先結束時就提早收掉「同步中」。
/// 這裡刻意只收 primitive：`NSPersistentCloudKitContainer.Event` 無法在測試中建構，
/// 但事件的先後與重疊正是最需要驗證的部分。
struct LedgerSyncEventTracker: Equatable, Sendable {
    private(set) var inputs = LedgerSyncInputs()
    private var activeIdentifiers: Set<UUID> = []

    init(inputs: LedgerSyncInputs = LedgerSyncInputs()) {
        self.inputs = inputs
    }

    var state: LedgerSyncState { LedgerSyncStateReducer.state(from: inputs) }

    mutating func setAccountStatus(_ status: CKAccountStatus?) {
        inputs.accountStatus = status
    }

    mutating func setNetworkAvailable(_ isAvailable: Bool) {
        inputs.isNetworkAvailable = isAvailable
    }

    mutating func apply(
        identifier: UUID,
        isFinished: Bool,
        succeeded: Bool,
        errorMessage: String?,
        endDate: Date?
    ) {
        if isFinished {
            activeIdentifiers.remove(identifier)
        } else {
            activeIdentifiers.insert(identifier)
        }
        inputs.hasActiveEvent = !activeIdentifiers.isEmpty

        guard isFinished else { return }
        if succeeded {
            // 一次成功就清掉先前的錯誤：失敗的原因已經不成立了，繼續顯示只會讓
            // 使用者以為問題還在。
            inputs.lastEventError = nil
            inputs.lastSuccessfulSync = endDate ?? Date()
        } else if let errorMessage {
            inputs.lastEventError = errorMessage
        }
    }
}

enum LedgerSyncStateReducer {
    /// 把各項輸入收斂成單一狀態。
    ///
    /// 順序就是優先權，而優先權的依據是「使用者現在能做什麼」：帳號問題最優先，
    /// 因為在解決之前其他狀態都不會改變；離線排在失敗之前，因為離線本身就解釋了
    /// 失敗，顯示「同步失敗」只會讓人以為資料出了問題。
    static func state(from inputs: LedgerSyncInputs) -> LedgerSyncState {
        switch inputs.accountStatus {
        case .noAccount:
            return .signedOut
        case .restricted:
            return .restricted
        case .couldNotDetermine, .temporarilyUnavailable:
            return .undetermined
        case .none:
            // 還沒問到帳號狀態時，網路狀態仍然值得先講。
            return inputs.isNetworkAvailable ? .undetermined : .offline
        case .available:
            break
        @unknown default:
            return .undetermined
        }

        guard inputs.isNetworkAvailable else { return .offline }
        if inputs.hasActiveEvent { return .syncing }
        if let error = inputs.lastEventError { return .failed(error) }
        return .upToDate
    }
}

extension LedgerSyncState {
    var title: String {
        switch self {
        case .signedOut: return "未登入 iCloud"
        case .restricted: return "iCloud 受到限制"
        case .undetermined: return "正在確認 iCloud"
        case .offline: return "離線"
        case .syncing: return "同步中"
        case .upToDate: return "已同步"
        case .failed: return "同步失敗"
        }
    }

    /// 每個狀態都要說清楚「資料還在不在」與「接下來該做什麼」。同步狀態最怕的是
    /// 讓使用者以為記到一半的帳消失了。
    func detail(lastSuccessfulSync: Date?) -> String {
        switch self {
        case .signedOut:
            return "這台裝置尚未登入 iCloud，帳務只會保存在本機，也不會與其他成員共享。到「設定 → Apple 帳號」登入並開啟 iCloud 雲碟後就會開始同步。"
        case .restricted:
            return "這個 Apple 帳號的 iCloud 被家長控制或裝置管理停用。帳務仍可正常記錄在本機，但無法同步或共享。"
        case .undetermined:
            return "正在確認 iCloud 帳號狀態。這段期間仍可正常記帳，資料會保存在本機。"
        case .offline:
            return "目前沒有網路連線。仍可正常記帳，恢復連線後會自動同步，不需要重新輸入。"
        case .syncing:
            return "正在與 iCloud 同步。這段期間仍可正常記帳。"
        case .upToDate:
            guard let lastSuccessfulSync else {
                return "已連上 iCloud。新的變更會自動同步。"
            }
            return "最後同步時間：\(Self.timestampText(lastSuccessfulSync))。"
        case .failed(let reason):
            return "最近一次同步沒有完成，資料仍完整保存在本機。iCloud 會自動重試，你也可以手動重新檢查。\n\n原因：\(reason)"
        }
    }

    /// 值得請使用者採取行動的狀態。其餘狀態會自行恢復，放一顆按鈕只會讓人以為
    /// 不按就不會好。
    var suggestsRetry: Bool {
        switch self {
        case .failed, .undetermined, .offline: return true
        case .signedOut, .restricted, .syncing, .upToDate: return false
        }
    }

    /// 本機資料是否完整。任何狀態下都是完整的，這個屬性存在是為了讓畫面永遠
    /// 講得出這句話，而不是只在想到的時候才講。
    var keepsLocalDataIntact: Bool { true }

    private static func timestampText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
