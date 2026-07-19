import CoreData
import XCTest
@testable import SharedLedger

final class AllocationCalculatorTests: XCTestCase {
    func testEqualSplitDistributesTWDMinorUnitDeterministically() throws {
        let ids = [UUID(), UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        let allocations = try AllocationCalculator.calculateSplits(
            total: 100,
            mode: .equal,
            inputs: ids.reversed().map { SplitInput(memberID: $0, value: nil) },
            currencyCode: "TWD"
        )

        XCTAssertEqual(allocations.map(\.memberID), ids)
        XCTAssertEqual(allocations.map(\.amount), [34, 33, 33])
        XCTAssertEqual(allocations.map(\.amount).reduce(0, +), 100)
    }

    func testPercentageSplitHandlesNegativeJPYTail() throws {
        let ids = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        let allocations = try AllocationCalculator.calculateSplits(
            total: 1,
            mode: .percentage,
            inputs: ids.map { SplitInput(memberID: $0, value: 50) },
            currencyCode: "JPY"
        )

        XCTAssertEqual(allocations.map(\.amount), [0, 1])
        XCTAssertEqual(allocations.map(\.amount).reduce(0, +), 1)
    }

    func testPercentageSplitHandlesPositiveKWDTail() throws {
        let ids = [UUID(), UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        let percentages = [Decimal(string: "33.33")!, Decimal(string: "33.33")!, Decimal(string: "33.34")!]
        let allocations = try AllocationCalculator.calculateSplits(
            total: 1,
            mode: .percentage,
            inputs: zip(ids, percentages).map { SplitInput(memberID: $0.0, value: $0.1) },
            currencyCode: "KWD"
        )

        XCTAssertEqual(allocations.map(\.amount).reduce(0, +), 1)
        XCTAssertTrue(allocations.allSatisfy {
            LedgerCurrency.isValidAmount($0.amount, currencyCode: "KWD")
        })
    }

    func testFixedAmountsMustEqualTransactionTotal() throws {
        let ids = [UUID(), UUID()]

        XCTAssertThrowsError(
            try AllocationCalculator.calculateSplits(
                total: 100,
                mode: .fixedAmount,
                inputs: [
                    SplitInput(memberID: ids[0], value: 40),
                    SplitInput(memberID: ids[1], value: 50)
                ],
                currencyCode: "TWD"
            )
        ) { error in
            XCTAssertEqual(
                error as? AllocationCalculator.AllocationError,
                .fixedAmountTotalMismatch
            )
        }
    }

    func testPaymentsRejectDuplicatePayersAndInvalidTotals() {
        let payer = UUID()

        XCTAssertThrowsError(
            try AllocationCalculator.validatePayments(
                total: 100,
                inputs: [
                    PaymentInput(memberID: payer, amount: 50),
                    PaymentInput(memberID: payer, amount: 50)
                ],
                currencyCode: "TWD"
            )
        ) { error in
            XCTAssertEqual(error as? AllocationCalculator.AllocationError, .duplicatePayer)
        }

        XCTAssertThrowsError(
            try AllocationCalculator.validatePayments(
                total: 100,
                inputs: [PaymentInput(memberID: payer, amount: 99)],
                currencyCode: "TWD"
            )
        ) { error in
            XCTAssertEqual(error as? AllocationCalculator.AllocationError, .paymentTotalMismatch)
        }
    }

    func testPaymentsRespectCurrencyMinorUnits() throws {
        XCTAssertThrowsError(
            try AllocationCalculator.validatePayments(
                total: 1,
                inputs: [PaymentInput(memberID: UUID(), amount: Decimal(string: "1.1")!)],
                currencyCode: "JPY"
            )
        ) { error in
            XCTAssertEqual(
                error as? AllocationCalculator.AllocationError,
                .invalidPaymentAmount("JPY")
            )
        }
    }
}

@MainActor
final class MultiPayerEntryRepositoryTests: XCTestCase {
    func testRepositoryPersistsPercentageSplitsAndMultiplePayments() throws {
        let fixture = try makeFixture(currencyCode: "TWD")
        let amount = "101"
        let ownerID = try XCTUnwrap(fixture.owner.id)
        let friendID = try XCTUnwrap(fixture.friend.id)
        let entry = try fixture.repository.createEntry(
            from: TransactionDraft(
                kind: .expense,
                amountText: amount,
                sourceAccountID: fixture.account.id,
                splitMemberIDs: [ownerID, friendID],
                splitMode: .percentage,
                splitValueTexts: [ownerID: "40", friendID: "60"],
                paymentDrafts: [
                    TransactionPaymentDraft(memberID: ownerID, amountText: "70"),
                    TransactionPaymentDraft(memberID: friendID, amountText: "31")
                ]
            ),
            in: fixture.book,
            accounts: [fixture.account],
            categories: [],
            members: [fixture.owner, fixture.friend]
        )

        let payments = (entry.payments as? Set<EntryPayment> ?? [])
            .sorted { $0.sortOrder < $1.sortOrder }
        let splits = entry.splits as? Set<EntrySplit> ?? []

        XCTAssertEqual(entry.splitMode, SplitMode.percentage.rawValue)
        XCTAssertNil(entry.payer)
        XCTAssertEqual(payments.compactMap { $0.amount as Decimal? }, [70, 31])
        XCTAssertEqual(payments.compactMap { $0.amount as Decimal? }.reduce(0, +), 101)
        XCTAssertEqual(splits.compactMap { $0.amount as Decimal? }.reduce(0, +), 101)
        XCTAssertEqual(Set(splits.compactMap { $0.inputValue as Decimal? }), [40, 60])
    }

    func testRepositoryRejectsCrossGroupArchivedAndDuplicatePayers() throws {
        let fixture = try makeFixture(currencyCode: "TWD")
        let ownerID = try XCTUnwrap(fixture.owner.id)
        let friendID = try XCTUnwrap(fixture.friend.id)
        let foreignGroup = try GroupRepository(persistence: fixture.persistence).createGroup(
            from: GroupDraft(name: "其他群組", ownerDisplayName: "外部成員")
        )
        let foreignMember = try XCTUnwrap((foreignGroup.members as? Set<Member>)?.first)
        let foreignID = try XCTUnwrap(foreignMember.id)

        XCTAssertThrowsError(
            try fixture.repository.createEntry(
                from: TransactionDraft(
                    kind: .expense,
                    amountText: "100",
                    sourceAccountID: fixture.account.id,
                    splitMemberIDs: [foreignID],
                    paymentDrafts: [
                        TransactionPaymentDraft(memberID: ownerID, amountText: "100")
                    ]
                ),
                in: fixture.book,
                accounts: [fixture.account],
                categories: [],
                members: [fixture.owner, fixture.friend, foreignMember]
            )
        ) { error in
            guard case EntryRepository.EntryError.crossScopeReference = error else {
                return XCTFail("Expected crossScopeReference, got \(error)")
            }
        }

        fixture.friend.archivedAt = Date()
        XCTAssertThrowsError(
            try fixture.repository.createEntry(
                from: TransactionDraft(
                    kind: .expense,
                    amountText: "100",
                    sourceAccountID: fixture.account.id,
                    splitMemberIDs: [friendID],
                    paymentDrafts: [
                        TransactionPaymentDraft(memberID: ownerID, amountText: "100")
                    ]
                ),
                in: fixture.book,
                accounts: [fixture.account],
                categories: [],
                members: [fixture.owner, fixture.friend]
            )
        ) { error in
            guard case EntryRepository.EntryError.archivedMember = error else {
                return XCTFail("Expected archivedMember, got \(error)")
            }
        }
        fixture.friend.archivedAt = nil

        XCTAssertThrowsError(
            try fixture.repository.createEntry(
                from: TransactionDraft(
                    kind: .expense,
                    amountText: "100",
                    sourceAccountID: fixture.account.id,
                    splitMemberIDs: [ownerID],
                    paymentDrafts: [
                        TransactionPaymentDraft(memberID: ownerID, amountText: "50"),
                        TransactionPaymentDraft(memberID: ownerID, amountText: "50")
                    ]
                ),
                in: fixture.book,
                accounts: [fixture.account],
                categories: [],
                members: [fixture.owner, fixture.friend]
            )
        ) { error in
            XCTAssertEqual(error as? AllocationCalculator.AllocationError, .duplicatePayer)
        }
    }

    func testRepositoryRejectsInvalidJPYAmount() throws {
        let fixture = try makeFixture(currencyCode: "JPY")
        let ownerID = try XCTUnwrap(fixture.owner.id)

        XCTAssertThrowsError(
            try fixture.repository.createEntry(
                from: TransactionDraft(
                    kind: .expense,
                    amountText: "1.5",
                    sourceAccountID: fixture.account.id,
                    payerMemberID: ownerID,
                    splitMemberIDs: [ownerID]
                ),
                in: fixture.book,
                accounts: [fixture.account],
                categories: [],
                members: [fixture.owner]
            )
        ) { error in
            guard case EntryRepository.EntryError.invalidCurrencyAmount("JPY") = error else {
                return XCTFail("Expected JPY precision error, got \(error)")
            }
        }
    }

    func testLegacySinglePayerMigrationIsIdempotent() async throws {
        let fixture = try makeFixture(currencyCode: "TWD")
        let context = fixture.persistence.container.viewContext
        let entry = LedgerEntry(context: context)
        context.assign(entry, to: fixture.persistence.store(for: fixture.book))
        entry.id = UUID()
        entry.amount = 125
        entry.kind = EntryKind.expense.rawValue
        entry.note = "舊交易"
        entry.splitMode = SplitMode.equal.rawValue
        entry.group = fixture.group
        entry.book = fixture.book
        entry.sourceAccount = fixture.account
        entry.payer = fixture.owner
        try context.save()

        try await fixture.repository.migrateLegacyPayments()
        try await fixture.repository.migrateLegacyPayments()

        let payments = entry.payments as? Set<EntryPayment> ?? []
        XCTAssertEqual(payments.count, 1)
        XCTAssertEqual(payments.first?.member, fixture.owner)
        XCTAssertEqual(payments.first?.amount as Decimal?, 125)
    }

    private func makeFixture(currencyCode: String) throws -> EntryFixture {
        let persistence = PersistenceController(inMemory: true)
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(
                name: "家庭",
                ownerDisplayName: "小明",
                currencyCode: currencyCode
            )
        )
        let owner = try XCTUnwrap((group.members as? Set<Member>)?.first)
        let context = persistence.container.viewContext
        let friend = Member(context: context)
        context.assign(friend, to: persistence.store(for: group))
        friend.id = UUID()
        friend.displayName = "小美"
        friend.invitationStatus = InvitationStatus.accepted.rawValue
        friend.role = MemberRole.member.rawValue
        friend.group = group
        let book = try XCTUnwrap(BookRepository(persistence: persistence).defaultBook(in: group))
        let account = try AccountRepository(persistence: persistence).createAccount(
            from: AccountDraft(name: "現金"),
            in: group
        )
        try context.save()
        return EntryFixture(
            persistence: persistence,
            group: group,
            book: book,
            account: account,
            owner: owner,
            friend: friend,
            repository: EntryRepository(persistence: persistence)
        )
    }
}

@MainActor
private struct EntryFixture {
    let persistence: PersistenceController
    let group: LedgerGroup
    let book: LedgerBook
    let account: LedgerAccount
    let owner: Member
    let friend: Member
    let repository: EntryRepository
}

final class SplitPaymentModelMigrationTests: XCTestCase {
    func testV6ToV7LightweightMappingCanBeInferred() throws {
        let bundle = Bundle(for: PersistenceController.self)
        let modelDirectory = try XCTUnwrap(
            bundle.url(forResource: "SharedLedger", withExtension: "momd")
        )
        let sourceModel = try XCTUnwrap(
            NSManagedObjectModel(
                contentsOf: modelDirectory.appendingPathComponent("SharedLedgerV6.mom")
            )
        )
        let destinationModel = try XCTUnwrap(
            NSManagedObjectModel(
                contentsOf: modelDirectory.appendingPathComponent("SharedLedgerV7.mom")
            )
        )

        XCTAssertNoThrow(
            try NSMappingModel.inferredMappingModel(
                forSourceModel: sourceModel,
                destinationModel: destinationModel
            )
        )
        XCTAssertNotNil(destinationModel.entitiesByName["EntryPayment"])
        XCTAssertEqual(
            destinationModel.entitiesByName["LedgerEntry"]?
                .attributesByName["splitMode"]?.defaultValue as? String,
            SplitMode.equal.rawValue
        )
    }
}
