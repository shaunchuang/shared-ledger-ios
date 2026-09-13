import CoreData
import XCTest
@testable import SharedLedger

@MainActor
final class LedgerWidgetTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return calendar
    }

    private func date(_ day: Int, month: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
    }

    func testQuickEntryLinksRoundTripForBothKinds() {
        let bookID = UUID()
        for kind in [EntryKind.expense, .income] {
            let route = LedgerWidgetRoute.newEntry(bookID: bookID, kind: kind)
            XCTAssertEqual(LedgerWidgetRoute(url: route.url), route)
        }
        XCTAssertEqual(LedgerWidgetRoute(url: LedgerWidgetRoute.settings.url), .settings)
    }

    func testMalformedLinksCannotSelectAnotherBookOrCreateUnsupportedEntries() {
        let id = UUID().uuidString
        for value in [
            "https://new-entry?book=\(id)&kind=expense",
            "sharedledger://new-entry?kind=expense",
            "sharedledger://new-entry?book=invalid&kind=expense",
            "sharedledger://new-entry?book=\(id)&kind=transfer",
            "sharedledger://new-entry?book=\(id)&kind=balanceAdjustment",
            "sharedledger://new-entry?book=\(id)&book=\(id)&kind=expense",
            "sharedledger://new-entry?book=\(id)&kind=expense&amount=10",
            "sharedledger://new-entry/path?book=\(id)&kind=income",
            "sharedledger://user@new-entry?book=\(id)&kind=income",
            "sharedledger://widget-settings?book=\(id)"
        ] {
            XCTAssertNil(LedgerWidgetRoute(url: URL(string: value)!), value)
        }
    }

    func testSummaryRollsOverAtMidnightWithoutChangingMonthlyTotals() throws {
        let snapshot = makeSnapshot()
        let today = try XCTUnwrap(snapshot.summary(at: date(13), calendar: calendar))
        let tomorrow = try XCTUnwrap(snapshot.summary(at: date(14), calendar: calendar))
        XCTAssertEqual(today.todayCount, 1)
        XCTAssertEqual(tomorrow.todayCount, 0)
        XCTAssertEqual(today.expense, Decimal(string: "10.25"))
        XCTAssertEqual(today, .init(income: 0, expense: Decimal(string: "10.25")!, todayCount: 1))
        XCTAssertEqual(tomorrow.expense, today.expense)
    }

    func testPreviousMonthAndChangedTimeZoneRequireRefresh() {
        let snapshot = makeSnapshot()
        XCTAssertNil(snapshot.summary(at: snapshot.month.end, calendar: calendar))
        XCTAssertNil(snapshot.summary(at: snapshot.month.start.addingTimeInterval(-1), calendar: calendar))
        var changed = calendar
        changed.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertNil(snapshot.summary(at: date(13), calendar: changed))
        let dates = snapshot.timelineDates(from: date(13), calendar: calendar)
        XCTAssertEqual(dates.first, date(13))
        XCTAssertEqual(dates.last, snapshot.month.end)
        XCTAssertEqual(dates[1], calendar.startOfDay(for: date(14)))
    }

    func testTimelineUsesCalendarDaysAcrossDaylightSaving() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 12))!
        let snapshot = LedgerWidgetSnapshot(
            schemaVersion: 1, bookID: UUID(), groupName: "G", bookName: "B", currencyCode: "USD",
            updatedAt: now, month: calendar.dateInterval(of: .month, for: now)!,
            timeZoneIdentifier: calendar.timeZone.identifier, days: []
        )
        let dates = snapshot.timelineDates(from: now, calendar: calendar)
        XCTAssertEqual(dates[2].timeIntervalSince(dates[1]), 23 * 60 * 60)
        XCTAssertTrue(dates.dropFirst().allSatisfy { calendar.component(.hour, from: $0) == 0 })
    }

    func testCachePreservesDecimalAndRejectsCorruptionAndWrongSelection() throws {
        let store = try makeStore()
        let snapshot = makeSnapshot()
        store.select(bookID: snapshot.bookID)
        try store.save(snapshot)
        XCTAssertEqual(store.load(), snapshot)
        store.select(bookID: UUID())
        XCTAssertNil(store.load())
        store.select(bookID: snapshot.bookID)
        try Data("invalid".utf8).write(to: store.directory!.appendingPathComponent("widget-summary-v1.json"))
        XCTAssertNil(store.load())
        try store.save(snapshot)
        try store.reset()
        XCTAssertNil(store.load())
        XCTAssertFalse(store.hasStoredData)
    }

    func testUnknownCacheVersionAndUnavailableAppGroupAreSafe() throws {
        let store = try makeStore()
        let snapshot = makeSnapshot()
        store.select(bookID: snapshot.bookID)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        json["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject: json)
            .write(to: store.directory!.appendingPathComponent("widget-summary-v1.json"))
        XCTAssertNil(store.load())
        let unavailable = LedgerWidgetStore(directory: nil, defaults: nil)
        XCTAssertFalse(unavailable.isAvailable)
        XCTAssertNil(unavailable.load())
        XCTAssertThrowsError(try unavailable.save(snapshot))
    }

    func testProjectionScopesBookAndPeriodAndExcludesTransfersAndVoids() throws {
        let fixture = try makeFixture()
        let repository = EntryRepository(persistence: fixture.persistence)
        let first = try addEntry(fixture, kind: .expense, amount: "10.25")
        try addEntry(fixture, kind: .income, amount: "30.50")
        let voided = try addEntry(fixture, kind: .expense, amount: "900")
        try repository.voidEntry(voided)
        let otherBook = try BookRepository(persistence: fixture.persistence)
            .createBook(from: BookDraft(name: "Other"), in: fixture.group)
        try addEntry(fixture, kind: .expense, amount: "800", book: otherBook)
        let monthEnd = calendar.dateInterval(of: .month, for: date(13))!.end
        try addEntry(fixture, kind: .expense, amount: "700", on: monthEnd)
        let transferAccount = try AccountRepository(persistence: fixture.persistence)
            .createAccount(from: AccountDraft(name: "Bank"), in: fixture.group)
        try repository.createEntry(
            from: TransactionDraft(kind: .transfer, amountText: "600", date: date(13),
                                   sourceAccountID: fixture.account.id, destinationAccountID: transferAccount.id),
            in: fixture.book, accounts: [fixture.account, transferAccount], categories: [], members: [fixture.owner]
        )
        let service = LedgerWidgetSnapshotService(persistence: fixture.persistence)
        let snapshot = try XCTUnwrap(service.snapshot(bookID: fixture.book.id!, now: date(13), calendar: calendar))
        let summary = try XCTUnwrap(snapshot.summary(at: date(13), calendar: calendar))
        XCTAssertEqual(summary.expense, Decimal(string: "10.25"))
        XCTAssertEqual(summary.income, Decimal(string: "30.50"))
        XCTAssertEqual(summary.todayCount, 2)
        XCTAssertEqual(snapshot.currencyCode, "USD")
        XCTAssertEqual(snapshot.bookID, fixture.book.id)

        // Editing and voiding must replace the cached projection, not accumulate.
        var draft = TransactionDraft(entry: first)
        draft.amountText = "20.75"
        draft.paymentDrafts = []
        try repository.updateEntry(first, from: draft, accounts: [fixture.account], categories: [], members: [fixture.owner])
        XCTAssertEqual(try service.snapshot(bookID: fixture.book.id!, now: date(13), calendar: calendar)?
            .summary(at: date(13), calendar: calendar)?.expense, Decimal(string: "20.75"))
        try repository.voidEntry(first)
        XCTAssertEqual(try service.snapshot(bookID: fixture.book.id!, now: date(13), calendar: calendar)?
            .summary(at: date(13), calendar: calendar)?.expense, 0)
    }

    func testCoordinatorClearsArchivedOrDeletedBookWithoutFallback() throws {
        let fixture = try makeFixture()
        try addEntry(fixture, kind: .expense, amount: "10")
        let store = try makeStore()
        store.select(bookID: fixture.book.id)
        let coordinator = LedgerWidgetCoordinator(persistence: fixture.persistence, store: store)
        coordinator.refresh()
        XCTAssertNotNil(store.load())
        _ = try BookRepository(persistence: fixture.persistence)
            .createBook(from: BookDraft(name: "Other"), in: fixture.group)
        try BookRepository(persistence: fixture.persistence).archiveBook(fixture.book)
        coordinator.refresh()
        XCTAssertNil(store.load())
        store.select(bookID: UUID())
        coordinator.refresh()
        XCTAssertNil(store.load())
    }

    func testCoordinatorDoesNotPublishUnsavedChangesAndPersonalResetClearsWidget() throws {
        let fixture = try makeFixture()
        let store = try makeStore()
        store.select(bookID: fixture.book.id)
        let coordinator = LedgerWidgetCoordinator(persistence: fixture.persistence, store: store)
        coordinator.refresh()
        let savedName = store.load()?.bookName
        fixture.book.name = "Unsaved"
        coordinator.refresh()
        XCTAssertEqual(store.load()?.bookName, savedName)
        fixture.persistence.container.viewContext.rollback()
        let repository = LocalPersonalDataRepository(persistence: fixture.persistence, widgetStore: store)
        XCTAssertTrue(repository.summary().hasWidgetData)
        try repository.deleteAll()
        coordinator.refresh()
        XCTAssertFalse(store.hasStoredData)
    }

    private func makeSnapshot() -> LedgerWidgetSnapshot {
        LedgerWidgetSnapshot(
            schemaVersion: 1, bookID: UUID(), groupName: "Group", bookName: "Book", currencyCode: "USD",
            updatedAt: date(13), month: calendar.dateInterval(of: .month, for: date(13))!,
            timeZoneIdentifier: calendar.timeZone.identifier,
            days: [.init(date: calendar.startOfDay(for: date(13)), expense: Decimal(string: "10.25")!, entryCount: 1)]
        )
    }

    private func makeStore() throws -> LedgerWidgetStore {
        let suite = "LedgerWidgetTests-\(UUID())"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        return LedgerWidgetStore(directory: directory, defaults: UserDefaults(suiteName: suite))
    }

    private struct Fixture {
        let persistence: PersistenceController
        let group: LedgerGroup
        let book: LedgerBook
        let account: LedgerAccount
        let owner: Member
    }

    private func makeFixture() throws -> Fixture {
        let persistence = PersistenceController(inMemory: true)
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(name: "Widget", ownerDisplayName: "Owner", currencyCode: "USD")
        )
        let book = try XCTUnwrap(BookRepository(persistence: persistence).defaultBook(in: group))
        let owner = try XCTUnwrap((group.members as? Set<Member>)?.first)
        let account = try AccountRepository(persistence: persistence)
            .createAccount(from: AccountDraft(name: "Cash"), in: group)
        return Fixture(persistence: persistence, group: group, book: book, account: account, owner: owner)
    }

    @discardableResult
    private func addEntry(_ fixture: Fixture, kind: EntryKind, amount: String,
                          book: LedgerBook? = nil, on date: Date? = nil) throws -> LedgerEntry {
        try EntryRepository(persistence: fixture.persistence).createEntry(
            from: TransactionDraft(kind: kind, amountText: amount, date: date ?? self.date(13),
                                   sourceAccountID: fixture.account.id, payerMemberID: fixture.owner.id,
                                   splitMemberIDs: [fixture.owner.id!]),
            in: book ?? fixture.book, accounts: [fixture.account], categories: [], members: [fixture.owner]
        )
    }
}
