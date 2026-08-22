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
    static func text(for error: Error, locale: Locale? = nil) -> String {
        guard let ckError = error as? CKError else {
            return error.localizedDescription
        }
        guard let key = key(for: ckError.code) else {
            return ckError.localizedDescription
        }
        return key.string(locale: locale)
    }

    private static func key(for code: CKError.Code) -> LedgerStringKey? {
        switch code {
        case .networkUnavailable, .networkFailure:
            return .syncErrorNetwork
        case .notAuthenticated:
            return .syncErrorNotAuthenticated
        case .quotaExceeded:
            return .syncErrorQuotaExceeded
        case .zoneBusy, .serviceUnavailable, .requestRateLimited:
            return .syncErrorServiceBusy
        case .permissionFailure:
            return .syncErrorPermission
        default:
            return nil
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
    var titleKey: LedgerStringKey {
        switch self {
        case .signedOut: return .syncStateSignedOutTitle
        case .restricted: return .syncStateRestrictedTitle
        case .undetermined: return .syncStateUndeterminedTitle
        case .offline: return .syncStateOfflineTitle
        case .syncing: return .syncStateSyncingTitle
        case .upToDate: return .syncStateUpToDateTitle
        case .failed: return .syncStateFailedTitle
        }
    }

    var title: String { titleKey.string() }

    /// 每個狀態都要說清楚「資料還在不在」與「接下來該做什麼」。同步狀態最怕的是
    /// 讓使用者以為記到一半的帳消失了。
    func detail(lastSuccessfulSync: Date?, locale: Locale? = nil) -> String {
        switch self {
        case .signedOut:
            return LedgerStringKey.syncStateSignedOutDetail.string(locale: locale)
        case .restricted:
            return LedgerStringKey.syncStateRestrictedDetail.string(locale: locale)
        case .undetermined:
            return LedgerStringKey.syncStateUndeterminedDetail.string(locale: locale)
        case .offline:
            return LedgerStringKey.syncStateOfflineDetail.string(locale: locale)
        case .syncing:
            return LedgerStringKey.syncStateSyncingDetail.string(locale: locale)
        case .upToDate:
            guard let lastSuccessfulSync else {
                return LedgerStringKey.syncStateUpToDateDetail.string(locale: locale)
            }
            return LedgerStringKey.syncStateUpToDateDetailLastSync.string(
                arguments: [LedgerFormatters.timestamp(lastSuccessfulSync, locale: locale)],
                locale: locale
            )
        case .failed(let reason):
            return LedgerStringKey.syncStateFailedDetail.string(
                arguments: [reason],
                locale: locale
            )
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

    /// 使用者可能擔心資料已經遺失的狀態。這些狀態的說明必須明講帳務仍在本機，
    /// 否則畫面等於預設使用者知道 CloudKit 的離線行為。
    var needsLocalDataReassurance: Bool {
        switch self {
        case .signedOut, .restricted, .undetermined, .offline, .failed: return true
        case .syncing, .upToDate: return false
        }
    }
}
