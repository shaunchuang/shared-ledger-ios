import XCTest
@testable import SharedLedger

final class CategoryNodeTests: XCTestCase {
    func testDepthIncludesDeepestDescendant() {
        let tree = CategoryNode(
            name: "交通",
            children: [
                CategoryNode(
                    name: "汽車",
                    children: [CategoryNode(name: "加油")]
                ),
                CategoryNode(name: "大眾運輸")
            ]
        )

        XCTAssertEqual(tree.depth, 3)
    }

    func testContainsFindsNestedCategory() {
        let target = CategoryNode(name: "捷運")
        let tree = CategoryNode(
            name: "交通",
            children: [CategoryNode(name: "大眾運輸", children: [target])]
        )

        XCTAssertTrue(tree.contains(id: target.id))
        XCTAssertFalse(tree.contains(id: UUID()))
    }
}

final class GroupDraftTests: XCTestCase {
    func testRequiresGroupAndOwnerNames() {
        XCTAssertFalse(GroupDraft().canCreate)

        let valid = GroupDraft(name: "家庭", ownerDisplayName: "小明")
        XCTAssertTrue(valid.canCreate)
    }

    func testAddingInviteesIgnoresExistingContact() {
        let contact = InviteeContact(contactIdentifier: "contact-1", displayName: "小美")
        var draft = GroupDraft(name: "家庭", invitees: [contact])

        draft.addInvitees([contact])

        XCTAssertEqual(draft.invitees, [contact])
    }

    func testAddingInviteesDeduplicatesWithinSameBatch() {
        let contact = InviteeContact(contactIdentifier: "contact-1", displayName: "小美")
        var draft = GroupDraft(name: "家庭")

        draft.addInvitees([contact, contact])

        XCTAssertEqual(draft.invitees, [contact])
    }
}

final class AccountBalanceCalculatorTests: XCTestCase {
    func testAccountDraftRequiresValidOpeningBalance() {
        XCTAssertTrue(AccountDraft(name: "現金", openingBalanceText: "0").canCreate)
        XCTAssertTrue(AccountDraft(name: "信用卡", openingBalanceText: "-1200.5").canCreate)
        XCTAssertFalse(AccountDraft(name: "現金", openingBalanceText: "不是金額").canCreate)
    }

    func testBalanceIncludesIncomeExpenseTransfersAndAdjustment() {
        let movements = [
            AccountBalanceMovement(kind: .income, amount: 50, isSourceAccount: true, isDestinationAccount: false),
            AccountBalanceMovement(kind: .expense, amount: 20, isSourceAccount: true, isDestinationAccount: false),
            AccountBalanceMovement(kind: .transfer, amount: 30, isSourceAccount: true, isDestinationAccount: false),
            AccountBalanceMovement(kind: .transfer, amount: 10, isSourceAccount: false, isDestinationAccount: true),
            AccountBalanceMovement(kind: .balanceAdjustment, amount: -5, isSourceAccount: true, isDestinationAccount: false)
        ]

        XCTAssertEqual(
            AccountBalanceCalculator.balance(openingBalance: 100, movements: movements),
            105
        )
    }

    func testTransferDoesNotChangeCombinedAccountBalance() {
        let outgoing = AccountBalanceMovement(
            kind: .transfer,
            amount: 75,
            isSourceAccount: true,
            isDestinationAccount: false
        )
        let incoming = AccountBalanceMovement(
            kind: .transfer,
            amount: 75,
            isSourceAccount: false,
            isDestinationAccount: true
        )

        XCTAssertEqual(
            AccountBalanceCalculator.effect(of: outgoing)
                + AccountBalanceCalculator.effect(of: incoming),
            0
        )
    }
}

final class BookDraftTests: XCTestCase {
    func testBookNameIsRequired() {
        XCTAssertFalse(BookDraft().canCreate)
        XCTAssertFalse(BookDraft(name: "   ").canCreate)
        XCTAssertTrue(BookDraft(name: "家庭日常").canCreate)
    }
}

@MainActor
final class AccountBalanceRepositoryTests: XCTestCase {
    func testRepositoryDerivesAdjustsAndReconcilesBalance() throws {
        let persistence = PersistenceController(inMemory: true)
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(name: "家庭", ownerDisplayName: "小明")
        )
        let repository = AccountRepository(persistence: persistence)
        let source = try repository.createAccount(
            from: AccountDraft(name: "現金", openingBalanceText: "100"),
            in: group
        )
        let destination = try repository.createAccount(
            from: AccountDraft(name: "銀行", openingBalanceText: "10"),
            in: group
        )
        let members = Array(group.members as? Set<Member> ?? [])
        let ownerID = try XCTUnwrap(members.first?.id)
        let entryRepository = EntryRepository(persistence: persistence)

        try entryRepository.createEntry(
            from: TransactionDraft(
                kind: .income,
                amountText: "50",
                sourceAccountID: source.id,
                payerMemberID: ownerID,
                splitMemberIDs: [ownerID]
            ),
            in: group,
            accounts: [source, destination],
            categories: [],
            members: members
        )
        try entryRepository.createEntry(
            from: TransactionDraft(
                kind: .expense,
                amountText: "20",
                sourceAccountID: source.id,
                payerMemberID: ownerID,
                splitMemberIDs: [ownerID]
            ),
            in: group,
            accounts: [source, destination],
            categories: [],
            members: members
        )
        try entryRepository.createEntry(
            from: TransactionDraft(
                kind: .transfer,
                amountText: "30",
                sourceAccountID: source.id,
                destinationAccountID: destination.id
            ),
            in: group,
            accounts: [source, destination],
            categories: [],
            members: members
        )

        XCTAssertEqual(repository.currentBalance(for: source), 100)
        XCTAssertEqual(repository.currentBalance(for: destination), 40)

        let adjustment = try repository.adjustBalance(of: source, to: 125, note: "依帳單調整")
        XCTAssertEqual(adjustment?.kind, EntryKind.balanceAdjustment.rawValue)
        XCTAssertEqual(adjustment?.amount as Decimal?, 25)
        XCTAssertEqual(repository.currentBalance(for: source), 125)

        let reconciliationDate = Date(timeIntervalSince1970: 1_700_000_000)
        try repository.reconcile(source, at: reconciliationDate)
        XCTAssertEqual(source.lastReconciledAt, reconciliationDate)
        XCTAssertEqual(source.lastReconciledBalance as Decimal?, 125)

        let auditActions = (group.auditEvents as? Set<AuditEvent> ?? []).compactMap(\.action)
        XCTAssertTrue(auditActions.contains("account.balance.adjusted"))
        XCTAssertTrue(auditActions.contains("account.reconciled"))
    }
}

@MainActor
final class BookRepositoryTests: XCTestCase {
    func testNewGroupCreatesDefaultBook() throws {
        let persistence = PersistenceController(inMemory: true)
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(name: "家庭", ownerDisplayName: "小明")
        )

        let books = BookRepository(persistence: persistence).books(in: group)
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.name, BookDraft.defaultName)
        XCTAssertEqual(books.first?.isDefault, true)
    }

    func testAccountsCategoriesAndEntriesAreScopedToBook() throws {
        let persistence = PersistenceController(inMemory: true)
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(name: "家庭", ownerDisplayName: "小明")
        )
        let bookRepository = BookRepository(persistence: persistence)
        let defaultBook = try XCTUnwrap(bookRepository.defaultBook(in: group))
        let travelBook = try bookRepository.createBook(
            from: BookDraft(name: "日本旅行"),
            in: group
        )
        let accountRepository = AccountRepository(persistence: persistence)
        let homeAccount = try accountRepository.createAccount(
            from: AccountDraft(name: "家庭現金"),
            in: defaultBook
        )
        let travelAccount = try accountRepository.createAccount(
            from: AccountDraft(name: "旅費現金"),
            in: travelBook
        )
        let category = try CategoryRepository(persistence: persistence).createCategory(
            from: CategoryDraft(name: "交通"),
            in: travelBook,
            parent: nil
        )
        let members = Array(group.members as? Set<Member> ?? [])
        let ownerID = try XCTUnwrap(members.first?.id)
        let draft = TransactionDraft(
            kind: .expense,
            amountText: "500",
            categoryID: category.id,
            sourceAccountID: travelAccount.id,
            payerMemberID: ownerID,
            splitMemberIDs: [ownerID]
        )
        let entry = try EntryRepository(persistence: persistence).createEntry(
            from: draft,
            in: travelBook,
            accounts: [homeAccount, travelAccount],
            categories: [category],
            members: members
        )

        XCTAssertEqual(homeAccount.book, defaultBook)
        XCTAssertEqual(travelAccount.book, travelBook)
        XCTAssertEqual(category.book, travelBook)
        XCTAssertEqual(entry.book, travelBook)
        XCTAssertEqual(entry.sourceAccount, travelAccount)

        XCTAssertThrowsError(
            try EntryRepository(persistence: persistence).createEntry(
                from: TransactionDraft(
                    kind: .expense,
                    amountText: "100",
                    sourceAccountID: homeAccount.id,
                    payerMemberID: ownerID,
                    splitMemberIDs: [ownerID]
                ),
                in: travelBook,
                accounts: [homeAccount, travelAccount],
                categories: [],
                members: members
            )
        )
    }

    func testArchivingDefaultBookPromotesAnotherBook() throws {
        let persistence = PersistenceController(inMemory: true)
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(name: "家庭", ownerDisplayName: "小明")
        )
        let repository = BookRepository(persistence: persistence)
        let originalDefault = try XCTUnwrap(repository.defaultBook(in: group))
        let replacement = try repository.createBook(from: BookDraft(name: "裝潢"), in: group)

        try repository.archiveBook(originalDefault)

        XCTAssertNotNil(originalDefault.archivedAt)
        XCTAssertFalse(originalDefault.isDefault)
        XCTAssertTrue(replacement.isDefault)
    }

    func testRenameDefaultSelectionAndReorderingArePersistedAndAudited() throws {
        let persistence = PersistenceController(inMemory: true)
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(name: "家庭", ownerDisplayName: "小明")
        )
        let repository = BookRepository(persistence: persistence)
        let home = try XCTUnwrap(repository.defaultBook(in: group))
        let travel = try repository.createBook(from: BookDraft(name: "旅行"), in: group)
        let renovation = try repository.createBook(from: BookDraft(name: "裝潢"), in: group)

        try repository.renameBook(travel, using: BookDraft(name: "日本旅行"))
        try repository.setDefaultBook(travel)
        try repository.reorderBooks([renovation, home, travel], in: group)

        XCTAssertEqual(travel.name, "日本旅行")
        XCTAssertTrue(travel.isDefault)
        XCTAssertFalse(home.isDefault)
        XCTAssertEqual(repository.books(in: group), [renovation, home, travel])

        let auditActions = (group.auditEvents as? Set<AuditEvent> ?? []).compactMap(\.action)
        XCTAssertTrue(auditActions.contains("book.renamed"))
        XCTAssertTrue(auditActions.contains("book.default.changed"))
        XCTAssertTrue(auditActions.contains("book.reordered"))
    }

    func testOnlyActiveBookCannotBeArchived() throws {
        let persistence = PersistenceController(inMemory: true)
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(name: "家庭", ownerDisplayName: "小明")
        )
        let repository = BookRepository(persistence: persistence)
        let onlyBook = try XCTUnwrap(repository.defaultBook(in: group))

        XCTAssertThrowsError(try repository.archiveBook(onlyBook)) { error in
            guard case BookRepository.BookError.cannotArchiveOnlyBook = error else {
                return XCTFail("Expected cannotArchiveOnlyBook, got \(error)")
            }
        }
        XCTAssertNil(onlyBook.archivedAt)
        XCTAssertTrue(onlyBook.isDefault)
    }

    func testBackfillAssignsLegacyObjectsToDefaultBook() async throws {
        let persistence = PersistenceController(inMemory: true)
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(name: "家庭", ownerDisplayName: "小明")
        )
        let account = try AccountRepository(persistence: persistence).createAccount(
            from: AccountDraft(name: "現金"),
            in: group
        )
        account.book = nil
        try persistence.container.viewContext.save()

        try await BookRepository(persistence: persistence).backfillMissingBookRelationships()
        persistence.container.viewContext.refresh(account, mergeChanges: false)

        XCTAssertEqual(account.book, BookRepository(persistence: persistence).defaultBook(in: group))
    }
}
