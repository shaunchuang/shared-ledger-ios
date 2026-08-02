import CoreData
import XCTest
@testable import SharedLedger

@MainActor
final class TransactionSearchServiceTests: XCTestCase {
    func testUnfilteredSearchReturnsEveryEntryInTheCurrentBook() throws {
        let fixture = try makeFixture()
        let other = try fixture.makeBook(named: "旅遊帳本")
        try fixture.addExpense(100, in: fixture.book)
        try fixture.addExpense(200, in: other)

        let result = fixture.search(TransactionQuery())

        XCTAssertEqual(result.matchCount, 1)
        XCTAssertEqual(result.scopedCount, 1)
        XCTAssertEqual(result.expense, 100)
        XCTAssertEqual(result.includedBookIDs, [fixture.book.id].compactMap { $0 })
    }

    func testScopeWidensTheSearchToEveryActiveBook() throws {
        let fixture = try makeFixture()
        let other = try fixture.makeBook(named: "旅遊帳本")
        try fixture.addExpense(100, in: fixture.book)
        try fixture.addExpense(200, in: other)

        let result = fixture.search(TransactionQuery(), scope: .allActiveBooks)

        XCTAssertEqual(result.matchCount, 2)
        XCTAssertEqual(result.expense, 300)
        XCTAssertEqual(result.includedBookIDs.count, 2)
    }

    func testKeywordMatchesNoteCategoryAccountAndMemberNames() throws {
        let fixture = try makeFixture()
        let food = try fixture.makeCategory(named: "餐飲")
        try fixture.addExpense(100, note: "和同事吃拉麵", in: fixture.book)
        try fixture.addExpense(200, category: food, in: fixture.book)
        try fixture.addExpense(300, in: fixture.book)

        XCTAssertEqual(fixture.search(query(keyword: "拉麵")).matchCount, 1)
        XCTAssertEqual(fixture.search(query(keyword: "餐飲")).matchCount, 1)
        // 帳戶與付款人名稱套用在每一筆交易上，所以三筆都會命中。
        XCTAssertEqual(fixture.search(query(keyword: "現金")).matchCount, 3)
        XCTAssertEqual(fixture.search(query(keyword: "小明")).matchCount, 3)
        XCTAssertEqual(fixture.search(query(keyword: "不存在的字")).matchCount, 0)
    }

    func testKeywordTokensMustAllMatch() throws {
        let fixture = try makeFixture()
        let food = try fixture.makeCategory(named: "餐飲")
        try fixture.addExpense(100, note: "拉麵", category: food, in: fixture.book)
        try fixture.addExpense(200, note: "拉麵", in: fixture.book)

        // 兩個詞是 AND：只有同時符合備註與分類的那一筆算命中。
        XCTAssertEqual(fixture.search(query(keyword: "拉麵 餐飲")).matchCount, 1)
        XCTAssertEqual(fixture.search(query(keyword: "拉麵")).matchCount, 2)
    }

    func testKeywordIgnoresCaseAndWidth() throws {
        let fixture = try makeFixture()
        try fixture.addExpense(100, note: "Uber Eats", in: fixture.book)

        XCTAssertEqual(fixture.search(query(keyword: "uber")).matchCount, 1)
        XCTAssertEqual(fixture.search(query(keyword: "ＵＢＥＲ")).matchCount, 1)
    }

    func testDateRangeIncludesBothBoundaryDays() throws {
        let fixture = try makeFixture()
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: fixture.referenceDate)
        let previousDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: day))
        let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day))
        // 當天最後一刻仍屬於這一天，不能因為時間不是 00:00 就被排除。
        let lateInTheDay = try XCTUnwrap(calendar.date(byAdding: .second, value: -1, to: nextDay))

        try fixture.addExpense(100, date: previousDay, in: fixture.book)
        try fixture.addExpense(200, date: day, in: fixture.book)
        try fixture.addExpense(300, date: lateInTheDay, in: fixture.book)
        try fixture.addExpense(400, date: nextDay, in: fixture.book)

        var query = TransactionQuery()
        query.startDate = day
        query.endDate = day

        let result = fixture.search(query)

        XCTAssertEqual(result.matchCount, 2)
        XCTAssertEqual(result.expense, 500)
    }

    func testAmountRangeIsInclusiveAndInvertedRangeMatchesNothing() throws {
        let fixture = try makeFixture()
        try fixture.addExpense(100, in: fixture.book)
        try fixture.addExpense(200, in: fixture.book)
        try fixture.addExpense(300, in: fixture.book)

        var range = TransactionQuery()
        range.minAmountText = "100"
        range.maxAmountText = "200"
        XCTAssertEqual(fixture.search(range).matchCount, 2)

        var lowerOnly = TransactionQuery()
        lowerOnly.minAmountText = "300"
        XCTAssertEqual(fixture.search(lowerOnly).matchCount, 1)

        // 上下顛倒的區間照字面套用，結果是空的，而不是靜靜地把兩個值對調。
        var inverted = TransactionQuery()
        inverted.minAmountText = "300"
        inverted.maxAmountText = "100"
        XCTAssertTrue(inverted.hasInvertedAmountRange)
        XCTAssertEqual(fixture.search(inverted).matchCount, 0)
    }

    func testUnparsableAmountIsReportedAndIgnored() throws {
        let fixture = try makeFixture()
        try fixture.addExpense(100, in: fixture.book)

        var query = TransactionQuery()
        query.minAmountText = "一百"

        XCTAssertTrue(query.hasUnparsableAmountInput)
        XCTAssertNil(query.minAmount)
        XCTAssertEqual(fixture.search(query).matchCount, 1)
    }

    func testCategoryFilterIncludesDescendantsAndUncategorised() throws {
        let fixture = try makeFixture()
        let food = try fixture.makeCategory(named: "餐飲")
        let breakfast = try fixture.makeCategory(named: "早餐", parent: food)
        let transport = try fixture.makeCategory(named: "交通")

        try fixture.addExpense(100, category: food, in: fixture.book)
        try fixture.addExpense(200, category: breakfast, in: fixture.book)
        try fixture.addExpense(300, category: transport, in: fixture.book)
        try fixture.addExpense(400, in: fixture.book)

        var parentOnly = TransactionQuery()
        parentOnly.categoryIDs = [try XCTUnwrap(food.id)]
        // 選父分類代表選了整個範圍，子分類的交易必須一起出現。
        XCTAssertEqual(fixture.search(parentOnly).expense, 300)

        var childOnly = TransactionQuery()
        childOnly.categoryIDs = [try XCTUnwrap(breakfast.id)]
        XCTAssertEqual(fixture.search(childOnly).expense, 200)

        var uncategorised = TransactionQuery()
        uncategorised.includesUncategorized = true
        XCTAssertEqual(fixture.search(uncategorised).expense, 400)

        var mixed = TransactionQuery()
        mixed.categoryIDs = [try XCTUnwrap(transport.id)]
        mixed.includesUncategorized = true
        XCTAssertEqual(fixture.search(mixed).expense, 700)
    }

    func testAccountFilterMatchesEitherSideOfATransfer() throws {
        let fixture = try makeFixture()
        let destination = try fixture.makeAccount(named: "銀行")
        try fixture.addExpense(100, in: fixture.book)
        try fixture.addTransfer(500, to: destination, in: fixture.book)

        var query = TransactionQuery()
        query.accountIDs = [try XCTUnwrap(destination.id)]

        let result = fixture.search(query)

        XCTAssertEqual(result.matchCount, 1)
        // 轉帳不是收入也不是支出，只出現在列表，不進小計。
        XCTAssertEqual(result.expense, 0)
        XCTAssertEqual(result.income, 0)
    }

    func testPayerAndParticipantFiltersUseTheirOwnDetails() throws {
        let fixture = try makeFixture()
        let partner = try fixture.makeMember(named: "小美")
        let ownerID = try XCTUnwrap(fixture.owner.id)
        let partnerID = try XCTUnwrap(partner.id)

        try fixture.addExpense(100, payer: ownerID, participants: [ownerID], in: fixture.book)
        try fixture.addExpense(200, payer: partnerID, participants: [ownerID, partnerID], in: fixture.book)

        var payerFilter = TransactionQuery()
        payerFilter.payerMemberIDs = [partnerID]
        XCTAssertEqual(fixture.search(payerFilter).expense, 200)

        var participantFilter = TransactionQuery()
        participantFilter.participantMemberIDs = [partnerID]
        XCTAssertEqual(fixture.search(participantFilter).expense, 200)

        // 擁有者參與了兩筆，但只付了其中一筆，兩個維度不能互相取代。
        var ownerPayer = TransactionQuery()
        ownerPayer.payerMemberIDs = [ownerID]
        XCTAssertEqual(fixture.search(ownerPayer).expense, 100)

        var ownerParticipant = TransactionQuery()
        ownerParticipant.participantMemberIDs = [ownerID]
        XCTAssertEqual(fixture.search(ownerParticipant).expense, 300)
    }

    func testFiltersCombineWithAnd() throws {
        let fixture = try makeFixture()
        let food = try fixture.makeCategory(named: "餐飲")
        try fixture.addExpense(100, note: "拉麵", category: food, in: fixture.book)
        try fixture.addExpense(900, note: "拉麵", category: food, in: fixture.book)
        try fixture.addIncome(100, note: "拉麵", category: food, in: fixture.book)

        var query = TransactionQuery()
        query.keyword = "拉麵"
        query.kinds = [.expense]
        query.categoryIDs = [try XCTUnwrap(food.id)]
        query.maxAmountText = "500"

        let result = fixture.search(query)

        XCTAssertEqual(result.matchCount, 1)
        XCTAssertEqual(result.expense, 100)
    }

    func testVoidedEntriesAreHiddenUntilExplicitlyIncluded() throws {
        let fixture = try makeFixture()
        try fixture.addExpense(100, in: fixture.book)
        let voided = try fixture.addExpense(400, in: fixture.book)
        try EntryRepository(persistence: fixture.persistence).voidEntry(voided)

        let hidden = fixture.search(TransactionQuery())
        XCTAssertEqual(hidden.matchCount, 1)
        XCTAssertEqual(hidden.scopedCount, 1)
        XCTAssertEqual(hidden.expense, 100)

        var includingVoided = TransactionQuery()
        includingVoided.includesVoided = true
        let shown = fixture.search(includingVoided)

        XCTAssertEqual(shown.matchCount, 2)
        XCTAssertEqual(shown.voidedEntryIDs, [try XCTUnwrap(voided.id)])
        // 作廢交易看得到，但不能把小計算進去。
        XCTAssertEqual(shown.expense, 100)
    }

    func testResultsAreGroupedByMonthNewestFirst() throws {
        let fixture = try makeFixture()
        let calendar = Calendar.current
        let thisMonth = fixture.referenceDate
        let lastMonth = try XCTUnwrap(calendar.date(byAdding: .month, value: -1, to: thisMonth))

        try fixture.addExpense(100, date: thisMonth, in: fixture.book)
        try fixture.addExpense(200, date: lastMonth, in: fixture.book)
        try fixture.addIncome(500, date: lastMonth, in: fixture.book)

        let result = fixture.search(TransactionQuery())

        XCTAssertEqual(result.sections.count, 2)
        XCTAssertEqual(result.sections.map(\.id).sorted(by: >), result.sections.map(\.id))

        let newest = try XCTUnwrap(result.sections.first)
        XCTAssertEqual(newest.entries.count, 1)
        XCTAssertEqual(newest.expense, 100)

        let oldest = try XCTUnwrap(result.sections.last)
        XCTAssertEqual(oldest.entries.count, 2)
        XCTAssertEqual(oldest.income, 500)
        XCTAssertEqual(oldest.expense, 200)
        XCTAssertEqual(oldest.net, 300)
    }

    func testScopedCountSeparatesAnEmptyBookFromAnEmptyResult() throws {
        let fixture = try makeFixture()
        try fixture.addExpense(100, note: "拉麵", in: fixture.book)

        let noMatch = fixture.search(query(keyword: "咖啡"))
        XCTAssertEqual(noMatch.matchCount, 0)
        // 有交易、只是都不符合條件，畫面才能給出不同的說明。
        XCTAssertEqual(noMatch.scopedCount, 1)

        let emptyFixture = try makeFixture()
        let empty = emptyFixture.search(TransactionQuery())
        XCTAssertEqual(empty.matchCount, 0)
        XCTAssertEqual(empty.scopedCount, 0)
    }

    func testArchivedBooksAreNeverSearched() throws {
        let fixture = try makeFixture()
        let archived = try fixture.makeBook(named: "已結束的旅行")
        try fixture.addExpense(100, in: fixture.book)
        try fixture.addExpense(700, in: archived)
        try BookRepository(persistence: fixture.persistence).archiveBook(archived)

        let result = fixture.search(TransactionQuery(), scope: .allActiveBooks)

        XCTAssertEqual(result.matchCount, 1)
        XCTAssertEqual(result.expense, 100)
    }

    private func query(keyword: String) -> TransactionQuery {
        var query = TransactionQuery()
        query.keyword = keyword
        return query
    }

    private func makeFixture() throws -> TransactionSearchFixture {
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

        return TransactionSearchFixture(
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
private struct TransactionSearchFixture {
    let persistence: PersistenceController
    let group: LedgerGroup
    let book: LedgerBook
    let account: LedgerAccount
    let owner: Member
    /// 月中，一次解析好，測試才能前後移動一天而不會跨出當月，也不會在測試中途變動。
    let referenceDate: Date

    func makeBook(named name: String) throws -> LedgerBook {
        try BookRepository(persistence: persistence).createBook(
            from: BookDraft(name: name),
            in: group
        )
    }

    func makeCategory(named name: String, parent: LedgerCategory? = nil) throws -> LedgerCategory {
        try CategoryRepository(persistence: persistence).createCategory(
            from: CategoryDraft(name: name),
            in: group,
            parent: parent
        )
    }

    func makeAccount(named name: String) throws -> LedgerAccount {
        try AccountRepository(persistence: persistence).createAccount(
            from: AccountDraft(name: name),
            in: group
        )
    }

    /// 沒有公開的「新增成員」API——成員只會從建立群組或接受分享而來，所以測試
    /// 直接建一個已接受邀請的成員，和其他測試的做法一致。
    func makeMember(named name: String) throws -> Member {
        let context = persistence.container.viewContext
        let member = Member(context: context)
        context.assign(member, to: persistence.privateStore)
        member.id = UUID()
        member.displayName = name
        member.role = MemberRole.member.rawValue
        member.invitationStatus = InvitationStatus.accepted.rawValue
        member.joinedAt = Date()
        member.group = group
        try context.save()
        return member
    }

    @discardableResult
    func addExpense(
        _ amount: Int,
        note: String = "",
        category: LedgerCategory? = nil,
        date: Date? = nil,
        payer: UUID? = nil,
        participants: Set<UUID>? = nil,
        in book: LedgerBook
    ) throws -> LedgerEntry {
        try addEntry(
            kind: .expense,
            amount: amount,
            note: note,
            category: category,
            date: date,
            payer: payer,
            participants: participants,
            in: book
        )
    }

    @discardableResult
    func addIncome(
        _ amount: Int,
        note: String = "",
        category: LedgerCategory? = nil,
        date: Date? = nil,
        in book: LedgerBook
    ) throws -> LedgerEntry {
        try addEntry(
            kind: .income,
            amount: amount,
            note: note,
            category: category,
            date: date,
            payer: nil,
            participants: nil,
            in: book
        )
    }

    @discardableResult
    func addTransfer(
        _ amount: Int,
        to destination: LedgerAccount,
        in book: LedgerBook
    ) throws -> LedgerEntry {
        try EntryRepository(persistence: persistence).createEntry(
            from: TransactionDraft(
                kind: .transfer,
                amountText: "\(amount)",
                date: referenceDate,
                sourceAccountID: account.id,
                destinationAccountID: destination.id
            ),
            in: book,
            accounts: allAccounts,
            categories: allCategories,
            members: allMembers
        )
    }

    private func addEntry(
        kind: EntryKind,
        amount: Int,
        note: String,
        category: LedgerCategory?,
        date: Date?,
        payer: UUID?,
        participants: Set<UUID>?,
        in book: LedgerBook
    ) throws -> LedgerEntry {
        let ownerID = try XCTUnwrap(owner.id)
        let payerID = payer ?? ownerID
        return try EntryRepository(persistence: persistence).createEntry(
            from: TransactionDraft(
                kind: kind,
                amountText: "\(amount)",
                date: date ?? referenceDate,
                note: note,
                categoryID: category?.id,
                sourceAccountID: account.id,
                payerMemberID: payerID,
                splitMemberIDs: participants ?? [ownerID]
            ),
            in: book,
            accounts: allAccounts,
            categories: allCategories,
            members: allMembers
        )
    }

    private var allAccounts: [LedgerAccount] {
        Array(group.accounts as? Set<LedgerAccount> ?? [])
    }

    private var allCategories: [LedgerCategory] {
        Array(group.categories as? Set<LedgerCategory> ?? [])
    }

    private var allMembers: [Member] {
        Array(group.members as? Set<Member> ?? [])
    }

    func search(
        _ query: TransactionQuery,
        scope: ReportBookScope = .currentBook,
        selectedBookIDs: Set<UUID> = []
    ) -> TransactionSearchResult {
        TransactionSearchService(persistence: persistence).results(
            in: group,
            query: query,
            scope: scope,
            currentBook: book,
            selectedBookIDs: selectedBookIDs
        )
    }
}
