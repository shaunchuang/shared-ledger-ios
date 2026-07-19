import CoreData
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
        XCTAssertEqual(adjustment?.amount as Decimal?, 25)
        XCTAssertEqual(adjustment?.account, source)
        XCTAssertEqual(adjustment?.note, "依帳單調整")
        XCTAssertEqual(repository.currentBalance(for: source), 125)

        let entries = group.entries as? Set<LedgerEntry> ?? []
        XCTAssertFalse(entries.contains { $0.kind == EntryKind.balanceAdjustment.rawValue })

        let reconciliationDate = Date(timeIntervalSince1970: 1_700_000_000)
        try repository.reconcile(source, at: reconciliationDate)
        XCTAssertEqual(source.lastReconciledAt, reconciliationDate)
        XCTAssertEqual(source.lastReconciledBalance as Decimal?, 125)

        let auditActions = (group.auditEvents as? Set<AuditEvent> ?? []).compactMap(\.action)
        XCTAssertTrue(auditActions.contains("account.balance.adjusted"))
        XCTAssertTrue(auditActions.contains("account.reconciled"))
    }

    func testLegacyBalanceAdjustmentMigrationIsIdempotentAndPreservesBalance() async throws {
        let persistence = PersistenceController(inMemory: true)
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(name: "家庭", ownerDisplayName: "小明")
        )
        let repository = AccountRepository(persistence: persistence)
        let account = try repository.createAccount(
            from: AccountDraft(name: "現金", openingBalanceText: "100"),
            in: group
        )
        let context = persistence.container.viewContext
        let legacyID = UUID()
        let legacyEntry = LedgerEntry(context: context)
        context.assign(legacyEntry, to: persistence.store(for: account))
        legacyEntry.id = legacyID
        legacyEntry.amount = 25
        legacyEntry.date = Date(timeIntervalSince1970: 1_700_000_000)
        legacyEntry.createdAt = legacyEntry.date
        legacyEntry.updatedAt = legacyEntry.date
        legacyEntry.kind = EntryKind.balanceAdjustment.rawValue
        legacyEntry.note = "舊版調整"
        legacyEntry.group = group
        legacyEntry.sourceAccount = account
        try context.save()

        XCTAssertEqual(repository.currentBalance(for: account), 125)

        try await repository.migrateLegacyBalanceAdjustments()
        try await repository.migrateLegacyBalanceAdjustments()
        context.refresh(account, mergeChanges: false)

        let entryRequest = NSFetchRequest<LedgerEntry>(entityName: "LedgerEntry")
        entryRequest.predicate = NSPredicate(format: "kind == %@", EntryKind.balanceAdjustment.rawValue)
        XCTAssertTrue(try context.fetch(entryRequest).isEmpty)

        let adjustmentRequest = NSFetchRequest<AccountAdjustment>(entityName: "AccountAdjustment")
        let adjustments = try context.fetch(adjustmentRequest)
        XCTAssertEqual(adjustments.count, 1)
        XCTAssertEqual(adjustments.first?.id, legacyID)
        XCTAssertEqual(adjustments.first?.amount as Decimal?, 25)
        XCTAssertEqual(adjustments.first?.account, account)
        XCTAssertEqual(repository.currentBalance(for: account), 125)
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

    func testAccountsAreGroupScopedWhileCategoriesAndEntriesRemainBookScoped() throws {
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
        let sharedAccount = try accountRepository.createAccount(
            from: AccountDraft(name: "共用現金"),
            in: group
        )
        let homeCategory = try CategoryRepository(persistence: persistence).createCategory(
            from: CategoryDraft(name: "家用"),
            in: defaultBook,
            parent: nil
        )
        let travelCategory = try CategoryRepository(persistence: persistence).createCategory(
            from: CategoryDraft(name: "交通"),
            in: travelBook,
            parent: nil
        )
        let members = Array(group.members as? Set<Member> ?? [])
        let ownerID = try XCTUnwrap(members.first?.id)
        let draft = TransactionDraft(
            kind: .expense,
            amountText: "500",
            categoryID: travelCategory.id,
            sourceAccountID: sharedAccount.id,
            payerMemberID: ownerID,
            splitMemberIDs: [ownerID]
        )
        let entry = try EntryRepository(persistence: persistence).createEntry(
            from: draft,
            in: travelBook,
            accounts: [sharedAccount],
            categories: [homeCategory, travelCategory],
            members: members
        )

        XCTAssertEqual(sharedAccount.group, group)
        XCTAssertEqual(travelCategory.book, travelBook)
        XCTAssertEqual(entry.book, travelBook)
        XCTAssertEqual(entry.sourceAccount, sharedAccount)

        XCTAssertThrowsError(
            try EntryRepository(persistence: persistence).createEntry(
                from: TransactionDraft(
                    kind: .expense,
                    amountText: "100",
                    categoryID: homeCategory.id,
                    sourceAccountID: sharedAccount.id,
                    payerMemberID: ownerID,
                    splitMemberIDs: [ownerID]
                ),
                in: travelBook,
                accounts: [sharedAccount],
                categories: [homeCategory, travelCategory],
                members: members
            )
        ) { error in
            guard case EntryRepository.EntryError.crossScopeReference = error else {
                return XCTFail("Expected crossScopeReference, got \(error)")
            }
        }

        let otherGroup = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(name: "室友", ownerDisplayName: "小華")
        )
        let foreignAccount = try accountRepository.createAccount(
            from: AccountDraft(name: "室友現金"),
            in: otherGroup
        )

        XCTAssertThrowsError(
            try EntryRepository(persistence: persistence).createEntry(
                from: TransactionDraft(
                    kind: .expense,
                    amountText: "100",
                    sourceAccountID: foreignAccount.id,
                    payerMemberID: ownerID,
                    splitMemberIDs: [ownerID]
                ),
                in: travelBook,
                accounts: [sharedAccount, foreignAccount],
                categories: [],
                members: members
            )
        ) { error in
            guard case EntryRepository.EntryError.crossScopeReference = error else {
                return XCTFail("Expected crossScopeReference, got \(error)")
            }
        }
    }

    func testGroupAccountBalanceIncludesEntriesFromMultipleBooks() throws {
        let persistence = PersistenceController(inMemory: true)
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(name: "家庭", ownerDisplayName: "小明")
        )
        let bookRepository = BookRepository(persistence: persistence)
        let defaultBook = try XCTUnwrap(bookRepository.defaultBook(in: group))
        let travelBook = try bookRepository.createBook(from: BookDraft(name: "旅行"), in: group)
        let accountRepository = AccountRepository(persistence: persistence)
        let account = try accountRepository.createAccount(
            from: AccountDraft(name: "銀行", openingBalanceText: "100"),
            in: group
        )
        let members = Array(group.members as? Set<Member> ?? [])
        let ownerID = try XCTUnwrap(members.first?.id)
        let entryRepository = EntryRepository(persistence: persistence)

        try entryRepository.createEntry(
            from: TransactionDraft(
                kind: .expense,
                amountText: "20",
                sourceAccountID: account.id,
                payerMemberID: ownerID,
                splitMemberIDs: [ownerID]
            ),
            in: defaultBook,
            accounts: [account],
            categories: [],
            members: members
        )
        try entryRepository.createEntry(
            from: TransactionDraft(
                kind: .income,
                amountText: "50",
                sourceAccountID: account.id,
                payerMemberID: ownerID,
                splitMemberIDs: [ownerID]
            ),
            in: travelBook,
            accounts: [account],
            categories: [],
            members: members
        )

        XCTAssertEqual(accountRepository.currentBalance(for: account), 130)
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

    func testArchivedBookAndAccountCannotReceiveNewEntries() throws {
        let persistence = PersistenceController(inMemory: true)
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(name: "家庭", ownerDisplayName: "小明")
        )
        let bookRepository = BookRepository(persistence: persistence)
        let archivedBook = try XCTUnwrap(bookRepository.defaultBook(in: group))
        let activeBook = try bookRepository.createBook(from: BookDraft(name: "旅行"), in: group)
        let accountRepository = AccountRepository(persistence: persistence)
        let account = try accountRepository.createAccount(
            from: AccountDraft(name: "現金"),
            in: group
        )
        let members = Array(group.members as? Set<Member> ?? [])
        let ownerID = try XCTUnwrap(members.first?.id)
        let draft = TransactionDraft(
            kind: .expense,
            amountText: "100",
            sourceAccountID: account.id,
            payerMemberID: ownerID,
            splitMemberIDs: [ownerID]
        )
        let entryRepository = EntryRepository(persistence: persistence)

        try bookRepository.archiveBook(archivedBook)
        XCTAssertThrowsError(
            try entryRepository.createEntry(
                from: draft,
                in: archivedBook,
                accounts: [account],
                categories: [],
                members: members
            )
        ) { error in
            guard case EntryRepository.EntryError.archivedBook = error else {
                return XCTFail("Expected archivedBook, got \(error)")
            }
        }

        let categoryRepository = CategoryRepository(persistence: persistence)
        let category = try categoryRepository.createCategory(
            from: CategoryDraft(name: "交通"),
            in: activeBook,
            parent: nil
        )
        try categoryRepository.archiveCategory(category)
        var archivedCategoryDraft = draft
        archivedCategoryDraft.categoryID = category.id
        XCTAssertThrowsError(
            try entryRepository.createEntry(
                from: archivedCategoryDraft,
                in: activeBook,
                accounts: [account],
                categories: [category],
                members: members
            )
        ) { error in
            guard case EntryRepository.EntryError.archivedCategory = error else {
                return XCTFail("Expected archivedCategory, got \(error)")
            }
        }

        try accountRepository.archiveAccount(account)
        XCTAssertThrowsError(
            try entryRepository.createEntry(
                from: draft,
                in: activeBook,
                accounts: [account],
                categories: [],
                members: members
            )
        ) { error in
            guard case EntryRepository.EntryError.archivedAccount = error else {
                return XCTFail("Expected archivedAccount, got \(error)")
            }
        }
    }

    func testBackfillAssignsLegacyBookOwnedObjectsToDefaultBook() async throws {
        let persistence = PersistenceController(inMemory: true)
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(name: "家庭", ownerDisplayName: "小明")
        )
        let defaultBook = try XCTUnwrap(BookRepository(persistence: persistence).defaultBook(in: group))
        let category = try CategoryRepository(persistence: persistence).createCategory(
            from: CategoryDraft(name: "餐飲"),
            in: defaultBook,
            parent: nil
        )
        category.book = nil
        try persistence.container.viewContext.save()

        try await BookRepository(persistence: persistence).backfillMissingBookRelationships()
        persistence.container.viewContext.refresh(category, mergeChanges: false)

        XCTAssertEqual(category.book, defaultBook)
    }
}
