import CoreData
import XCTest
@testable import SharedLedger

@MainActor
final class GroupReportServiceTests: XCTestCase {
    func testCategorySharesAreRelativeToPeriodExpenseTotal() throws {
        let fixture = try makeFixture()
        let food = try fixture.makeCategory(named: "餐飲")
        let transport = try fixture.makeCategory(named: "交通")

        try fixture.addExpense(600, category: food, in: fixture.book)
        try fixture.addExpense(400, category: transport, in: fixture.book)

        let snapshot = fixture.snapshot()

        XCTAssertEqual(snapshot.expense, 1000)
        XCTAssertEqual(snapshot.categories.count, 2)
        XCTAssertEqual(fixture.share(of: "餐飲", in: snapshot), Decimal(string: "0.6"))
        XCTAssertEqual(fixture.share(of: "交通", in: snapshot), Decimal(string: "0.4"))
        XCTAssertEqual(snapshot.categories.map(\.expenseShare).reduce(0, +), 1)
    }

    func testIncomeDoesNotDiluteExpenseShares() throws {
        let fixture = try makeFixture()
        let food = try fixture.makeCategory(named: "餐飲")

        try fixture.addExpense(500, category: food, in: fixture.book)
        try fixture.addIncome(9000, category: food, in: fixture.book)

        let snapshot = fixture.snapshot()

        // The denominator is period expense, so a large income must not shrink the
        // only expense category's share.
        XCTAssertEqual(snapshot.income, 9000)
        XCTAssertEqual(snapshot.expense, 500)
        XCTAssertEqual(fixture.share(of: "餐飲", in: snapshot), 1)
    }

    func testUncategorisedExpensesGetTheirOwnShare() throws {
        let fixture = try makeFixture()
        let food = try fixture.makeCategory(named: "餐飲")

        try fixture.addExpense(700, category: food, in: fixture.book)
        try fixture.addExpense(300, category: nil, in: fixture.book)

        let snapshot = fixture.snapshot()

        XCTAssertEqual(fixture.share(of: "餐飲", in: snapshot), Decimal(string: "0.7"))
        XCTAssertEqual(fixture.share(of: "未分類", in: snapshot), Decimal(string: "0.3"))
    }

    func testSharesAreZeroWhenPeriodHasNoExpense() throws {
        let fixture = try makeFixture()
        let food = try fixture.makeCategory(named: "餐飲")

        try fixture.addIncome(1000, category: food, in: fixture.book)

        let snapshot = fixture.snapshot()

        XCTAssertEqual(snapshot.expense, 0)
        // No expense means no denominator; the share must be 0 rather than a
        // division by zero or a misleading 100%.
        XCTAssertEqual(snapshot.categories.map(\.expenseShare), [0])
        XCTAssertEqual(snapshot.books.map(\.expenseShare), [0])
    }

    func testSameCategoryAggregatesAcrossBooksByStableID() throws {
        let fixture = try makeFixture()
        let secondBook = try fixture.makeBook(named: "旅遊帳本")
        let food = try fixture.makeCategory(named: "餐飲")

        try fixture.addExpense(200, category: food, in: fixture.book)
        try fixture.addExpense(300, category: food, in: secondBook)

        let snapshot = fixture.snapshot()

        XCTAssertEqual(snapshot.categories.count, 1)
        XCTAssertEqual(snapshot.categories.first?.expense, 500)
        XCTAssertEqual(snapshot.categories.first?.expenseShare, 1)

        // Each source book keeps its own contribution.
        XCTAssertEqual(snapshot.books.count, 2)
        XCTAssertEqual(fixture.bookShare(of: "主要帳本", in: snapshot), Decimal(string: "0.4"))
        XCTAssertEqual(fixture.bookShare(of: "旅遊帳本", in: snapshot), Decimal(string: "0.6"))
    }

    func testScopeSelectsWhichBooksAreAggregated() throws {
        let fixture = try makeFixture()
        let secondBook = try fixture.makeBook(named: "旅遊帳本")
        let food = try fixture.makeCategory(named: "餐飲")

        try fixture.addExpense(200, category: food, in: fixture.book)
        try fixture.addExpense(300, category: food, in: secondBook)

        XCTAssertEqual(fixture.snapshot(scope: .allActiveBooks).expense, 500)
        XCTAssertEqual(
            fixture.snapshot(scope: .currentBook, currentBook: fixture.book).expense,
            200
        )
        XCTAssertEqual(
            fixture.snapshot(scope: .currentBook, currentBook: secondBook).expense,
            300
        )

        let secondBookID = try XCTUnwrap(secondBook.id)
        let custom = fixture.snapshot(scope: .selectedBookIDs, selectedBookIDs: [secondBookID])
        XCTAssertEqual(custom.expense, 300)
        XCTAssertEqual(custom.includedBookIDs, [secondBookID])
        XCTAssertEqual(custom.categories.first?.expenseShare, 1)
    }

    func testVoidedEntriesAreExcludedAndSharesRecomputed() throws {
        let fixture = try makeFixture()
        let food = try fixture.makeCategory(named: "餐飲")
        let transport = try fixture.makeCategory(named: "交通")

        try fixture.addExpense(600, category: food, in: fixture.book)
        let voided = try fixture.addExpense(400, category: transport, in: fixture.book)

        try EntryRepository(persistence: fixture.persistence).voidEntry(voided)

        let snapshot = fixture.snapshot()

        XCTAssertEqual(snapshot.expense, 600)
        XCTAssertEqual(snapshot.categories.count, 1)
        XCTAssertEqual(fixture.share(of: "餐飲", in: snapshot), 1)
    }

    func testPeriodBoundaryIsHalfOpen() throws {
        let fixture = try makeFixture()
        let food = try fixture.makeCategory(named: "餐飲")
        let calendar = Calendar.current
        let interval = try XCTUnwrap(calendar.dateInterval(of: .month, for: fixture.referenceDate))

        try fixture.addExpense(100, category: food, in: fixture.book, date: interval.start)
        // Midnight on the first of the next month belongs to the next period only.
        try fixture.addExpense(700, category: food, in: fixture.book, date: interval.end)

        let snapshot = fixture.snapshot(interval: interval)

        XCTAssertEqual(snapshot.expense, 100)
        XCTAssertEqual(snapshot.entries.count, 1)
    }

    func testAccountBalanceIsSeparateFromPeriodReporting() throws {
        let fixture = try makeFixture()
        let food = try fixture.makeCategory(named: "餐飲")
        let calendar = Calendar.current
        let interval = try XCTUnwrap(calendar.dateInterval(of: .month, for: fixture.referenceDate))
        let previousMonth = try XCTUnwrap(
            calendar.date(byAdding: .day, value: -1, to: interval.start)
        )

        try fixture.addExpense(100, category: food, in: fixture.book)
        try fixture.addExpense(250, category: food, in: fixture.book, date: previousMonth)

        let snapshot = fixture.snapshot(interval: interval)

        // The period report only covers this month, while the account balance is
        // derived from the account model and still reflects every transaction.
        XCTAssertEqual(snapshot.expense, 100)
        let accounts = Array(fixture.group.accounts as? Set<LedgerAccount> ?? [])
        XCTAssertEqual(
            snapshot.accountBalance,
            AccountRepository(persistence: fixture.persistence).totalBalance(for: accounts)
        )
        // The out-of-period expense still moved the account, so the balance cannot
        // be a restatement of the period total.
        XCTAssertNotEqual(snapshot.accountBalance, -snapshot.expense)
    }

    private func makeFixture() throws -> GroupReportFixture {
        let persistence = PersistenceController(inMemory: true)
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(
                name: "家庭",
                ownerDisplayName: "小明",
                currencyCode: "TWD"
            )
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

        let now = Date()
        let midMonth = Calendar.current.dateInterval(of: .month, for: now)
            .map { $0.start.addingTimeInterval($0.duration / 2) } ?? now

        return GroupReportFixture(
            persistence: persistence,
            group: group,
            book: book,
            account: account,
            owner: owner,
            referenceDate: midMonth
        )
    }
}

@MainActor
private struct GroupReportFixture {
    let persistence: PersistenceController
    let group: LedgerGroup
    let book: LedgerBook
    let account: LedgerAccount
    let owner: Member
    /// Mid-month, resolved once, so tests can shift a day either way without
    /// leaving the period and without the value moving mid-test.
    let referenceDate: Date

    func makeBook(named name: String) throws -> LedgerBook {
        try BookRepository(persistence: persistence).createBook(
            from: BookDraft(name: name),
            in: group
        )
    }

    func makeCategory(named name: String) throws -> LedgerCategory {
        try CategoryRepository(persistence: persistence).createCategory(
            from: CategoryDraft(name: name),
            in: group,
            parent: nil
        )
    }

    @discardableResult
    func addExpense(
        _ amount: Int,
        category: LedgerCategory?,
        in book: LedgerBook,
        date: Date? = nil
    ) throws -> LedgerEntry {
        try addEntry(kind: .expense, amount: amount, category: category, in: book, date: date)
    }

    @discardableResult
    func addIncome(
        _ amount: Int,
        category: LedgerCategory?,
        in book: LedgerBook,
        date: Date? = nil
    ) throws -> LedgerEntry {
        try addEntry(kind: .income, amount: amount, category: category, in: book, date: date)
    }

    private func addEntry(
        kind: EntryKind,
        amount: Int,
        category: LedgerCategory?,
        in book: LedgerBook,
        date: Date?
    ) throws -> LedgerEntry {
        let ownerID = try XCTUnwrap(owner.id)
        let categories = Array(group.categories as? Set<LedgerCategory> ?? [])
        return try EntryRepository(persistence: persistence).createEntry(
            from: TransactionDraft(
                kind: kind,
                amountText: "\(amount)",
                date: date ?? referenceDate,
                categoryID: category?.id,
                sourceAccountID: account.id,
                payerMemberID: ownerID,
                splitMemberIDs: [ownerID]
            ),
            in: book,
            accounts: [account],
            categories: categories,
            members: [owner]
        )
    }

    func snapshot(
        interval: DateInterval? = nil,
        scope: ReportBookScope = .allActiveBooks,
        currentBook: LedgerBook? = nil,
        selectedBookIDs: Set<UUID> = []
    ) -> GroupReportSnapshot {
        let period = interval
            ?? Calendar.current.dateInterval(of: .month, for: referenceDate)
            ?? DateInterval(start: referenceDate, duration: 0)
        return GroupReportService(persistence: persistence).snapshot(
            in: group,
            interval: period,
            scope: scope,
            currentBook: currentBook ?? book,
            selectedBookIDs: selectedBookIDs
        )
    }

    func share(of categoryName: String, in snapshot: GroupReportSnapshot) -> Decimal? {
        snapshot.categories.first { $0.name == categoryName }?.expenseShare
    }

    func bookShare(of bookName: String, in snapshot: GroupReportSnapshot) -> Decimal? {
        snapshot.books.first { $0.name == bookName }?.expenseShare
    }
}
