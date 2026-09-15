import CoreData
import XCTest
@testable import SharedLedger

@MainActor
final class WatchLedgerTests: XCTestCase {
    func testRetryAfterLostReplyCreatesExactlyOneEntryAndAudit() throws {
        let f = try fixture()
        let request = f.request()
        XCTAssertEqual(try f.service.save(request), request.id)
        XCTAssertEqual(try f.service.save(request), request.id)
        XCTAssertEqual(try f.count("LedgerEntry"), 1)
        let entries = try f.persistence.container.viewContext.fetch(NSFetchRequest<LedgerEntry>(entityName: "LedgerEntry"))
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.amount as Decimal?, Decimal(string: "12.50"))
        XCTAssertEqual(entry.livePayments.count, 1)
        XCTAssertEqual(entry.liveSplits.count, 1)
        let audits = NSFetchRequest<AuditEvent>(entityName: "AuditEvent")
        audits.predicate = NSPredicate(format: "action == %@", "transaction.created")
        XCTAssertEqual(try f.persistence.container.viewContext.count(for: audits), 1)
        // A voided transaction must not be resurrected by a delayed retry.
        try EntryRepository(persistence: f.persistence).voidEntry(entry)
        XCTAssertEqual(try f.service.save(request), request.id)
        XCTAssertEqual(try f.count("LedgerEntry"), 1)
    }

    func testPendingIDAndDecimalSurviveRestartAndOnlyMatchingAckClearsIt() throws {
        let f = try fixture()
        let request = f.request()
        var state = try JSONDecoder().decode(WatchLedgerState.self,
            from: JSONEncoder().encode(WatchLedgerState(pending: request)))
        XCTAssertEqual(state.pending, request)
        state.receive(WatchLedgerReply(savedID: UUID()))
        XCTAssertEqual(state.pending, request)
        state.receive(WatchLedgerReply(context: WatchLedgerContext()))
        XCTAssertEqual(state.pending, request)
        state.receive(WatchLedgerReply(savedID: request.id))
        XCTAssertNil(state.pending)
    }

    func testRejectionIsDistinctFromRefreshAndOldContextCannotOverwriteNew() throws {
        let f = try fixture()
        let request = f.request()
        let recent = WatchLedgerContext(generatedAt: Date(timeIntervalSince1970: 200), restriction: "new")
        var state = WatchLedgerState(context: recent, pending: request)
        state.receive(WatchLedgerReply(context: WatchLedgerContext(generatedAt: Date(timeIntervalSince1970: 100))))
        XCTAssertEqual(state.context?.restriction, "new")
        XCTAssertNotNil(state.pending)
        state.receive(WatchLedgerReply(rejectedID: request.id, error: "changed"))
        XCTAssertNil(state.pending)
    }

    func testInvalidAmountsKindsAndProtocolNeverWrite() throws {
        let f = try fixture()
        for request in [f.request(amount: 0), f.request(amount: -1), f.request(amount: Decimal(string: "0.001")!),
                        f.request(amount: 1_000_000_000_000), f.request(kind: .transfer)] {
            XCTAssertFalse(request.isValid)
            XCTAssertThrowsError(try f.service.save(request))
        }
        var future = f.request(); future.version = 99
        XCTAssertThrowsError(try f.service.save(future))
        XCTAssertEqual(try f.count("LedgerEntry"), 0)
    }

    func testChangedBookCurrencyPayerOrMembersAreRejected() throws {
        let f = try fixture()
        for request in [f.request(bookID: UUID()), f.request(currency: "EUR"),
                        f.request(payerID: UUID()), f.request(memberIDs: [UUID()]),
                        f.request(memberIDs: [f.owner.id!, f.owner.id!])] {
            XCTAssertThrowsError(try f.service.save(request))
        }
        f.defaults.removeObject(forKey: WatchLedgerService.selectionKey)
        XCTAssertThrowsError(try f.service.save(f.request()))
        XCTAssertEqual(try f.count("LedgerEntry"), 0)
    }

    func testForeignAccountAndDisabledCategoryAreRejectedByRepository() throws {
        let f = try fixture()
        XCTAssertThrowsError(try f.service.save(f.request(accountID: UUID())))
        XCTAssertThrowsError(try f.service.save(f.request(categoryID: UUID())))
        XCTAssertEqual(try f.count("LedgerEntry"), 0)
    }

    func testReadOnlyAndUnsavedPhoneChangesCannotWrite() throws {
        let f = try fixture()
        f.book.name = "Unsaved"
        XCTAssertThrowsError(try f.service.save(f.request()))
        XCTAssertTrue(f.persistence.container.viewContext.hasChanges)
        f.persistence.container.viewContext.rollback()
        CurrentMemberIdentityRepository(persistence: f.persistence).setCurrentMember(f.owner, in: f.group)
        f.owner.role = MemberRole.viewer.rawValue
        try f.persistence.container.viewContext.save()
        XCTAssertThrowsError(try f.service.save(f.request()))
        XCTAssertEqual(try f.count("LedgerEntry"), 0)
    }

    func testContextSelectionArchiveAndPersonalReset() throws {
        let f = try fixture()
        let context = try f.service.context()
        XCTAssertTrue(context.canCreate)
        XCTAssertEqual(context.snapshot?.bookID, f.book.id)
        XCTAssertEqual(context.payer?.id, f.owner.id)
        XCTAssertEqual(context.accounts.map(\.id), [f.account.id!])
        _ = try BookRepository(persistence: f.persistence).createBook(from: BookDraft(name: "Other"), in: f.group)
        try BookRepository(persistence: f.persistence).archiveBook(f.book)
        XCTAssertNil(try f.service.context().snapshot)
        XCTAssertThrowsError(try f.service.save(f.request()))
        let personal = LocalPersonalDataRepository(persistence: f.persistence, watchDefaults: f.defaults)
        XCTAssertTrue(personal.summary().hasWatchData)
        try personal.deleteAll()
        XCTAssertNil(f.defaults.string(forKey: WatchLedgerService.selectionKey))
        XCTAssertNil(try f.service.context().snapshot)
    }

    func testRetryIDCannotAcknowledgeAnotherBook() throws {
        let f = try fixture()
        let request = f.request()
        try f.service.save(request)
        XCTAssertThrowsError(try f.service.save(f.request(id: request.id, bookID: UUID())))
        XCTAssertEqual(try f.count("LedgerEntry"), 1)
    }

    private struct Fixture {
        let persistence: PersistenceController
        let defaults: UserDefaults
        let group: LedgerGroup
        let book: LedgerBook
        let owner: Member
        let account: LedgerAccount
        var service: WatchLedgerService { WatchLedgerService(persistence: persistence, defaults: defaults) }

        func request(id: UUID = UUID(), bookID: UUID? = nil, currency: String = "USD", kind: EntryKind = .expense,
                     amount: Decimal = Decimal(string: "12.50")!, accountID: UUID? = nil,
                     categoryID: UUID? = nil, payerID: UUID? = nil, memberIDs: [UUID]? = nil) -> WatchLedgerRequest {
            WatchLedgerRequest(id: id, groupID: group.id!, bookID: bookID ?? book.id!, currencyCode: currency,
                               kind: kind, amount: amount, date: Date(), accountID: accountID ?? account.id!,
                               categoryID: categoryID, payerID: payerID ?? owner.id!, memberIDs: memberIDs ?? [owner.id!])
        }
        func count(_ entity: String) throws -> Int {
            try persistence.container.viewContext.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: entity))
        }
    }

    private func fixture() throws -> Fixture {
        let name = "WatchLedgerTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let persistence = PersistenceController(inMemory: true)
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(name: "Watch", ownerDisplayName: "Owner", currencyCode: "USD"))
        let book = try XCTUnwrap(BookRepository(persistence: persistence).defaultBook(in: group))
        let owner = try XCTUnwrap((group.members as? Set<Member>)?.first)
        let account = try AccountRepository(persistence: persistence).createAccount(from: AccountDraft(name: "Cash"), in: group)
        defaults.set(book.id!.uuidString, forKey: WatchLedgerService.selectionKey)
        return Fixture(persistence: persistence, defaults: defaults, group: group, book: book, owner: owner, account: account)
    }
}
