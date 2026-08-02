import CloudKit
import CoreData
import Foundation
import Network

/// 追蹤 iCloud 同步狀態並發佈給畫面。
///
/// 判斷邏輯全部在 `LedgerSyncEventTracker` 與 `LedgerSyncStateReducer` 裡；這個
/// 類別只負責把三個系統來源翻成純值：帳號狀態、網路可用性，以及
/// `NSPersistentCloudKitContainer` 的匯入／匯出事件。狀態機留在純函式裡，才能在
/// 沒有 iCloud 帳號、沒有網路的測試機器上驗證所有狀態組合。
@MainActor
final class SyncStatusMonitor: ObservableObject {
    typealias AccountStatusProvider = () async -> CKAccountStatus?

    @Published private(set) var state: LedgerSyncState = .undetermined
    @Published private(set) var lastSuccessfulSync: Date?

    private var tracker = LedgerSyncEventTracker() {
        didSet {
            guard tracker != oldValue else { return }
            state = tracker.state
            lastSuccessfulSync = tracker.inputs.lastSuccessfulSync
        }
    }

    private let accountStatusProvider: AccountStatusProvider
    private let container: NSPersistentCloudKitContainer?
    private let pathMonitor: NWPathMonitor?
    private var observers: [NSObjectProtocol] = []

    /// `nonisolated` 讓 `@StateObject` 可以在 View 的屬性初始式裡直接建立。這裡只
    /// 設定 stored property，不讀取任何 main actor 狀態；`state` 的預設值刻意與
    /// 空白輸入推導出的 `.undetermined` 一致，第一次 render 才不會閃過錯誤的狀態。
    nonisolated init(
        container: NSPersistentCloudKitContainer? = nil,
        accountStatusProvider: AccountStatusProvider? = nil,
        monitorsNetwork: Bool = true
    ) {
        self.container = container
        self.accountStatusProvider = accountStatusProvider ?? {
            let container = CKContainer(
                identifier: PersistenceController.cloudKitContainerIdentifier
            )
            return try? await container.accountStatus()
        }
        pathMonitor = monitorsNetwork ? NWPathMonitor() : nil
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        pathMonitor?.cancel()
    }

    /// 可以重複呼叫。SwiftUI 的 `onAppear` 會在切換分頁或返回時再次觸發，沒有這個
    /// 保護就會每次都多掛一組 observer，並對已經在跑的 `NWPathMonitor` 再 start 一次。
    func start() {
        guard observers.isEmpty else {
            // 已經在監看了，只補一次帳號狀態：離開畫面期間使用者可能登入或登出了。
            refresh()
            return
        }
        observeAccountChanges()
        observeCloudKitEvents()
        observeNetworkPath()
        Task { await refreshAccountStatus() }
    }

    /// 使用者按下「重新檢查」時呼叫。
    ///
    /// 這裡不會、也不能強制觸發一次同步：`NSPersistentCloudKitContainer` 自行排程
    /// 匯入與匯出，沒有公開的手動觸發 API。假裝按鈕能推動同步，只會在狀態沒有立刻
    /// 好轉時讓使用者更困惑，所以這個動作明確地只是重新確認狀態。
    func refresh() {
        Task { await refreshAccountStatus() }
    }

    private func refreshAccountStatus() async {
        let status = await accountStatusProvider()
        tracker.setAccountStatus(status)
    }

    private func observeAccountChanges() {
        let observer = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshAccountStatus()
            }
        }
        observers.append(observer)
    }

    private func observeCloudKitEvents() {
        guard let container else { return }
        let observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: container,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?[
                NSPersistentCloudKitContainer.eventNotificationUserInfoKey
            ] as? NSPersistentCloudKitContainer.Event else { return }
            let identifier = event.identifier
            let endDate = event.endDate
            let succeeded = event.succeeded
            let message = event.error.map(LedgerSyncErrorMessage.text(for:))
            Task { @MainActor [weak self] in
                self?.tracker.apply(
                    identifier: identifier,
                    isFinished: endDate != nil,
                    succeeded: succeeded,
                    errorMessage: message,
                    endDate: endDate
                )
            }
        }
        observers.append(observer)
    }

    private func observeNetworkPath() {
        guard let pathMonitor else { return }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let isAvailable = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.tracker.setNetworkAvailable(isAvailable)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "SyncStatusMonitor.path"))
    }
}
