import CoreData
import XCTest
@testable import SharedLedger

final class LedgerNotificationPlannerTests: XCTestCase {
    private let groupID = UUID()
    private let bookID = UUID()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    fileprivate static let zhHant = Locale(identifier: "zh-Hant")
    fileprivate static let english = Locale(identifier: "en")
    fileprivate static let supportedLocales = [zhHant, english]

    // MARK: - 稽核事件

    func testTheFirstPassOnlyTakesABaseline() {
        // 剛裝好 App 或剛接受一個共享群組時，整段歷史都是新匯入的。
        let event = makeEvent()
        let plan = LedgerNotificationPlanner.plan(
            inputs(events: [event], digest: LedgerNotificationDigest())
        )

        XCTAssertTrue(plan.requests.isEmpty)
        XCTAssertEqual(plan.digest.lastEventDate, event.createdAt)
        XCTAssertEqual(plan.digest.handledEventIDs, [event.id])
    }

    func testAnEventFromAnotherMemberIsNotified() throws {
        let event = makeEvent(action: "transaction.updated", actor: "小美")
        let plan = LedgerNotificationPlanner.plan(inputs(events: [event]))

        XCTAssertEqual(plan.requests.count, 1)
        let request = try XCTUnwrap(plan.requests.first)
        XCTAssertEqual(request.id, "audit.\(event.id.uuidString)")
        XCTAssertEqual(request.category, .transactionChange)
        // 文案本身由 catalog 決定，這裡驗的是 planner 有沒有挑對那一則；
        // 寫死正體中文的話，測試會在英文介面的模擬器上失敗。
        XCTAssertEqual(request.title, LedgerNotificationCategory.transactionChange.title)
        XCTAssertEqual(request.body, event.notificationBody)
        XCTAssertEqual(
            event.localizedNotificationBody(locale: Self.zhHant),
            "小美 修改了「家庭」的一筆交易。"
        )
        XCTAssertEqual(request.threadIdentifier, "group.\(groupID.uuidString)")
    }

    func testOwnActionsAreNotNotified() {
        // 自己按下儲存的當下就知道發生了什麼，再送一則通知只是噪音。
        let plan = LedgerNotificationPlanner.plan(
            inputs(events: [makeEvent(actor: "小明")])
        )

        XCTAssertTrue(plan.requests.isEmpty)
        XCTAssertEqual(plan.digest.handledEventIDs.count, 1)
    }

    func testStaleEventsAreNotNotified() {
        // CloudKit 匯入順序跟事件時間無關，三天前的交易可能今天才同步進來。
        let plan = LedgerNotificationPlanner.plan(
            inputs(events: [makeEvent(minutesAgo: 3 * 24 * 60)])
        )

        XCTAssertTrue(plan.requests.isEmpty)
    }

    func testDisabledCategoriesAreSkippedWhileOthersStillNotify() {
        var preferences = LedgerNotificationPreferences.default
        preferences.setEnabled(false, for: .transactionChange)

        let plan = LedgerNotificationPlanner.plan(
            inputs(
                events: [
                    makeEvent(action: "transaction.created"),
                    makeEvent(action: "member.identity.confirmed")
                ],
                preferences: preferences
            )
        )

        XCTAssertEqual(plan.requests.map(\.category), [.groupInvitation])
    }

    func testUnauthorizedRunsStillAdvanceTheBaseline() {
        // 沒授權時累積待補的通知，會讓使用者一授權就被一整週的舊事件洗版。
        let event = makeEvent()
        let denied = LedgerNotificationPlanner.plan(
            inputs(events: [event], authorization: .denied)
        )
        XCTAssertTrue(denied.requests.isEmpty)
        XCTAssertEqual(denied.digest.handledEventIDs, [event.id])

        let authorized = LedgerNotificationPlanner.plan(
            inputs(events: [event], digest: denied.digest)
        )
        XCTAssertTrue(authorized.requests.isEmpty)
    }

    func testAnEventIsNeverNotifiedTwice() {
        let event = makeEvent()
        let first = LedgerNotificationPlanner.plan(inputs(events: [event]))
        XCTAssertEqual(first.requests.count, 1)

        // 同一批事件會在每次遠端變更時重新被撈出來。
        let second = LedgerNotificationPlanner.plan(
            inputs(events: [event], digest: first.digest)
        )
        XCTAssertTrue(second.requests.isEmpty)
    }

    func testActionsWithoutANotificationAreIgnored() {
        let plan = LedgerNotificationPlanner.plan(
            inputs(
                events: [
                    makeEvent(action: "account.reconciled"),
                    makeEvent(action: "book.migrated")
                ]
            )
        )

        XCTAssertTrue(plan.requests.isEmpty)
        // 仍然要記下來，否則每一輪都會重新判斷同一批事件。
        XCTAssertEqual(plan.digest.handledEventIDs.count, 2)
    }

    func testHandledEventHistoryIsTrimmedToItsLimit() {
        let limit = LedgerNotificationPlanner.handledEventLimit
        let existing = (0..<limit).map { _ in UUID() }
        let event = makeEvent()

        let plan = LedgerNotificationPlanner.plan(
            inputs(
                events: [event],
                digest: LedgerNotificationDigest(
                    lastEventDate: now.addingTimeInterval(-3600),
                    handledEventIDs: existing
                )
            )
        )

        XCTAssertEqual(plan.digest.handledEventIDs.count, limit)
        XCTAssertEqual(plan.digest.handledEventIDs.last, event.id)
        XCTAssertFalse(plan.digest.handledEventIDs.contains(existing[0]))
    }

    // MARK: - 待結算提醒

    func testSettlementRemindersAreDeliveredOnTheFirstPass() {
        // 待結算講的是現在的狀態，不是剛剛發生的事：一筆放了三個月沒人付的款不會再
        // 產生任何新事件，等狀態變動才提醒等於永遠不提醒。
        let plan = LedgerNotificationPlanner.plan(
            inputs(settlements: [makeReminder()], digest: LedgerNotificationDigest())
        )

        XCTAssertEqual(plan.requests.count, 1)
        XCTAssertEqual(plan.requests.first?.id, "settlement.\(bookID.uuidString)")
        XCTAssertEqual(plan.requests.first?.category, .settlementReminder)
        // 比對鍵與參數，不比對文案：內文跟著裝置語言走，寫死中文會在英文模擬器上失敗。
        // 每種語言的實際措辭由 testSettlementDirectionChoosesItsWording 逐句驗。
        XCTAssertEqual(
            plan.requests.first?.body,
            LedgerStringKey.notificationBodySettlementReminderOwes
                .string(arguments: ["家庭", "日常", Int64(1)])
        )
        XCTAssertEqual(plan.digest.settlementFingerprints[bookID.uuidString], "owes#1")
        XCTAssertEqual(plan.digest.settlementRemindedAt[bookID.uuidString], now)
    }

    func testAnUnchangedSettlementIsNotRepeated() {
        let first = LedgerNotificationPlanner.plan(inputs(settlements: [makeReminder()]))
        let second = LedgerNotificationPlanner.plan(
            inputs(
                settlements: [makeReminder()],
                digest: first.digest,
                now: now.addingTimeInterval(30 * 24 * 60 * 60)
            )
        )

        XCTAssertTrue(second.requests.isEmpty)
    }

    func testAChangedSettlementWaitsForTheCooldown() {
        let digest = LedgerNotificationDigest(
            lastEventDate: now.addingTimeInterval(-3600),
            settlementFingerprints: [bookID.uuidString: "owes#1"],
            settlementRemindedAt: [bookID.uuidString: now.addingTimeInterval(-3600)]
        )
        let changed = makeReminder(direction: .owes, count: 2)

        let tooSoon = LedgerNotificationPlanner.plan(
            inputs(settlements: [changed], digest: digest)
        )
        XCTAssertTrue(tooSoon.requests.isEmpty)
        // 指紋沒有被記下來，冷卻結束後這個變化仍然提得動。
        XCTAssertEqual(tooSoon.digest.settlementFingerprints[bookID.uuidString], "owes#1")

        let later = LedgerNotificationPlanner.plan(
            inputs(
                settlements: [changed],
                digest: tooSoon.digest,
                now: now.addingTimeInterval(LedgerNotificationPlanner.minimumSettlementInterval)
            )
        )
        XCTAssertEqual(later.requests.count, 1)
        XCTAssertEqual(later.digest.settlementFingerprints[bookID.uuidString], "owes#2")
    }

    func testASettledBookForgetsItsReminder() {
        let first = LedgerNotificationPlanner.plan(inputs(settlements: [makeReminder()]))
        let settled = LedgerNotificationPlanner.plan(
            inputs(
                settlements: [makeReminder(count: 0)],
                digest: first.digest,
                now: now.addingTimeInterval(60)
            )
        )

        XCTAssertTrue(settled.requests.isEmpty)
        // 忘掉紀錄，下次再欠時才能立刻提醒，而不是等冷卻時間。
        XCTAssertNil(settled.digest.settlementFingerprints[bookID.uuidString])
        XCTAssertNil(settled.digest.settlementRemindedAt[bookID.uuidString])
    }

    func testTurningTheSettlementCategoryOnRemindsImmediately() {
        var preferences = LedgerNotificationPreferences.default
        preferences.setEnabled(false, for: .settlementReminder)

        let off = LedgerNotificationPlanner.plan(
            inputs(settlements: [makeReminder()], preferences: preferences)
        )
        XCTAssertTrue(off.requests.isEmpty)
        // 關著的時候不留指紋，否則打開後要等到欠款金額變動才會有第一則提醒。
        XCTAssertTrue(off.digest.settlementFingerprints.isEmpty)

        let on = LedgerNotificationPlanner.plan(
            inputs(settlements: [makeReminder()], digest: off.digest)
        )
        XCTAssertEqual(on.requests.count, 1)
    }

    func testSettlementDirectionChoosesItsWording() {
        XCTAssertEqual(
            makeReminder(direction: .owed, count: 2)
                .localizedNotificationBody(locale: Self.zhHant),
            "「家庭」的「日常」還有 2 筆款項尚未付給你。"
        )
        XCTAssertEqual(
            makeReminder(direction: .both, count: 3)
                .localizedNotificationBody(locale: Self.zhHant),
            "「家庭」的「日常」還有 3 筆款項尚未結清。"
        )
    }

    func testSettlementRemindersUseEnglishPluralRules() {
        // 中文沒有單複數變化，所以複數規則有沒有真的接上，只有英文看得出來。
        // catalog 的 plural variation 若沒編進 `.stringsdict`，這裡會拿到同一句。
        let one = makeReminder(direction: .owes, count: 1)
            .localizedNotificationBody(locale: Self.english)
        let many = makeReminder(direction: .owes, count: 4)
            .localizedNotificationBody(locale: Self.english)

        XCTAssertTrue(one.contains("1 payment "), one)
        XCTAssertTrue(many.contains("4 payments "), many)
        XCTAssertNotEqual(one, many)
    }

    // MARK: - 內容

    func testEveryNotifiableActionHasAWordingWithoutAmounts() throws {
        // 通知會顯示在鎖定畫面上，金額是這個 App 裡最敏感的資料。
        let actions = [
            "transaction.created", "transaction.updated", "transaction.voided",
            "settlement.recorded", "settlement.reversed", "member.left",
            "member.removed", "member.identity.confirmed", "member.invitation.resent",
            "member.invitation.revoked", "group.ownership.transferred"
        ]
        for action in actions {
            XCTAssertNotNil(LedgerNotificationCategory(auditAction: action), action)
            for locale in Self.supportedLocales {
                let body = try XCTUnwrap(
                    makeEvent(action: action).localizedNotificationBody(locale: locale),
                    "\(action) / \(locale.identifier)"
                )
                XCTAssertFalse(
                    body.contains { $0.isASCII && $0.isNumber },
                    "\(action) / \(locale.identifier)"
                )
                // 沒翻到的鍵會原封不動掉出鍵名，那也是一種「有文字」，要另外擋。
                XCTAssertFalse(body.contains("notification.body."), body)
            }
        }
    }

    func testAuditActionsMapOntoTheCategoryTheUserWouldSwitchOff() {
        XCTAssertEqual(
            LedgerNotificationCategory(auditAction: "transaction.voided"),
            .transactionChange
        )
        XCTAssertEqual(
            LedgerNotificationCategory(auditAction: "member.left"),
            .groupInvitation
        )
        XCTAssertEqual(
            LedgerNotificationCategory(auditAction: "settlement.recorded"),
            .settlementReminder
        )
        XCTAssertNil(LedgerNotificationCategory(auditAction: "account.balance.adjusted"))
    }

    // MARK: - Helpers

    private func inputs(
        events: [LedgerAuditEventSummary] = [],
        settlements: [LedgerSettlementReminder] = [],
        preferences: LedgerNotificationPreferences = .default,
        authorization: LedgerNotificationAuthorization = .authorized,
        digest: LedgerNotificationDigest? = nil,
        now: Date? = nil
    ) -> LedgerNotificationPlanner.Inputs {
        LedgerNotificationPlanner.Inputs(
            events: events,
            settlements: settlements,
            currentActorNames: [groupID: "小明"],
            preferences: preferences,
            authorization: authorization,
            // 預設一份已經取過基準的 digest：第一次執行不通知的規則另外測。
            digest: digest ?? LedgerNotificationDigest(
                lastEventDate: self.now.addingTimeInterval(-3600)
            ),
            now: now ?? self.now
        )
    }

    private func makeEvent(
        action: String = "transaction.updated",
        actor: String = "小美",
        minutesAgo: Double = 1
    ) -> LedgerAuditEventSummary {
        LedgerAuditEventSummary(
            id: UUID(),
            groupID: groupID,
            groupName: "家庭",
            action: action,
            actorDisplayName: actor,
            createdAt: now.addingTimeInterval(-minutesAgo * 60)
        )
    }

    private func makeReminder(
        direction: LedgerSettlementReminder.Direction = .owes,
        count: Int = 1
    ) -> LedgerSettlementReminder {
        LedgerSettlementReminder(
            groupID: groupID,
            bookID: bookID,
            groupName: "家庭",
            bookName: "日常",
            direction: direction,
            outstandingTransferCount: count
        )
    }
}

final class LedgerNotificationPreferencesTests: XCTestCase {
    func testEveryCategoryStartsEnabled() {
        let preferences = LedgerNotificationPreferences.default
        XCTAssertTrue(LedgerNotificationCategory.allCases.allSatisfy(preferences.isEnabled))
        XCTAssertTrue(preferences.isAnyCategoryEnabled)
    }

    func testTurningACategoryOffLeavesTheOthersAlone() {
        var preferences = LedgerNotificationPreferences.default
        preferences.setEnabled(false, for: .settlementReminder)

        XCTAssertFalse(preferences.isEnabled(.settlementReminder))
        XCTAssertEqual(
            preferences.enabledCategories,
            [.groupInvitation, .transactionChange]
        )

        preferences.setEnabled(true, for: .settlementReminder)
        XCTAssertTrue(preferences.isEnabled(.settlementReminder))
    }

    func testStoredSettingsFromAnOlderBuildDefaultNewCategoriesOn() throws {
        // 只保存「關掉的」種類，日後新增種類時舊裝置上的設定才不會把它誤判成關閉。
        let stored = Data(#"{"disabledCategories":["transactionChange"]}"#.utf8)
        let preferences = try JSONDecoder().decode(
            LedgerNotificationPreferences.self,
            from: stored
        )

        XCTAssertFalse(preferences.isEnabled(.transactionChange))
        XCTAssertTrue(preferences.isEnabled(.groupInvitation))
        XCTAssertTrue(preferences.isEnabled(.settlementReminder))
    }

    func testPreferencesAndDigestSurviveAStoreRoundTrip() throws {
        let suiteName = "LedgerNotificationStore-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let store = LedgerNotificationStore(defaults: defaults)

        var preferences = LedgerNotificationPreferences.default
        preferences.setEnabled(false, for: .groupInvitation)
        store.save(preferences)
        XCTAssertEqual(store.loadPreferences(), preferences)

        let digest = LedgerNotificationDigest(
            lastEventDate: Date(timeIntervalSince1970: 1_800_000_000),
            handledEventIDs: [UUID()],
            settlementFingerprints: ["book": "owes#2"],
            settlementRemindedAt: ["book": Date(timeIntervalSince1970: 1_800_000_100)]
        )
        store.save(digest)
        XCTAssertEqual(store.loadDigest(), digest)
    }

    func testAnEmptyStoreFallsBackToTheDefaults() throws {
        let suiteName = "LedgerNotificationStore-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let store = LedgerNotificationStore(defaults: defaults)

        XCTAssertEqual(store.loadPreferences(), .default)
        XCTAssertEqual(store.loadDigest(), LedgerNotificationDigest())
    }

    func testOnlyGrantedAuthorizationsAllowDelivery() {
        // 「未授權時仍能正常使用 App」的另一半：未授權就一則都不送。
        XCTAssertTrue(LedgerNotificationAuthorization.authorized.allowsDelivery)
        XCTAssertTrue(LedgerNotificationAuthorization.provisional.allowsDelivery)
        XCTAssertFalse(LedgerNotificationAuthorization.notDetermined.allowsDelivery)
        XCTAssertFalse(LedgerNotificationAuthorization.denied.allowsDelivery)
        XCTAssertFalse(LedgerNotificationAuthorization.unavailable.allowsDelivery)
        // 被拒絕之後只剩系統設定能改，App 不該再問一次。
        XCTAssertTrue(LedgerNotificationAuthorization.notDetermined.canRequest)
        XCTAssertFalse(LedgerNotificationAuthorization.denied.canRequest)
    }
}

/// 記下被排定的通知，取代 `UNUserNotificationCenter`。
private final class RecordingScheduler: LedgerNotificationScheduling {
    var authorization: LedgerNotificationAuthorization
    private(set) var scheduled: [LedgerNotificationRequest] = []

    init(authorization: LedgerNotificationAuthorization = .authorized) {
        self.authorization = authorization
    }

    func authorizationStatus() async -> LedgerNotificationAuthorization { authorization }

    func requestAuthorization() async -> LedgerNotificationAuthorization {
        authorization = .authorized
        return authorization
    }

    func schedule(_ requests: [LedgerNotificationRequest]) async {
        scheduled.append(contentsOf: requests)
    }
}

@MainActor
final class LedgerNotificationCoordinatorTests: XCTestCase {
    func testAnotherMembersEditBecomesANotification() async throws {
        let fixture = try makeFixture()

        // 第一輪只取基準，之後匯入的稽核事件才會通知。
        await fixture.coordinator.process()
        try fixture.insertAuditEvent(action: "transaction.updated", actor: "小美")
        await fixture.coordinator.process()

        XCTAssertEqual(fixture.scheduler.scheduled.count, 1)
        XCTAssertEqual(fixture.scheduler.scheduled.first?.category, .transactionChange)
        XCTAssertEqual(
            fixture.scheduler.scheduled.first?.body,
            LedgerStringKey.notificationBodyTransactionUpdated
                .string(arguments: ["小美", "家庭"])
        )
    }

    func testYourOwnEditsNeverNotifyYou() async throws {
        let fixture = try makeFixture()
        await fixture.coordinator.process()

        // 目前使用者是群組擁有者小明，repository 會用他的名字寫下稽核紀錄。
        try fixture.addExpense()
        await fixture.coordinator.process()

        XCTAssertTrue(fixture.scheduler.scheduled.isEmpty)
    }

    func testNothingIsScheduledWithoutAuthorization() async throws {
        let fixture = try makeFixture(authorization: .denied)
        await fixture.coordinator.process()
        try fixture.insertAuditEvent(action: "member.identity.confirmed", actor: "小美")
        await fixture.coordinator.process()

        XCTAssertTrue(fixture.scheduler.scheduled.isEmpty)
        // App 本身完全不受影響：帳務仍然照常寫入。
        XCTAssertNoThrow(try fixture.addExpense())
    }

    func testASwitchedOffCategoryStopsItsNotifications() async throws {
        let fixture = try makeFixture()
        fixture.coordinator.setEnabled(false, for: .transactionChange)
        await fixture.coordinator.process()

        try fixture.insertAuditEvent(action: "transaction.created", actor: "小美")
        try fixture.insertAuditEvent(action: "member.left", actor: "小美")
        await fixture.coordinator.process()

        XCTAssertEqual(fixture.scheduler.scheduled.map(\.category), [.groupInvitation])
    }

    private func makeFixture(
        authorization: LedgerNotificationAuthorization = .authorized
    ) throws -> NotificationFixture {
        let persistence = PersistenceController(inMemory: true)
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(name: "家庭", ownerDisplayName: "小明", currencyCode: "TWD")
        )
        let owner = try XCTUnwrap((group.members as? Set<Member>)?.first)
        let book = try XCTUnwrap(BookRepository(persistence: persistence).defaultBook(in: group))
        let account = try AccountRepository(persistence: persistence).createAccount(
            from: AccountDraft(name: "現金"),
            in: group
        )
        CurrentMemberIdentityRepository(persistence: persistence)
            .setCurrentMember(owner, in: group)
        try persistence.container.viewContext.save()

        let suiteName = "LedgerNotificationCoordinator-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let scheduler = RecordingScheduler(authorization: authorization)

        return NotificationFixture(
            persistence: persistence,
            group: group,
            book: book,
            account: account,
            owner: owner,
            scheduler: scheduler,
            coordinator: LedgerNotificationCoordinator(
                persistence: persistence,
                store: LedgerNotificationStore(defaults: defaults),
                scheduler: scheduler,
                coalescingDelay: 0
            )
        )
    }
}

@MainActor
private struct NotificationFixture {
    let persistence: PersistenceController
    let group: LedgerGroup
    let book: LedgerBook
    let account: LedgerAccount
    let owner: Member
    let scheduler: RecordingScheduler
    let coordinator: LedgerNotificationCoordinator

    /// 模擬其他成員的動作同步進來。
    func insertAuditEvent(action: String, actor: String) throws {
        let context = persistence.container.viewContext
        let audit = AuditEvent(context: context)
        context.assign(audit, to: persistence.store(for: group))
        audit.id = UUID()
        audit.action = action
        audit.actorDisplayName = actor
        audit.createdAt = Date()
        audit.summary = "測試事件"
        audit.group = group
        try context.save()
    }

    @discardableResult
    func addExpense() throws -> LedgerEntry {
        let ownerID = try XCTUnwrap(owner.id)
        return try EntryRepository(persistence: persistence).createEntry(
            from: TransactionDraft(
                kind: .expense,
                amountText: "100",
                date: Date(),
                sourceAccountID: account.id,
                payerMemberID: ownerID,
                splitMemberIDs: [ownerID]
            ),
            in: book,
            accounts: Array(group.accounts as? Set<LedgerAccount> ?? []),
            categories: Array(group.categories as? Set<LedgerCategory> ?? []),
            members: Array(group.members as? Set<Member> ?? [])
        )
    }
}
