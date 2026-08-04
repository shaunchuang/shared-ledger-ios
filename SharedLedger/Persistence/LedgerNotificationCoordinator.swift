import CoreData
import Foundation

/// 把共享資料的變動變成本機通知，並持有使用者的通知偏好。
///
/// 這個 App 沒有自己的伺服器，`NSPersistentCloudKitContainer` 收到的推播是靜默的、
/// 只用來觸發同步。所以「其他成員做了什麼」這件事只能在同步完成之後、由這台裝置自己
/// 從稽核紀錄裡讀出來再送出本機通知。判斷全部委託給 `LedgerNotificationPlanner`；
/// 這個類別只負責蒐集輸入、保存 digest，以及把結果交給排程器。
@MainActor
final class LedgerNotificationCoordinator: ObservableObject {
    static let shared = LedgerNotificationCoordinator()

    @Published private(set) var authorization: LedgerNotificationAuthorization = .notDetermined
    @Published private(set) var preferences: LedgerNotificationPreferences

    private let persistence: PersistenceController
    private let store: LedgerNotificationStore
    private let scheduler: LedgerNotificationScheduling
    /// 收到遠端變更後等多久才處理，用來把一整串匯入合併成一次。
    private let coalescingDelay: TimeInterval
    /// 兩次待結算掃描之間至少間隔多久。
    private let settlementScanInterval: TimeInterval

    private var observers: [NSObjectProtocol] = []
    private var isProcessing = false
    private var shouldProcessAgain = false
    private var lastSettlementScan: Date?

    init(
        persistence: PersistenceController = .shared,
        store: LedgerNotificationStore = .standard,
        scheduler: LedgerNotificationScheduling = SystemNotificationScheduler(),
        coalescingDelay: TimeInterval = 2,
        settlementScanInterval: TimeInterval = 30 * 60
    ) {
        self.persistence = persistence
        self.store = store
        self.scheduler = scheduler
        self.coalescingDelay = coalescingDelay
        self.settlementScanInterval = settlementScanInterval
        preferences = store.loadPreferences()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// 偏好在別處被清掉之後重新讀一次。
    ///
    /// 目前唯一的呼叫端是「刪除本機個人資料」：協調器活在 App 層並把偏好留在記憶體，
    /// 沒有這一步，設定頁的開關會維持在已經不存在的舊值。
    func reloadPreferences() {
        preferences = store.loadPreferences()
    }

    /// 可以重複呼叫；App 每次回到前景都會再叫一次。
    ///
    /// 這裡不會主動詢問通知權限。啟動就跳出授權對話框，等於在使用者還不知道通知有什麼
    /// 用之前先要一次權限，被拒絕之後就只剩系統設定能救。詢問留給通知設定頁。
    func start() {
        Task { await refreshAuthorization() }
        guard observers.isEmpty else {
            scheduleProcessing()
            return
        }
        let observer = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: persistence.container.persistentStoreCoordinator,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleProcessing()
            }
        }
        observers.append(observer)
        scheduleProcessing()
    }

    func refreshAuthorization() async {
        authorization = await scheduler.authorizationStatus()
    }

    /// 由通知設定頁在使用者主動要求時呼叫。
    func requestAuthorization() async {
        authorization = await scheduler.requestAuthorization()
        guard authorization.allowsDelivery else { return }
        scheduleProcessing()
    }

    func setEnabled(_ isEnabled: Bool, for category: LedgerNotificationCategory) {
        guard preferences.isEnabled(category) != isEnabled else { return }
        preferences.setEnabled(isEnabled, for: category)
        store.save(preferences)
        // 剛打開待結算提醒時，未結清的款項不會為了這件事再變動一次，所以這裡要主動
        // 重跑一輪，否則使用者要等到有人記帳才收得到第一則提醒。
        guard isEnabled else { return }
        lastSettlementScan = nil
        scheduleProcessing()
    }

    /// 合併連續觸發並排入一次處理。
    ///
    /// CloudKit 匯入會一次丟出大量遠端變更通知，每一次都跑一輪稽核事件與待結算掃描，
    /// 會在同步期間把主執行緒吃光。做法與 `PersistenceController.scheduleDataRepair`
    /// 一致：處理中再來的觸發只記一個旗標，等這輪結束後再補跑一次。
    private func scheduleProcessing() {
        if isProcessing {
            shouldProcessAgain = true
            return
        }
        isProcessing = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isProcessing = false }
            repeat {
                self.shouldProcessAgain = false
                if self.coalescingDelay > 0 {
                    try? await Task.sleep(
                        nanoseconds: UInt64(self.coalescingDelay * Double(NSEC_PER_SEC))
                    )
                }
                await self.process()
            } while self.shouldProcessAgain
        }
    }

    /// 蒐集輸入、排定通知、保存 digest。
    ///
    /// digest 一定要存回去，即使一則都沒送：它同時記錄「已經看過哪些事件」，少存一次
    /// 就會在下一輪重複通知。
    func process() async {
        let authorization = await scheduler.authorizationStatus()
        self.authorization = authorization

        let now = Date()
        let digest = store.loadDigest()
        let plan = LedgerNotificationPlanner.plan(
            LedgerNotificationPlanner.Inputs(
                events: recentAuditEvents(now: now),
                settlements: settlementReminders(now: now),
                currentActorNames: currentActorNames(),
                preferences: preferences,
                authorization: authorization,
                digest: digest,
                now: now
            )
        )
        store.save(plan.digest)

        guard !plan.requests.isEmpty else { return }
        await scheduler.schedule(plan.requests)
    }

    /// 判斷窗口內的稽核事件。
    ///
    /// 只取 `maximumEventAge` 以內：更舊的事件 planner 一律不通知，撈進來只是多讀一
    /// 堆資料。重複與否交給 digest 裡的識別碼判斷，不用時間當去重依據——CloudKit 匯入
    /// 的順序本來就跟事件時間無關。
    private func recentAuditEvents(now: Date) -> [LedgerAuditEventSummary] {
        let request = NSFetchRequest<AuditEvent>(entityName: "AuditEvent")
        request.predicate = NSPredicate(
            format: "createdAt >= %@",
            now.addingTimeInterval(-LedgerNotificationPlanner.maximumEventAge) as NSDate
        )
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \AuditEvent.createdAt, ascending: true)
        ]
        let events = (try? persistence.container.viewContext.fetch(request)) ?? []

        return events.compactMap { event in
            guard let id = event.id,
                  let group = event.group,
                  let groupID = group.id,
                  let action = event.action,
                  let createdAt = event.createdAt
            else { return nil }
            return LedgerAuditEventSummary(
                id: id,
                groupID: groupID,
                groupName: group.name ?? LedgerStringKey.commonPlaceholderUnnamedGroup.string(),
                action: action,
                actorDisplayName: event.actorDisplayName
                    ?? LedgerStringKey.defaultMemberGroupMember.string(),
                createdAt: createdAt
            )
        }
    }

    /// 每個啟用中帳本裡，與目前使用者有關的待結算狀態。
    ///
    /// 這一趟要把每個帳本的交易全部重算一次淨額，是這個流程裡最貴的部分，所以先擋掉
    /// 結果一定會被丟掉的情況（沒授權、種類關著），再限制掃描頻率。planner 仍然會各自
    /// 檢查一次；這裡的判斷只是為了不做白工，不是把規則搬過來。
    private func settlementReminders(now: Date) -> [LedgerSettlementReminder] {
        guard authorization.allowsDelivery,
              preferences.isEnabled(.settlementReminder)
        else { return [] }
        if let lastSettlementScan,
           now.timeIntervalSince(lastSettlementScan) < settlementScanInterval {
            return []
        }
        lastSettlementScan = now

        let request = NSFetchRequest<LedgerGroup>(entityName: "LedgerGroup")
        let groups = (try? persistence.container.viewContext.fetch(request)) ?? []
        let identities = CurrentMemberIdentityRepository(persistence: persistence)
        let books = BookRepository(persistence: persistence)
        let settlements = SettlementRepository(persistence: persistence)

        var reminders: [LedgerSettlementReminder] = []
        for group in groups {
            guard let groupID = group.id,
                  let memberID = identities.currentMember(in: group)?.id
            else { continue }

            for book in books.books(in: group) {
                guard let bookID = book.id,
                      let snapshot = try? settlements.snapshot(in: book)
                else { continue }

                let transfers = snapshot.result.suggestedTransfers.filter {
                    $0.fromMemberID == memberID || $0.toMemberID == memberID
                }
                reminders.append(
                    LedgerSettlementReminder(
                        groupID: groupID,
                        bookID: bookID,
                        groupName: group.name
                            ?? LedgerStringKey.commonPlaceholderUnnamedGroup.string(),
                        bookName: book.name
                            ?? LedgerStringKey.commonPlaceholderUnnamedBook.string(),
                        direction: direction(of: transfers, for: memberID),
                        outstandingTransferCount: transfers.count
                    )
                )
            }
        }
        return reminders
    }

    private func direction(
        of transfers: [SettlementTransfer],
        for memberID: UUID
    ) -> LedgerSettlementReminder.Direction {
        let owes = transfers.contains { $0.fromMemberID == memberID }
        let owed = transfers.contains { $0.toMemberID == memberID }
        switch (owes, owed) {
        case (true, true): return .both
        case (false, true): return .owed
        default: return .owes
        }
    }

    private func currentActorNames() -> [UUID: String] {
        let request = NSFetchRequest<LedgerGroup>(entityName: "LedgerGroup")
        let groups = (try? persistence.container.viewContext.fetch(request)) ?? []
        let identities = CurrentMemberIdentityRepository(persistence: persistence)

        var names: [UUID: String] = [:]
        for group in groups {
            guard let groupID = group.id,
                  let name = identities.currentMember(in: group)?.displayName
            else { continue }
            names[groupID] = name
        }
        return names
    }
}
