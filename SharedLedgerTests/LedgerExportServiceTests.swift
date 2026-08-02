import CoreData
import XCTest
@testable import SharedLedger

@MainActor
final class LedgerExportServiceTests: XCTestCase {
    func testTransactionRowCarriesEveryColumnItPromises() throws {
        let fixture = try makeFixture()
        let food = try fixture.makeCategory(named: "餐飲")
        try fixture.addExpense(120, note: "早餐", category: food, in: fixture.book)

        let rows = try transactionRows(fixture.export())

        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row["帳本"], "主要帳本")
        XCTAssertEqual(row["類型"], "支出")
        XCTAssertEqual(row["分類"], "餐飲")
        XCTAssertEqual(row["金額"], "120")
        XCTAssertEqual(row["貨幣"], "TWD")
        XCTAssertEqual(row["轉出帳戶"], "現金")
        XCTAssertEqual(row["付款明細"], "小明:120")
        XCTAssertEqual(row["分攤方式"], "平均")
        XCTAssertEqual(row["分攤明細"], "小明:120")
        XCTAssertEqual(row["備註"], "早餐")
        XCTAssertEqual(row["狀態"], "有效")
    }

    func testAmountsAreRawNumbersRatherThanFormattedCurrency() throws {
        let fixture = try makeFixture()
        try fixture.addExpense(1200, in: fixture.book)

        let row = try XCTUnwrap(try transactionRows(fixture.export()).first)

        // 帶著貨幣符號或千分位就會變成試算表裡的文字，沒辦法直接加總。
        XCTAssertEqual(row["金額"], "1200")
        XCTAssertFalse(row["金額"]?.contains(",") ?? true)
        XCTAssertFalse(row["金額"]?.contains("$") ?? true)
    }

    func testMultiplePayersAndUnevenSplitsSurviveTheFlattening() throws {
        let fixture = try makeFixture()
        let partner = try fixture.makeMember(named: "小美")
        let ownerID = try XCTUnwrap(fixture.owner.id)
        let partnerID = try XCTUnwrap(partner.id)

        try fixture.addSplitExpense(
            1000,
            payments: [(ownerID, 600), (partnerID, 400)],
            splits: [(ownerID, 700), (partnerID, 300)],
            in: fixture.book
        )

        let row = try XCTUnwrap(try transactionRows(fixture.export()).first)

        XCTAssertEqual(row["分攤方式"], "指定金額")
        XCTAssertEqual(row["付款明細"], "小明:600;小美:400")
        // 依顯示名稱排序，同一筆交易每次匯出的欄位內容才會一致。
        XCTAssertEqual(row["分攤明細"], "小明:700;小美:300")
    }

    func testVoidedTransactionsAreExcludedUnlessRequested() throws {
        let fixture = try makeFixture()
        try fixture.addExpense(100, in: fixture.book)
        let voided = try fixture.addExpense(400, in: fixture.book)
        try EntryRepository(persistence: fixture.persistence).voidEntry(voided)

        let withoutVoided = try transactionRows(fixture.export())
        XCTAssertEqual(withoutVoided.count, 1)

        var request = LedgerExportRequest()
        request.includesVoided = true
        let withVoided = try transactionRows(fixture.export(request))

        XCTAssertEqual(withVoided.count, 2)
        XCTAssertEqual(Set(withVoided.compactMap { $0["狀態"] }), ["有效", "已作廢"])
    }

    func testScopeDecidesWhichBooksAreExported() throws {
        let fixture = try makeFixture()
        let travel = try fixture.makeBook(named: "旅遊帳本")
        try fixture.addExpense(100, in: fixture.book)
        try fixture.addExpense(200, in: travel)

        let currentOnly = fixture.export()
        XCTAssertEqual(currentOnly.transactionCount, 1)
        XCTAssertEqual(currentOnly.includedBookNames, ["主要帳本"])

        var allBooks = LedgerExportRequest()
        allBooks.scope = .allActiveBooks
        let everything = fixture.export(allBooks)

        XCTAssertEqual(everything.transactionCount, 2)
        XCTAssertEqual(Set(everything.includedBookNames), ["主要帳本", "旅遊帳本"])

        let rows = try transactionRows(everything)
        XCTAssertEqual(Set(rows.compactMap { $0["帳本"] }), ["主要帳本", "旅遊帳本"])
    }

    func testDateRangeIncludesBothBoundaryDays() throws {
        let fixture = try makeFixture()
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: fixture.referenceDate)
        let dayBefore = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: day))
        let dayAfter = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day))

        try fixture.addExpense(100, date: dayBefore, in: fixture.book)
        try fixture.addExpense(200, date: day, in: fixture.book)
        try fixture.addExpense(300, date: dayAfter, in: fixture.book)

        var request = LedgerExportRequest()
        request.startDate = day
        request.endDate = dayAfter

        let summary = fixture.export(request)

        XCTAssertEqual(summary.transactionCount, 2)
        let amounts = try transactionRows(summary).compactMap { $0["金額"] }
        XCTAssertEqual(Set(amounts), ["200", "300"])
    }

    func testAccountBalancesIgnoreTheTransactionDateRange() throws {
        let fixture = try makeFixture()
        let calendar = Calendar.current
        let longAgo = try XCTUnwrap(
            calendar.date(byAdding: .month, value: -6, to: fixture.referenceDate)
        )
        try fixture.addExpense(250, date: longAgo, in: fixture.book)
        try fixture.addExpense(100, in: fixture.book)

        var request = LedgerExportRequest()
        request.startDate = calendar.startOfDay(for: fixture.referenceDate)
        request.endDate = fixture.referenceDate

        let summary = fixture.export(request)
        XCTAssertEqual(summary.transactionCount, 1)

        let accountRow = try XCTUnwrap(try rows(in: summary, fileNameContains: "帳戶").first)
        // 帳戶餘額是資產狀態，不是期間現金流：把它跟著日期篩選會匯出一個對不起來的數字。
        XCTAssertEqual(accountRow["目前餘額"], "-350")
        XCTAssertEqual(accountRow["帳戶"], "現金")
        XCTAssertEqual(accountRow["狀態"], "使用中")
    }

    func testSettlementHistoryIsExportedWithMemberNames() throws {
        let fixture = try makeFixture()
        let partner = try fixture.makeMember(named: "小美")
        let ownerID = try XCTUnwrap(fixture.owner.id)
        let partnerID = try XCTUnwrap(partner.id)
        try fixture.addSplitExpense(
            1000,
            payments: [(ownerID, 1000)],
            splits: [(ownerID, 500), (partnerID, 500)],
            in: fixture.book
        )
        try SettlementRepository(persistence: fixture.persistence).recordSettlement(
            from: partner,
            to: fixture.owner,
            amount: 500,
            note: "現金還款",
            in: fixture.book
        )

        let settlementRow = try XCTUnwrap(
            try rows(in: fixture.export(), fileNameContains: "結算").first
        )

        XCTAssertEqual(settlementRow["付款人"], "小美")
        XCTAssertEqual(settlementRow["收款人"], "小明")
        XCTAssertEqual(settlementRow["金額"], "500")
        XCTAssertEqual(settlementRow["備註"], "現金還款")
        XCTAssertEqual(settlementRow["狀態"], "有效")
    }

    func testOptionalDocumentsCanBeLeftOut() throws {
        let fixture = try makeFixture()
        try fixture.addExpense(100, in: fixture.book)

        var request = LedgerExportRequest()
        request.includesAccounts = false
        request.includesSettlements = false
        let summary = fixture.export(request)

        XCTAssertEqual(summary.documents.count, 1)
        XCTAssertTrue(summary.documents[0].fileName.hasSuffix("-交易.csv"))
    }

    func testNotesAreQuotedRatherThanBreakingTheRow() throws {
        let fixture = try makeFixture()
        try fixture.addExpense(100, note: "晚餐, 含小費\n記得請款", in: fixture.book)

        let contents = try XCTUnwrap(fixture.export().documents.first?.contents)

        XCTAssertTrue(contents.contains("\"晚餐, 含小費\n記得請款\""))
        // 逗號與換行都在引號裡，所以整份檔案仍然只有標題列加一筆資料列。
        XCTAssertEqual(try transactionRows(fixture.export()).count, 1)
    }

    func testFileNamesCarryTheGroupAndCannotContainPathSeparators() throws {
        let fixture = try makeFixture(groupName: "家庭/日常")
        try fixture.addExpense(100, in: fixture.book)

        for document in fixture.export().documents {
            XCTAssertFalse(document.fileName.contains("/"))
            XCTAssertTrue(document.fileName.hasPrefix("家庭-日常-"))
            XCTAssertTrue(document.fileName.hasSuffix(".csv"))
        }
    }

    // MARK: - Helpers

    /// 把匯出的 CSV 解析回 `欄名: 值`，讓斷言針對欄位意義而不是字串位置。
    private func parse(_ contents: String) throws -> [[String: String]] {
        let body = contents.hasPrefix(CSVWriter.byteOrderMark)
            ? String(contents.dropFirst(CSVWriter.byteOrderMark.count))
            : contents
        let lines = splitRecords(body)
        guard let headerLine = lines.first else { return [] }
        let header = parseFields(headerLine)
        return lines.dropFirst().map { line in
            let fields = parseFields(line)
            return Dictionary(
                uniqueKeysWithValues: zip(header, fields).map { ($0, $1) }
            )
        }
    }

    /// 以 CRLF 斷行，但引號內的 CRLF 屬於欄位本身。
    ///
    /// Swift 的 `Character` 是 extended grapheme cluster，CRLF 是其中一個 cluster，
    /// 所以逐字元走訪永遠不會單獨遇到 `"\r"`——要直接比對 `"\r\n"`。
    private func splitRecords(_ body: String) -> [String] {
        var records: [String] = []
        var current = ""
        var insideQuotes = false

        for character in body {
            if character == "\"" {
                insideQuotes.toggle()
                current.append(character)
            } else if character == "\r\n", !insideQuotes {
                records.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { records.append(current) }
        return records
    }

    private func parseFields(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var insideQuotes = false
        var iterator = line.startIndex

        while iterator < line.endIndex {
            let character = line[iterator]
            if character == "\"" {
                let next = line.index(after: iterator)
                if insideQuotes, next < line.endIndex, line[next] == "\"" {
                    current.append("\"")
                    iterator = next
                } else {
                    insideQuotes.toggle()
                }
            } else if character == ",", !insideQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
            iterator = line.index(after: iterator)
        }
        fields.append(current)
        return fields
    }

    private func transactionRows(_ summary: LedgerExportSummary) throws -> [[String: String]] {
        try rows(in: summary, fileNameContains: "交易")
    }

    private func rows(
        in summary: LedgerExportSummary,
        fileNameContains needle: String
    ) throws -> [[String: String]] {
        let document = try XCTUnwrap(
            summary.documents.first { $0.fileName.contains(needle) }
        )
        return try parse(document.contents)
    }

    private func makeFixture(groupName: String = "家庭") throws -> ExportFixture {
        let persistence = PersistenceController(inMemory: true)
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(
                name: groupName,
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

        return ExportFixture(
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
private struct ExportFixture {
    let persistence: PersistenceController
    let group: LedgerGroup
    let book: LedgerBook
    let account: LedgerAccount
    let owner: Member
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

    /// 成員只會從建立群組或接受分享而來，測試直接建一個已接受邀請的成員。
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
        in book: LedgerBook
    ) throws -> LedgerEntry {
        let ownerID = try XCTUnwrap(owner.id)
        return try EntryRepository(persistence: persistence).createEntry(
            from: TransactionDraft(
                kind: .expense,
                amountText: "\(amount)",
                date: date ?? referenceDate,
                note: note,
                categoryID: category?.id,
                sourceAccountID: account.id,
                payerMemberID: ownerID,
                splitMemberIDs: [ownerID]
            ),
            in: book,
            accounts: allAccounts,
            categories: allCategories,
            members: allMembers
        )
    }

    @discardableResult
    func addSplitExpense(
        _ amount: Int,
        payments: [(UUID, Int)],
        splits: [(UUID, Int)],
        in book: LedgerBook
    ) throws -> LedgerEntry {
        try EntryRepository(persistence: persistence).createEntry(
            from: TransactionDraft(
                kind: .expense,
                amountText: "\(amount)",
                date: referenceDate,
                sourceAccountID: account.id,
                splitMemberIDs: Set(splits.map(\.0)),
                splitMode: .fixedAmount,
                splitValueTexts: Dictionary(
                    uniqueKeysWithValues: splits.map { ($0.0, "\($0.1)") }
                ),
                paymentDrafts: payments.map {
                    TransactionPaymentDraft(memberID: $0.0, amountText: "\($0.1)")
                }
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

    func export(_ request: LedgerExportRequest = LedgerExportRequest()) -> LedgerExportSummary {
        LedgerExportService(persistence: persistence).export(
            in: group,
            request: request,
            currentBook: book
        )
    }
}
