import CoreData
import XCTest
@testable import SharedLedger

/// 刪除只存在這台裝置的個人資料。
///
/// 重點在「刪掉的剛好是那三份、而且只有那三份」：帳務資料一筆都不能少，否則這個
/// 功能就從隱私控制變成資料遺失。
@MainActor
final class LocalPersonalDataTests: XCTestCase {
    /// 每個測試各自一個 `UserDefaults` suite：這些測試會寫入通知偏好與權限快取，
    /// 用共用的 standard defaults 等於改動執行測試那台機器的真實設定。
    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "LocalPersonalDataTests-\(UUID().uuidString)"
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        return try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    func testSummaryCountsWhatIsActuallyStored() throws {
        let fixture = try makeFixture(defaults: try makeDefaults())

        let summary = fixture.repository.summary()

        XCTAssertEqual(summary.identityMappingCount, 1)
        XCTAssertTrue(summary.hasNotificationData)
        XCTAssertEqual(summary.cachedPermissionCount, 1)
        XCTAssertFalse(summary.isEmpty)
    }

    func testNothingStoredReadsAsEmpty() throws {
        let defaults = try makeDefaults()
        let persistence = PersistenceController(inMemory: true)
        let repository = LocalPersonalDataRepository(
            persistence: persistence,
            notificationStore: LedgerNotificationStore(defaults: defaults),
            permissionCache: CloudPermissionCache(defaults: defaults)
        )

        XCTAssertTrue(repository.summary().isEmpty)
    }

    func testDeletingClearsAllThreeKindsOfLocalState() throws {
        let defaults = try makeDefaults()
        let fixture = try makeFixture(defaults: defaults)

        try fixture.repository.deleteAll()

        XCTAssertTrue(fixture.repository.summary().isEmpty)
        XCTAssertEqual(try fixture.count(of: "LocalMemberIdentity"), 0)
        XCTAssertEqual(
            LedgerNotificationStore(defaults: defaults).loadPreferences(),
            .default
        )
        XCTAssertNil(
            CloudPermissionCache(defaults: defaults)
                .lastKnownWritePermission(for: fixture.group)
        )
    }

    func testDeletingKeepsEveryPieceOfLedgerData() throws {
        let fixture = try makeFixture(defaults: try makeDefaults())
        try fixture.addExpense(1000)

        try fixture.repository.deleteAll()

        XCTAssertEqual(try fixture.count(of: "LedgerGroup"), 1)
        XCTAssertEqual(try fixture.count(of: "LedgerEntry"), 1)
        XCTAssertEqual(try fixture.count(of: "EntrySplit"), 1)
        XCTAssertEqual(try fixture.count(of: "Member"), 1)
        XCTAssertEqual(fixture.group.name, "家庭")
    }

    func testDeletingMakesASharedGroupAskWhoYouAreAgain() throws {
        let fixture = try makeFixture(defaults: try makeDefaults())
        let identities = CurrentMemberIdentityRepository(persistence: fixture.persistence)
        XCTAssertNotNil(identities.mappedMember(in: fixture.group))

        try fixture.repository.deleteAll()

        // 對應沒了，共享群組就必須重新確認身分——這正是刪除本機個人資料該有的後果，
        // 而不是靜悄悄地繼續用舊的對應。
        XCTAssertNil(identities.mappedMember(in: fixture.group))
    }

    // MARK: - Fixture

    private func makeFixture(defaults: UserDefaults) throws -> LocalDataFixture {
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

        let notificationStore = LedgerNotificationStore(defaults: defaults)
        var preferences = LedgerNotificationPreferences.default
        preferences.setEnabled(false, for: .transactionChange)
        notificationStore.save(preferences)

        let permissionCache = CloudPermissionCache(defaults: defaults)
        permissionCache.store(true, for: group)

        return LocalDataFixture(
            persistence: persistence,
            group: group,
            book: book,
            account: account,
            owner: owner,
            repository: LocalPersonalDataRepository(
                persistence: persistence,
                notificationStore: notificationStore,
                permissionCache: permissionCache
            )
        )
    }
}

@MainActor
private struct LocalDataFixture {
    let persistence: PersistenceController
    let group: LedgerGroup
    let book: LedgerBook
    let account: LedgerAccount
    let owner: Member
    let repository: LocalPersonalDataRepository

    func count(of entityName: String) throws -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        return try persistence.container.viewContext.count(for: request)
    }

    @discardableResult
    func addExpense(_ amount: Int) throws -> LedgerEntry {
        let ownerID = try XCTUnwrap(owner.id)
        return try EntryRepository(persistence: persistence).createEntry(
            from: TransactionDraft(
                kind: .expense,
                amountText: "\(amount)",
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
