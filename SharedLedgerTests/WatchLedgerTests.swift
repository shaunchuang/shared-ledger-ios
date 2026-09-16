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

    func testLostReplyRetryAcknowledgesCommittedEntryWithoutTouchingPhoneEdits() throws {
        let f = try fixture()
        let request = f.request()
        try f.service.save(request)
        let context = f.persistence.container.viewContext
        let entry = try XCTUnwrap(context.fetch(NSFetchRequest<LedgerEntry>(entityName: "LedgerEntry")).first)
        // Even editing the original entry's scope must not change its receipt.
        entry.book = nil
        f.book.name = "Unfinished edit"
        let reply = f.bridge().reply(to: WatchLedgerMessage(request: request))
        XCTAssertEqual(reply.savedID, request.id)
        XCTAssertNil(reply.rejectedID)
        XCTAssertNil(reply.context)
        XCTAssertNil(reply.error)
        XCTAssertTrue(context.hasChanges)
        XCTAssertNil(entry.book)
        XCTAssertEqual(f.book.name, "Unfinished edit")
        var state = WatchLedgerState(pending: request)
        state.receive(reply)
        XCTAssertNil(state.pending)
        context.rollback()
        XCTAssertEqual(entry.book?.id, f.book.id)
        XCTAssertEqual(try f.count("LedgerEntry"), 1)
        XCTAssertEqual(try f.count("EntryPayment"), 1)
        XCTAssertEqual(try f.count("EntrySplit"), 1)
    }

    func testUnsavedInsertCannotImpersonateCommittedReceipt() throws {
        let f = try fixture()
        let request = f.request()
        let context = f.persistence.container.viewContext
        let pendingEntry = LedgerEntry(context: context)
        context.assign(pendingEntry, to: f.persistence.privateStore)
        pendingEntry.id = request.id
        pendingEntry.book = f.book
        pendingEntry.group = f.group
        let reply = f.bridge().reply(to: WatchLedgerMessage(request: request))
        XCTAssertNil(reply.savedID)
        XCTAssertNil(reply.rejectedID)
        XCTAssertNotNil(reply.error)
        var state = WatchLedgerState(pending: request)
        state.receive(reply)
        XCTAssertEqual(state.pending, request)
        XCTAssertTrue(context.hasChanges)
        context.rollback()
        XCTAssertEqual(try f.count("LedgerEntry"), 0)
    }

    func testBusyReplyPreservesPendingForRetryAfterPhoneDiscardsChanges() throws {
        let f = try fixture()
        let request = f.request()
        let bridge = f.bridge()
        var state = WatchLedgerState(pending: request)
        f.book.name = "Unfinished edit"
        let busy = bridge.reply(to: WatchLedgerMessage(request: request))
        XCTAssertNil(busy.savedID)
        XCTAssertNil(busy.rejectedID)
        XCTAssertNil(busy.context)
        XCTAssertNotNil(busy.error)
        state.receive(busy)
        XCTAssertEqual(state.pending, request)
        XCTAssertEqual(try f.count("LedgerEntry"), 0)
        f.persistence.container.viewContext.rollback()
        let retry = bridge.reply(to: WatchLedgerMessage(request: request))
        XCTAssertEqual(retry.savedID, request.id)
        state.receive(retry)
        XCTAssertNil(state.pending)
        XCTAssertEqual(try f.count("LedgerEntry"), 1)
    }

    func testStorageAndUnknownFailuresNeverReleasePendingRequest() throws {
        let f = try fixture()
        let request = f.request()
        // The phone has committed, but the watch has not received its result.
        try f.service.save(request)
        let errors: [Error] = [
            NSError(domain: NSCocoaErrorDomain, code: NSPersistentStoreOperationError),
            NSError(domain: "UnexpectedWatchFailure", code: 1),
            PermissionError.cloudPermissionUnknown
        ]
        var state = WatchLedgerState(pending: request)
        for error in errors {
            let bridge = f.bridge(saveRequest: { _ in throw error })
            let reply = bridge.reply(to: WatchLedgerMessage(request: request))
            XCTAssertNil(reply.savedID)
            XCTAssertNil(reply.rejectedID)
            XCTAssertNotNil(reply.error)
            state.receive(reply)
            XCTAssertEqual(state.pending, request)
        }
        state.receive(f.bridge().reply(to: WatchLedgerMessage(request: request)))
        XCTAssertNil(state.pending)
        XCTAssertEqual(try f.count("LedgerEntry"), 1)
        XCTAssertEqual(try f.count("EntryPayment"), 1)
        XCTAssertEqual(try f.count("EntrySplit"), 1)
    }

    func testDefinitiveInputRejectionStillAllowsEditing() throws {
        let f = try fixture()
        let request = f.request(accountID: UUID())
        var state = WatchLedgerState(pending: request)
        let reply = f.bridge().reply(to: WatchLedgerMessage(request: request))
        XCTAssertNil(reply.savedID)
        XCTAssertEqual(reply.rejectedID, request.id)
        XCTAssertNotNil(reply.error)
        state.receive(reply)
        XCTAssertNil(state.pending)
        XCTAssertEqual(try f.count("LedgerEntry"), 0)
    }

    func testDirectRefreshPreservesLastCommittedSummaryDuringPhoneEdits() throws {
        let f = try fixture()
        try f.service.save(f.request())
        let committed = try f.service.context()
        let context = f.persistence.container.viewContext
        let entry = try XCTUnwrap(context.fetch(NSFetchRequest<LedgerEntry>(entityName: "LedgerEntry")).first)
        entry.amount = NSDecimalNumber(value: 999)
        f.book.name = "Unfinished edit"
        XCTAssertThrowsError(try f.service.context())
        let bridge = f.bridge()
        let reply = bridge.reply(to: WatchLedgerMessage())
        XCTAssertNil(reply.context)
        XCTAssertNotNil(reply.error)
        var state = WatchLedgerState(context: committed)
        state.receive(reply)
        XCTAssertEqual(state.context?.snapshot, committed.snapshot)
        XCTAssertTrue(context.hasChanges)
        XCTAssertEqual(entry.amount, NSDecimalNumber(value: 999))
        context.rollback()
        let refreshed = bridge.reply(to: WatchLedgerMessage())
        XCTAssertNil(refreshed.error)
        XCTAssertEqual(refreshed.context?.snapshot?.bookName, committed.snapshot?.bookName)
        XCTAssertEqual(refreshed.context?.snapshot?.days, committed.snapshot?.days)
    }

    func testBackgroundSaveRefreshesWidgetWithoutStartingSceneObservers() throws {
        let f = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = LedgerWidgetStore(directory: directory, defaults: f.defaults)
        store.select(bookID: f.book.id)
        try store.save(try f.service.context().snapshot)
        XCTAssertEqual(store.load()?.days.count, 0)
        // No start(), onAppear, observer subscription or run-loop delay.
        let bridge = f.bridge(widgetStore: store)
        let request = f.request()
        let reply = bridge.reply(to: WatchLedgerMessage(request: request))
        XCTAssertEqual(reply.savedID, request.id)
        let summary = try XCTUnwrap(store.load()?.summary(at: request.date))
        XCTAssertEqual(summary.expense, request.amount)
        XCTAssertEqual(summary.todayCount, 1)
        XCTAssertEqual(bridge.reply(to: WatchLedgerMessage(request: request)).savedID, request.id)
        XCTAssertEqual(store.load()?.summary(at: request.date), summary)
    }

    private struct Fixture {
        let persistence: PersistenceController
        let defaults: UserDefaults
        let group: LedgerGroup
        let book: LedgerBook
        let owner: Member
        let account: LedgerAccount
        var service: WatchLedgerService { WatchLedgerService(persistence: persistence, defaults: defaults) }

        func bridge(widgetStore: LedgerWidgetStore = LedgerWidgetStore(directory: nil, defaults: nil),
                    saveRequest: ((WatchLedgerRequest) throws -> UUID)? = nil) -> WatchLedgerBridge {
            WatchLedgerBridge(persistence: persistence, defaults: defaults,
                              widgetStore: widgetStore, saveRequest: saveRequest)
        }

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
