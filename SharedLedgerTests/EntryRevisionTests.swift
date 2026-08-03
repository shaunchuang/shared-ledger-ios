import CoreData
import XCTest
@testable import SharedLedger

/// 兩台裝置同時編輯同一筆交易之後，這台裝置看到的資料。
///
/// CloudKit 合併的單位是 record：交易金額由最後寫入的那台勝出，但兩邊各自新增的付款
/// 與分攤是不同的 record，誰也不會蓋掉誰。這裡驗證的是「兩組明細同時存在」時，帳務
/// 計算只採用勝出的那一組，而不是把兩組加起來。
@MainActor
final class EntryRevisionTests: XCTestCase {
    // MARK: - 純值規則

    func testRowsBelongToTheEntryRevisionTheyWereWrittenFor() {
        let winning = UUID()
        let losing = UUID()
        let rows = [winning, losing, winning]

        XCTAssertEqual(
            EntryRevision.live(rows, of: winning, revision: { $0 }).count,
            2
        )
        XCTAssertEqual(
            EntryRevision.superseded(rows, of: winning, revision: { $0 }),
            [losing]
        )
    }

    func testRowsWrittenBeforeV9StayLive() {
        // 升級前的資料兩邊都是 `nil`，不做回填也必須全部算數。
        let rows: [UUID?] = [nil, nil]

        XCTAssertEqual(EntryRevision.live(rows, of: nil, revision: { $0 }).count, 2)
        XCTAssertTrue(EntryRevision.superseded(rows, of: nil, revision: { $0 }).isEmpty)
    }

    func testConsistencyComparesBothTotalsAgainstTheAmount() {
        XCTAssertEqual(
            EntryConsistency.evaluate(
                kind: .expense,
                amount: 1000,
                paymentAmounts: [600, 400],
                splitAmounts: [500, 500],
                currencyCode: "TWD"
            ),
            .balanced
        )

        // 付款與分攤彼此相等、卻都不等於交易金額：結算的驗證看不出來，
        // 因為它只比對兩邊合計。
        XCTAssertEqual(
            EntryConsistency.evaluate(
                kind: .expense,
                amount: 1000,
                paymentAmounts: [1000, 1200],
                splitAmounts: [1100, 1100],
                currencyCode: "TWD"
            ),
            .mismatched(paymentTotal: 2200, splitTotal: 2200)
        )
    }

    func testConsistencyTreatsMissingRowsAsAwaitingSync() {
        XCTAssertEqual(
            EntryConsistency.evaluate(
                kind: .expense,
                amount: 1000,
                paymentAmounts: [],
                splitAmounts: [],
                currencyCode: "TWD"
            ),
            .awaitingDetails
        )
    }

    func testTransfersAndVoidedEntriesAreOutOfScope() {
        XCTAssertEqual(
            EntryConsistency.evaluate(
                kind: .transfer,
                amount: 1000,
                paymentAmounts: [],
                splitAmounts: [],
                currencyCode: "TWD"
            ),
            .notApplicable
        )
        // 作廢會把金額歸零、明細保留原值，拿去比對必然對不上。
        XCTAssertEqual(
            EntryConsistency.evaluate(
                kind: .expense,
                amount: 0,
                paymentAmounts: [1000],
                splitAmounts: [1000],
                currencyCode: "TWD",
                isVoided: true
            ),
            .notApplicable
        )
    }

    func testConsistencyFollowsTheCurrencyMinorUnit() throws {
        // 三位小數的幣別，分攤的尾差落在第三位。
        let amount = try XCTUnwrap(Decimal(string: "10.500"))
        XCTAssertEqual(
            EntryConsistency.evaluate(
                kind: .expense,
                amount: amount,
                paymentAmounts: [amount],
                splitAmounts: [
                    try XCTUnwrap(Decimal(string: "3.501")),
                    try XCTUnwrap(Decimal(string: "6.999"))
                ],
                currencyCode: "KWD"
            ),
            .balanced
        )
    }

    // MARK: - 兩組明細同時存在時

    func testAConcurrentEditDoesNotDoubleTheSettlement() throws {
        let fixture = try makeFixture()
        let entry = try fixture.addExpense(1000)
        let baseline = try SettlementRepository(persistence: fixture.persistence)
            .snapshot(in: fixture.book)

        try fixture.importRivalEdit(on: entry, payment: 1200, splits: [600, 600])

        let merged = try SettlementRepository(persistence: fixture.persistence)
            .snapshot(in: fixture.book)

        // 沒有 revision 篩選時，付款合計 2200 與分攤合計 2200 仍然相等，結算的驗證
        // 完全看不出問題，只會把這筆交易當成 2200 元記進去。
        XCTAssertEqual(merged.result, baseline.result)
        XCTAssertEqual(merged.skippedEntryCount, 0)
        XCTAssertEqual(
            merged.result.balances.first { $0.memberID == fixture.otherID }?.amount,
            -500
        )
    }

    func testOnlyTheWinningRevisionIsVisible() throws {
        let fixture = try makeFixture()
        let entry = try fixture.addExpense(1000)
        try fixture.importRivalEdit(on: entry, payment: 1200, splits: [600, 600])

        XCTAssertEqual(entry.livePayments.count, 1)
        XCTAssertEqual(entry.liveSplits.count, 2)
        XCTAssertEqual(entry.supersededChildCount, 3)
        XCTAssertEqual(entry.consistency(isVoided: false), .balanced)

        // 交易詳情與編輯表單都從這裡取值，不能看到另一版的成員與金額。
        let draft = TransactionDraft(entry: entry)
        XCTAssertEqual(draft.paymentDrafts.count, 1)
        XCTAssertEqual(draft.splitMemberIDs.count, 2)
        XCTAssertEqual(draft.amountText, "1000")
    }

    func testEditingAnEntryReplacesEveryRowItCanSee() throws {
        let fixture = try makeFixture()
        let entry = try fixture.addExpense(1000)
        try fixture.importRivalEdit(on: entry, payment: 1200, splits: [600, 600])

        var draft = TransactionDraft(entry: entry)
        draft.amountText = "900"
        // 金額改了，付款明細也要跟著改：付款總額必須等於交易金額，只改一邊會被資料層
        // 以 `paymentTotalMismatch` 擋下來——那正是 P0-2 要求的行為，不是這裡要測的東西。
        draft.paymentDrafts = [
            TransactionPaymentDraft(
                memberID: try XCTUnwrap(fixture.owner.id),
                amountText: "900"
            )
        ]
        try fixture.update(entry, with: draft)

        // 使用者剛送出的這一版就是最新的答案，落選的那一組沒有理由留著。
        XCTAssertEqual(entry.supersededChildCount, 0)
        XCTAssertEqual(entry.livePayments.count, 1)
        XCTAssertEqual(entry.consistency(isVoided: false), .balanced)
        XCTAssertEqual(
            Set(entry.liveSplits.map { $0.entryRevisionID }),
            [entry.revisionID]
        )
    }

    func testEntriesWrittenBeforeV9KeepTheirRows() throws {
        let fixture = try makeFixture()
        let entry = try fixture.addExpense(1000)

        // 升級前寫入的樣子：交易與明細都沒有 revision。先取出目前的明細再清，
        // 否則交易的 revision 一被清掉，那些列就不再是「目前這一版」了。
        let payments = entry.livePayments
        let splits = entry.liveSplits
        entry.revisionID = nil
        payments.forEach { $0.entryRevisionID = nil }
        splits.forEach { $0.entryRevisionID = nil }
        try fixture.save()

        XCTAssertEqual(entry.livePayments.count, 1)
        XCTAssertEqual(entry.liveSplits.count, 2)
        XCTAssertEqual(entry.supersededChildCount, 0)
        XCTAssertEqual(entry.consistency(isVoided: false), .balanced)
    }

    // MARK: - 使用者看得到、也處理得掉

    func testTheScannerListsASupersededEntryWithoutAlarmingAboutBalances() throws {
        let fixture = try makeFixture()
        let entry = try fixture.addExpense(1000)
        try fixture.importRivalEdit(on: entry, payment: 1200, splits: [600, 600])

        let conflicts = EntryConflictScanner(persistence: fixture.persistence).conflicts()

        XCTAssertEqual(conflicts.count, 1)
        let conflict = try XCTUnwrap(conflicts.first)
        XCTAssertEqual(conflict.reason, .superseded(rowCount: 3))
        XCTAssertEqual(conflict.entry, entry)
        XCTAssertTrue(conflict.isWritable)
        // 數字沒有受影響，畫面不該把它說得像帳算錯了。
        XCTAssertFalse(conflict.affectsBalances)
    }

    func testClearingSupersededRowsLeavesTheLedgerUnchanged() throws {
        let fixture = try makeFixture()
        let entry = try fixture.addExpense(1000)
        try fixture.importRivalEdit(on: entry, payment: 1200, splits: [600, 600])
        let before = try SettlementRepository(persistence: fixture.persistence)
            .snapshot(in: fixture.book)

        try EntryRepository(persistence: fixture.persistence)
            .discardSupersededChildren(of: entry)

        XCTAssertEqual(entry.supersededChildCount, 0)
        XCTAssertEqual(entry.livePayments.count, 1)
        XCTAssertEqual(try fixture.count(of: "EntrySplit"), 2)
        XCTAssertEqual(
            try SettlementRepository(persistence: fixture.persistence)
                .snapshot(in: fixture.book).result,
            before.result
        )
        XCTAssertTrue(
            EntryConflictScanner(persistence: fixture.persistence).conflicts().isEmpty
        )
    }

    func testTotalsThatDoNotAddUpAreReportedAndKeptOutOfSettlement() throws {
        let fixture = try makeFixture()
        let entry = try fixture.addExpense(1000)
        // 只有勝出那一版的一半明細到了：分攤剩下一筆，付款仍是全額。
        fixture.delete(try XCTUnwrap(entry.liveSplits.first))
        try fixture.save()

        XCTAssertEqual(
            entry.consistency(isVoided: false),
            .mismatched(paymentTotal: 1000, splitTotal: 500)
        )

        let conflicts = EntryConflictScanner(persistence: fixture.persistence).conflicts()
        XCTAssertEqual(conflicts.first?.reason, .mismatched)
        XCTAssertEqual(conflicts.first?.affectsBalances, true)

        // 結算寧可少算一筆，也不能拿對不起來的交易去分帳。
        let snapshot = try SettlementRepository(persistence: fixture.persistence)
            .snapshot(in: fixture.book)
        XCTAssertEqual(snapshot.skippedEntryCount, 1)
        XCTAssertTrue(snapshot.result.suggestedTransfers.isEmpty)
    }

    func testAnEntryStillWaitingForItsRowsIsOnlyReportedOnceItIsOverdue() throws {
        let fixture = try makeFixture()
        let entry = try fixture.addExpense(1000)
        entry.livePayments.forEach { fixture.delete($0) }
        entry.liveSplits.forEach { fixture.delete($0) }
        try fixture.save()

        // 剛匯入的交易本來就會短暫少了明細，那是正常的同步過程。
        XCTAssertEqual(entry.consistency(isVoided: false), .awaitingDetails)
        XCTAssertTrue(
            EntryConflictScanner(persistence: fixture.persistence).conflicts().isEmpty
        )

        entry.updatedAt = Date().addingTimeInterval(-2 * EntryRepository.supersededChildRetention)
        try fixture.save()

        XCTAssertEqual(
            EntryConflictScanner(persistence: fixture.persistence).conflicts().first?.reason,
            .missingDetails
        )
    }

    // MARK: - 背景修復

    func testTheRepairPassLeavesRecentlyChangedEntriesAlone() async throws {
        let fixture = try makeFixture()
        let entry = try fixture.addExpense(1000)
        try fixture.importRivalEdit(on: entry, payment: 1200, splits: [600, 600])

        try await EntryRepository(persistence: fixture.persistence)
            .discardSupersededChildren(in: [try XCTUnwrap(fixture.group.id)])

        // 匯入還可能在進行中，這時候刪掉落選的那一組，等於把還在路上的那一版
        // 提前處決掉——而刪除也會同步出去，對方裝置一樣救不回來。
        XCTAssertEqual(entry.supersededChildCount, 3)
    }

    func testTheRepairPassClearsEntriesThatHaveSettledDown() async throws {
        let fixture = try makeFixture()
        let entry = try fixture.addExpense(1000)
        try fixture.importRivalEdit(on: entry, payment: 1200, splits: [600, 600])
        entry.updatedAt = Date().addingTimeInterval(-2 * EntryRepository.supersededChildRetention)
        try fixture.save()

        try await EntryRepository(persistence: fixture.persistence)
            .discardSupersededChildren(in: [try XCTUnwrap(fixture.group.id)])

        XCTAssertEqual(entry.supersededChildCount, 0)
        XCTAssertEqual(entry.livePayments.count, 1)
        XCTAssertEqual(entry.liveSplits.count, 2)
    }

    // MARK: - Fixture

    private func makeFixture() throws -> RevisionFixture {
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

        let context = persistence.container.viewContext
        let other = Member(context: context)
        context.assign(other, to: persistence.privateStore)
        other.id = UUID()
        other.displayName = "小美"
        other.role = MemberRole.member.rawValue
        other.invitationStatus = InvitationStatus.accepted.rawValue
        other.joinedAt = Date()
        other.group = group
        try context.save()

        return RevisionFixture(
            persistence: persistence,
            group: group,
            book: book,
            account: account,
            owner: owner,
            other: other
        )
    }
}

@MainActor
private struct RevisionFixture {
    let persistence: PersistenceController
    let group: LedgerGroup
    let book: LedgerBook
    let account: LedgerAccount
    let owner: Member
    let other: Member

    var otherID: UUID { other.id ?? UUID() }

    func save() throws {
        try persistence.container.viewContext.save()
    }

    func delete(_ object: NSManagedObject) {
        persistence.container.viewContext.delete(object)
    }

    func count(of entityName: String) throws -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        return try persistence.container.viewContext.count(for: request)
    }

    @discardableResult
    func addExpense(_ amount: Int) throws -> LedgerEntry {
        let ownerID = try XCTUnwrap(owner.id)
        let otherID = try XCTUnwrap(other.id)
        return try EntryRepository(persistence: persistence).createEntry(
            from: TransactionDraft(
                kind: .expense,
                amountText: "\(amount)",
                date: Date(),
                sourceAccountID: account.id,
                payerMemberID: ownerID,
                splitMemberIDs: [ownerID, otherID]
            ),
            in: book,
            accounts: Array(group.accounts as? Set<LedgerAccount> ?? []),
            categories: Array(group.categories as? Set<LedgerCategory> ?? []),
            members: Array(group.members as? Set<Member> ?? [])
        )
    }

    func update(_ entry: LedgerEntry, with draft: TransactionDraft) throws {
        try EntryRepository(persistence: persistence).updateEntry(
            entry,
            from: draft,
            accounts: Array(group.accounts as? Set<LedgerAccount> ?? []),
            categories: Array(group.categories as? Set<LedgerCategory> ?? []),
            members: Array(group.members as? Set<Member> ?? [])
        )
    }

    /// 另一台裝置的編輯匯入之後的樣子。
    ///
    /// CloudKit 只會保留其中一版的交易 record，但兩版的付款與分攤 record 都會留下來，
    /// 所以這裡只加明細、不動交易本身——那正是同步完成後這台裝置看到的狀態。
    func importRivalEdit(
        on entry: LedgerEntry,
        payment: Decimal,
        splits: [Decimal]
    ) throws {
        let context = persistence.container.viewContext
        let store = persistence.store(for: entry)
        let rivalRevision = UUID()

        let rivalPayment = EntryPayment(context: context)
        context.assign(rivalPayment, to: store)
        rivalPayment.id = UUID()
        rivalPayment.amount = payment as NSDecimalNumber
        rivalPayment.sortOrder = 0
        rivalPayment.entryRevisionID = rivalRevision
        rivalPayment.entry = entry
        rivalPayment.member = owner

        for (index, amount) in splits.enumerated() {
            let rivalSplit = EntrySplit(context: context)
            context.assign(rivalSplit, to: store)
            rivalSplit.id = UUID()
            rivalSplit.amount = amount as NSDecimalNumber
            rivalSplit.entryRevisionID = rivalRevision
            rivalSplit.entry = entry
            rivalSplit.member = index == 0 ? owner : other
        }

        try context.save()
    }
}
