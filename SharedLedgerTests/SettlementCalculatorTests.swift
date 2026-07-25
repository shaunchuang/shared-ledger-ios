import XCTest
@testable import SharedLedger

final class SettlementCalculatorTests: XCTestCase {
    func testExpenseProducesMemberBalancesAndTwoTransfers() throws {
        let owner = UUID()
        let friendA = UUID()
        let friendB = UUID()

        let result = try SettlementCalculator.calculate(
            transactions: [
                SettlementTransactionInput(
                    kind: .expense,
                    payments: [PaymentInput(memberID: owner, amount: 120)],
                    splits: [
                        SettlementShareInput(memberID: owner, amount: 40),
                        SettlementShareInput(memberID: friendA, amount: 40),
                        SettlementShareInput(memberID: friendB, amount: 40)
                    ]
                )
            ],
            currencyCode: "TWD"
        )

        XCTAssertEqual(balance(for: owner, in: result), 80)
        XCTAssertEqual(balance(for: friendA, in: result), -40)
        XCTAssertEqual(balance(for: friendB, in: result), -40)
        XCTAssertEqual(result.suggestedTransfers.count, 2)
        XCTAssertEqual(result.suggestedTransfers.reduce(Decimal.zero) { $0 + $1.amount }, 80)
    }

    func testIncomeReversesObligationDirection() throws {
        let receiver = UUID()
        let friend = UUID()

        let result = try SettlementCalculator.calculate(
            transactions: [
                SettlementTransactionInput(
                    kind: .income,
                    payments: [PaymentInput(memberID: receiver, amount: 60)],
                    splits: [
                        SettlementShareInput(memberID: receiver, amount: 30),
                        SettlementShareInput(memberID: friend, amount: 30)
                    ]
                )
            ],
            currencyCode: "TWD"
        )

        XCTAssertEqual(balance(for: receiver, in: result), -30)
        XCTAssertEqual(balance(for: friend, in: result), 30)
        XCTAssertEqual(result.suggestedTransfers.count, 1)
        XCTAssertEqual(result.suggestedTransfers.first?.fromMemberID, receiver)
        XCTAssertEqual(result.suggestedTransfers.first?.toMemberID, friend)
        XCTAssertEqual(result.suggestedTransfers.first?.amount, 30)
    }

    func testPartialSettlementReducesOutstandingBalances() throws {
        let owner = UUID()
        let friendA = UUID()
        let friendB = UUID()
        let transaction = SettlementTransactionInput(
            kind: .expense,
            payments: [PaymentInput(memberID: owner, amount: 120)],
            splits: [
                SettlementShareInput(memberID: owner, amount: 40),
                SettlementShareInput(memberID: friendA, amount: 40),
                SettlementShareInput(memberID: friendB, amount: 40)
            ]
        )

        let result = try SettlementCalculator.calculate(
            transactions: [transaction],
            settlements: [
                SettlementRecordInput(
                    id: UUID(),
                    fromMemberID: friendA,
                    toMemberID: owner,
                    amount: 20
                )
            ],
            currencyCode: "TWD"
        )

        XCTAssertEqual(balance(for: owner, in: result), 60)
        XCTAssertEqual(balance(for: friendA, in: result), -20)
        XCTAssertEqual(balance(for: friendB, in: result), -40)
        XCTAssertEqual(result.suggestedTransfers.reduce(Decimal.zero) { $0 + $1.amount }, 60)
    }

    func testSettlementHonorsCurrencyMinorUnits() throws {
        let owner = UUID()
        let friend = UUID()
        let transaction = SettlementTransactionInput(
            kind: .expense,
            payments: [PaymentInput(memberID: owner, amount: 1)],
            splits: [
                SettlementShareInput(memberID: owner, amount: 0),
                SettlementShareInput(memberID: friend, amount: 1)
            ]
        )

        XCTAssertNoThrow(
            try SettlementCalculator.calculate(
                transactions: [transaction],
                currencyCode: "JPY"
            )
        )

        XCTAssertThrowsError(
            try SettlementCalculator.calculate(
                transactions: [transaction],
                settlements: [
                    SettlementRecordInput(
                        id: UUID(),
                        fromMemberID: friend,
                        toMemberID: owner,
                        amount: Decimal(string: "0.5")!
                    )
                ],
                currencyCode: "JPY"
            )
        ) { error in
            XCTAssertEqual(
                error as? SettlementCalculator.SettlementError,
                .invalidCurrencyAmount("JPY")
            )
        }
    }

    func testLargeGroupSettlesEveryBalanceWithBoundedTransfers() throws {
        // Above the exact-search limit the greedy fallback takes over. It must still
        // clear every balance, and must not exceed n - 1 transfers.
        let memberIDs = (0..<24).map { _ in UUID() }
        let payer = memberIDs[0]
        var splits: [SettlementShareInput] = []
        for memberID in memberIDs {
            splits.append(SettlementShareInput(memberID: memberID, amount: 100))
        }

        let transaction = SettlementTransactionInput(
            kind: .expense,
            payments: [PaymentInput(memberID: payer, amount: 2400)],
            splits: splits
        )
        let result = try SettlementCalculator.calculate(
            transactions: [transaction],
            currencyCode: "TWD"
        )

        XCTAssertEqual(balance(for: payer, in: result), 2300)
        XCTAssertLessThanOrEqual(result.suggestedTransfers.count, memberIDs.count - 1)
        XCTAssertTrue(result.suggestedTransfers.allSatisfy { $0.amount > 0 })
        assertTransfersClearAllBalances(result)
    }

    func testUnevenLargeGroupIsFullyClearedByGreedyFallback() throws {
        // Mixed debtors and creditors of differing sizes, so greedy has to split a
        // single creditor across several debtors.
        let memberIDs = (0..<16).map { _ in UUID() }
        var transactions: [SettlementTransactionInput] = []
        for index in 0..<3 {
            let paidAmount = Decimal(160 * (index + 1))
            let shareAmount = Decimal(10 * (index + 1))
            var splits: [SettlementShareInput] = []
            for memberID in memberIDs {
                splits.append(SettlementShareInput(memberID: memberID, amount: shareAmount))
            }
            transactions.append(
                SettlementTransactionInput(
                    kind: .expense,
                    payments: [PaymentInput(memberID: memberIDs[index], amount: paidAmount)],
                    splits: splits
                )
            )
        }

        let result = try SettlementCalculator.calculate(
            transactions: transactions,
            currencyCode: "TWD"
        )

        XCTAssertLessThanOrEqual(result.suggestedTransfers.count, memberIDs.count - 1)
        XCTAssertTrue(result.suggestedTransfers.allSatisfy { $0.amount > 0 })
        assertTransfersClearAllBalances(result)
    }

    /// Applying every suggested transfer must drive all member balances to zero.
    private func assertTransfersClearAllBalances(
        _ result: SettlementResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var remaining = Dictionary(
            uniqueKeysWithValues: result.balances.map { ($0.memberID, $0.amount) }
        )
        for transfer in result.suggestedTransfers {
            remaining[transfer.fromMemberID, default: 0] += transfer.amount
            remaining[transfer.toMemberID, default: 0] -= transfer.amount
        }
        for (memberID, amount) in remaining {
            XCTAssertEqual(amount, 0, "member \(memberID) left with \(amount)", file: file, line: line)
        }
    }

    private func balance(for memberID: UUID, in result: SettlementResult) -> Decimal? {
        result.balances.first { $0.memberID == memberID }?.amount
    }
}

@MainActor
final class SettlementRepositoryTests: XCTestCase {
    func testRecordAndReverseSettlementUpdatesOutstandingBalance() throws {
        let fixture = try makeFixture()
        let ownerID = try XCTUnwrap(fixture.owner.id)
        let friendID = try XCTUnwrap(fixture.friend.id)

        _ = try EntryRepository(persistence: fixture.persistence).createEntry(
            from: TransactionDraft(
                kind: .expense,
                amountText: "100",
                sourceAccountID: fixture.account.id,
                splitMemberIDs: [ownerID, friendID],
                paymentDrafts: [
                    TransactionPaymentDraft(memberID: ownerID, amountText: "100")
                ]
            ),
            in: fixture.book,
            accounts: [fixture.account],
            categories: [],
            members: [fixture.owner, fixture.friend]
        )

        let repository = SettlementRepository(persistence: fixture.persistence)
        let initial = try repository.result(in: fixture.book)
        XCTAssertEqual(initial.balances.first { $0.memberID == ownerID }?.amount, 50)
        XCTAssertEqual(initial.balances.first { $0.memberID == friendID }?.amount, -50)

        let settlement = try repository.recordSettlement(
            from: fixture.friend,
            to: fixture.owner,
            amount: 20,
            note: "銀行轉帳",
            in: fixture.book
        )

        let partial = try repository.result(in: fixture.book)
        XCTAssertEqual(partial.balances.first { $0.memberID == ownerID }?.amount, 30)
        XCTAssertEqual(partial.balances.first { $0.memberID == friendID }?.amount, -30)
        XCTAssertEqual(repository.history(in: fixture.book).first?.note, "銀行轉帳")

        try repository.reverseSettlement(settlement, in: fixture.book)

        let restored = try repository.result(in: fixture.book)
        XCTAssertEqual(restored.balances.first { $0.memberID == ownerID }?.amount, 50)
        XCTAssertEqual(restored.balances.first { $0.memberID == friendID }?.amount, -50)
        XCTAssertTrue(repository.history(in: fixture.book).first?.isReversed == true)
    }

    func testViewerCannotRecordSettlement() throws {
        let fixture = try makeFixture()
        let ownerID = try XCTUnwrap(fixture.owner.id)
        let friendID = try XCTUnwrap(fixture.friend.id)

        _ = try EntryRepository(persistence: fixture.persistence).createEntry(
            from: TransactionDraft(
                kind: .expense,
                amountText: "100",
                sourceAccountID: fixture.account.id,
                splitMemberIDs: [ownerID, friendID],
                paymentDrafts: [
                    TransactionPaymentDraft(memberID: ownerID, amountText: "100")
                ]
            ),
            in: fixture.book,
            accounts: [fixture.account],
            categories: [],
            members: [fixture.owner, fixture.friend]
        )

        fixture.friend.role = MemberRole.viewer.rawValue
        CurrentMemberIdentityRepository(persistence: fixture.persistence)
            .setCurrentMember(fixture.friend, in: fixture.group)
        try fixture.persistence.container.viewContext.save()

        let repository = SettlementRepository(persistence: fixture.persistence)
        XCTAssertFalse(repository.canRecordSettlements(in: fixture.book))
        XCTAssertThrowsError(
            try repository.recordSettlement(
                from: fixture.friend,
                to: fixture.owner,
                amount: 10,
                note: "",
                in: fixture.book
            )
        ) { error in
            guard case SettlementRepository.RepositoryError.permissionDenied = error else {
                return XCTFail("Expected permissionDenied, got \(error)")
            }
        }
    }

    func testEntryWithUnsyncedSplitMemberIsSkippedWithoutFailingTheBook() throws {
        let fixture = try makeFixture()
        let ownerID = try XCTUnwrap(fixture.owner.id)
        let friendID = try XCTUnwrap(fixture.friend.id)
        let entryRepository = EntryRepository(persistence: fixture.persistence)

        _ = try entryRepository.createEntry(
            from: TransactionDraft(
                kind: .expense,
                amountText: "100",
                sourceAccountID: fixture.account.id,
                splitMemberIDs: [ownerID, friendID],
                paymentDrafts: [
                    TransactionPaymentDraft(memberID: ownerID, amountText: "100")
                ]
            ),
            in: fixture.book,
            accounts: [fixture.account],
            categories: [],
            members: [fixture.owner, fixture.friend]
        )

        let pending = try entryRepository.createEntry(
            from: TransactionDraft(
                kind: .expense,
                amountText: "60",
                sourceAccountID: fixture.account.id,
                splitMemberIDs: [ownerID, friendID],
                paymentDrafts: [
                    TransactionPaymentDraft(memberID: friendID, amountText: "60")
                ]
            ),
            in: fixture.book,
            accounts: [fixture.account],
            categories: [],
            members: [fixture.owner, fixture.friend]
        )

        // Simulate the shared store having imported the entry before the Member that
        // one of its splits points at.
        let pendingSplit = try XCTUnwrap((pending.splits as? Set<EntrySplit>)?.first)
        pendingSplit.member = nil
        try fixture.persistence.container.viewContext.save()

        let repository = SettlementRepository(persistence: fixture.persistence)
        let snapshot = try repository.snapshot(in: fixture.book)

        XCTAssertEqual(snapshot.skippedEntryCount, 1)
        XCTAssertTrue(snapshot.hasSkippedEntries)
        // The intact 100 expense still settles normally.
        XCTAssertEqual(snapshot.result.balances.first { $0.memberID == ownerID }?.amount, 50)
        XCTAssertEqual(snapshot.result.balances.first { $0.memberID == friendID }?.amount, -50)
        XCTAssertEqual(snapshot.result.suggestedTransfers.count, 1)
    }

    private func makeFixture() throws -> SettlementFixture {
        let persistence = PersistenceController(inMemory: true)
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(
                name: "家庭",
                ownerDisplayName: "小明",
                currencyCode: "TWD"
            )
        )
        let owner = try XCTUnwrap((group.members as? Set<Member>)?.first)
        let context = persistence.container.viewContext
        let friend = Member(context: context)
        context.assign(friend, to: persistence.store(for: group))
        friend.id = UUID()
        friend.displayName = "小美"
        friend.role = MemberRole.member.rawValue
        friend.invitationStatus = InvitationStatus.accepted.rawValue
        friend.joinedAt = Date()
        friend.group = group
        let book = try XCTUnwrap(BookRepository(persistence: persistence).defaultBook(in: group))
        let account = try AccountRepository(persistence: persistence).createAccount(
            from: AccountDraft(name: "現金"),
            in: group
        )
        CurrentMemberIdentityRepository(persistence: persistence)
            .setCurrentMember(owner, in: group)
        try context.save()
        return SettlementFixture(
            persistence: persistence,
            group: group,
            book: book,
            account: account,
            owner: owner,
            friend: friend
        )
    }
}

@MainActor
private struct SettlementFixture {
    let persistence: PersistenceController
    let group: LedgerGroup
    let book: LedgerBook
    let account: LedgerAccount
    let owner: Member
    let friend: Member
}
