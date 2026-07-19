import CloudKit
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

final class LedgerCurrencyTests: XCTestCase {
    func testCurrencyPrecisionUsesISOFractionDigits() throws {
        XCTAssertEqual(LedgerCurrency.fractionDigits(for: "JPY"), 0)
        XCTAssertEqual(LedgerCurrency.fractionDigits(for: "KWD"), 3)
        XCTAssertFalse(
            LedgerCurrency.isValidAmount(
                try XCTUnwrap(Decimal(string: "1.5")),
                currencyCode: "JPY"
            )
        )
        XCTAssertTrue(
            LedgerCurrency.isValidAmount(
                try XCTUnwrap(Decimal(string: "1.234")),
                currencyCode: "KWD"
            )
        )
    }

    func testCurrencyRoundingUsesRequestedPrecision() throws {
        XCTAssertEqual(
            LedgerCurrency.rounded(
                try XCTUnwrap(Decimal(string: "1.2345")),
                currencyCode: "KWD"
            ),
            try XCTUnwrap(Decimal(string: "1.235"))
        )
    }
}

@MainActor
final class CurrencyPersistenceTests: XCTestCase {
    func testGroupPersistsSelectedCurrencyAndRejectsInvalidMinorUnits() throws {
        let persistence = PersistenceController(inMemory: true)
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(
                name: "日本旅行",
                ownerDisplayName: "小明",
                currencyCode: "JPY"
            )
        )

        XCTAssertEqual(group.currencyCode, "JPY")
        XCTAssertThrowsError(
            try AccountRepository(persistence: persistence).createAccount(
                from: AccountDraft(name: "現金", openingBalanceText: "1.5"),
                in: group
            )
        ) { error in
            guard case AccountRepository.AccountError.invalidCurrencyAmount("JPY") = error else {
                return XCTFail("Expected JPY precision error, got \(error)")
            }
        }
    }
}

@MainActor
final class CloudSharingTests: XCTestCase {
    func testPrepareShareReusesExistingShare() async throws {
        var existingGroupID: NSManagedObjectID?
        var fetchedObjectIDs: [NSManagedObjectID] = []
        let existingShare = CKShare(
            rootRecord: CKRecord(recordType: "LedgerGroup")
        )
        let persistence = PersistenceController(
            inMemory: true,
            shareFetcher: { objectIDs in
                fetchedObjectIDs = objectIDs
                guard let existingGroupID else { return [:] }
                return [existingGroupID: existingShare]
            }
        )
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(name: "家庭", ownerDisplayName: "小明")
        )
        existingGroupID = group.objectID

        let (share, cloudContainer) = try await persistence.prepareShare(for: group)

        XCTAssertEqual(fetchedObjectIDs, [group.objectID])
        XCTAssertEqual(share.recordID, existingShare.recordID)
        XCTAssertEqual(
            share[CKShare.SystemFieldKey.title] as? String,
            "家庭"
        )
        XCTAssertEqual(
            cloudContainer.containerIdentifier,
            "iCloud.com.shaunchuang.SharedLedger"
        )
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

    func testAccountsAndCategoriesAreGroupScopedWhileEntriesRemainBookScoped() throws {
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
        let sharedCategory = try CategoryRepository(persistence: persistence).createCategory(
            from: CategoryDraft(name: "餐飲"),
            in: group,
            parent: nil
        )
        let categoryRepository = CategoryRepository(persistence: persistence)

        XCTAssertEqual(homeCategory.group, group)
        XCTAssertEqual(travelCategory.group, group)
        XCTAssertNil(homeCategory.book)
        XCTAssertNil(travelCategory.book)
        XCTAssertTrue(categoryRepository.isCategoryAvailable(homeCategory, in: defaultBook))
        XCTAssertFalse(categoryRepository.isCategoryAvailable(homeCategory, in: travelBook))
        XCTAssertTrue(categoryRepository.isCategoryAvailable(travelCategory, in: travelBook))
        XCTAssertTrue(categoryRepository.isCategoryAvailable(sharedCategory, in: defaultBook))
        XCTAssertTrue(categoryRepository.isCategoryAvailable(sharedCategory, in: travelBook))

        let members = Array(group.members as? Set<Member> ?? [])
        let ownerID = try XCTUnwrap(members.first?.id)
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
                categories: [homeCategory, travelCategory, sharedCategory],
                members: members
            )
        ) { error in
            guard case EntryRepository.EntryError.crossScopeReference = error else {
                return XCTFail("Expected crossScopeReference, got \(error)")
            }
        }

        try categoryRepository.setCategory(homeCategory, enabled: true, in: travelBook)
        let entry = try EntryRepository(persistence: persistence).createEntry(
            from: TransactionDraft(
                kind: .expense,
                amountText: "500",
                categoryID: homeCategory.id,
                sourceAccountID: sharedAccount.id,
                payerMemberID: ownerID,
                splitMemberIDs: [ownerID]
            ),
            in: travelBook,
            accounts: [sharedAccount],
            categories: [homeCategory, travelCategory, sharedCategory],
            members: members
        )

        XCTAssertEqual(sharedAccount.group, group)
        XCTAssertEqual(entry.book, travelBook)
        XCTAssertEqual(entry.category, homeCategory)
        XCTAssertEqual(entry.sourceAccount, sharedAccount)

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

    func testLegacyCategoryAssignmentRepairIsIdempotent() async throws {
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
        let context = persistence.container.viewContext
        let assignments = category.bookAssignments as? Set<BookCategoryAssignment> ?? []
        assignments.forEach(context.delete)
        category.book = defaultBook
        try context.save()

        let repository = CategoryRepository(persistence: persistence)
        try await repository.repairLegacyCategoryAssignments()
        try await repository.repairLegacyCategoryAssignments()
        context.refresh(category, mergeChanges: false)

        let repairedAssignments = category.bookAssignments as? Set<BookCategoryAssignment> ?? []
        XCTAssertEqual(category.group, group)
        XCTAssertEqual(category.book, defaultBook)
        XCTAssertEqual(repairedAssignments.count, 1)
        XCTAssertEqual(repairedAssignments.first?.book, defaultBook)
        XCTAssertEqual(repairedAssignments.first?.category, category)
        XCTAssertEqual(repairedAssignments.first?.isEnabled, true)
    }

    func testCategoryAvailabilityCascadesWithoutChangingHistory() throws {
        let persistence = PersistenceController(inMemory: true)
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(name: "家庭", ownerDisplayName: "小明")
        )
        let book = try XCTUnwrap(BookRepository(persistence: persistence).defaultBook(in: group))
        let categoryRepository = CategoryRepository(persistence: persistence)
        let parent = try categoryRepository.createCategory(
            from: CategoryDraft(name: "交通"),
            in: group,
            parent: nil
        )
        let child = try categoryRepository.createCategory(
            from: CategoryDraft(name: "捷運"),
            in: group,
            parent: parent
        )
        let account = try AccountRepository(persistence: persistence).createAccount(
            from: AccountDraft(name: "現金"),
            in: group
        )
        let members = Array(group.members as? Set<Member> ?? [])
        let ownerID = try XCTUnwrap(members.first?.id)
        let draft = TransactionDraft(
            kind: .expense,
            amountText: "50",
            categoryID: child.id,
            sourceAccountID: account.id,
            payerMemberID: ownerID,
            splitMemberIDs: [ownerID]
        )
        let entryRepository = EntryRepository(persistence: persistence)
        let entry = try entryRepository.createEntry(
            from: draft,
            in: book,
            accounts: [account],
            categories: [parent, child],
            members: members
        )

        try categoryRepository.setCategory(parent, enabled: false, in: book)

        XCTAssertFalse(categoryRepository.isCategoryAvailable(parent, in: book))
        XCTAssertFalse(categoryRepository.isCategoryAvailable(child, in: book))
        XCTAssertEqual(entry.category, child)
        XCTAssertThrowsError(
            try entryRepository.createEntry(
                from: draft,
                in: book,
                accounts: [account],
                categories: [parent, child],
                members: members
            )
        ) { error in
            guard case EntryRepository.EntryError.crossScopeReference = error else {
                return XCTFail("Expected crossScopeReference, got \(error)")
            }
        }

        try categoryRepository.setCategory(child, enabled: true, in: book)
        XCTAssertTrue(categoryRepository.isCategoryAvailable(parent, in: book))
        XCTAssertTrue(categoryRepository.isCategoryAvailable(child, in: book))
    }

    func testNewBookCanUseAllCopyOrEmptyCategoryAssignments() throws {
        let persistence = PersistenceController(inMemory: true)
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(name: "家庭", ownerDisplayName: "小明")
        )
        let bookRepository = BookRepository(persistence: persistence)
        let defaultBook = try XCTUnwrap(bookRepository.defaultBook(in: group))
        let categoryRepository = CategoryRepository(persistence: persistence)
        let shared = try categoryRepository.createCategory(
            from: CategoryDraft(name: "餐飲"),
            in: group,
            parent: nil
        )
        let homeOnly = try categoryRepository.createCategory(
            from: CategoryDraft(name: "家用"),
            in: defaultBook,
            parent: nil
        )

        let allBook = try bookRepository.createBook(
            from: BookDraft(name: "全部"),
            in: group,
            categorySource: .allGroupCategories
        )
        let emptyBook = try bookRepository.createBook(
            from: BookDraft(name: "空白"),
            in: group,
            categorySource: .empty
        )
        try categoryRepository.setCategory(homeOnly, enabled: false, in: defaultBook)
        let copyBook = try bookRepository.createBook(
            from: BookDraft(name: "沿用"),
            in: group,
            categorySource: .copy(defaultBook)
        )

        XCTAssertEqual(Set(categoryRepository.availableCategories(in: allBook).map(\.objectID)), [shared.objectID, homeOnly.objectID])
        XCTAssertTrue(categoryRepository.availableCategories(in: emptyBook).isEmpty)
        XCTAssertEqual(categoryRepository.availableCategories(in: copyBook).map(\.objectID), [shared.objectID])
    }


    func testChildCategoryInheritsParentAvailabilityAcrossBooks() throws {
        let persistence = PersistenceController(inMemory: true)
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(name: "家庭", ownerDisplayName: "小明")
        )
        let bookRepository = BookRepository(persistence: persistence)
        let homeBook = try XCTUnwrap(bookRepository.defaultBook(in: group))
        let travelBook = try bookRepository.createBook(
            from: BookDraft(name: "旅行"),
            in: group
        )
        let repository = CategoryRepository(persistence: persistence)
        let parent = try repository.createCategory(
            from: CategoryDraft(name: "交通"),
            in: group,
            parent: nil
        )

        try repository.setCategory(parent, enabled: false, in: travelBook)
        let child = try repository.createCategory(
            from: CategoryDraft(name: "捷運"),
            in: group,
            parent: parent
        )

        XCTAssertTrue(repository.isCategoryAvailable(child, in: homeBook))
        XCTAssertFalse(repository.isCategoryAvailable(parent, in: travelBook))
        XCTAssertFalse(repository.isCategoryAvailable(child, in: travelBook))
        XCTAssertNil(repository.assignment(for: child, in: travelBook))

        try repository.setCategory(child, enabled: true, in: travelBook)

        XCTAssertTrue(repository.isCategoryAvailable(parent, in: travelBook))
        XCTAssertTrue(repository.isCategoryAvailable(child, in: travelBook))
    }

    func testCategoryMutationsRequireManagerPermissionAndFailClosed() throws {
        let persistence = PersistenceController(inMemory: true)
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(name: "家庭", ownerDisplayName: "小明")
        )
        let book = try XCTUnwrap(BookRepository(persistence: persistence).defaultBook(in: group))
        let repository = CategoryRepository(persistence: persistence)
        let category = try repository.createCategory(
            from: CategoryDraft(name: "餐飲"),
            in: group,
            parent: nil
        )
        let owner = try XCTUnwrap(
            CurrentMemberIdentityRepository(persistence: persistence)
                .currentMember(in: group)
        )
        owner.role = MemberRole.viewer.rawValue

        XCTAssertFalse(repository.canManageCategories(in: group))
        XCTAssertThrowsError(
            try repository.createCategory(
                from: CategoryDraft(name: "交通"),
                in: group,
                parent: nil
            )
        ) { error in
            guard case CategoryRepository.CategoryError.permissionDenied = error else {
                return XCTFail("Expected permissionDenied, got \(error)")
            }
        }
        XCTAssertThrowsError(
            try repository.setCategory(category, enabled: false, in: book)
        ) { error in
            guard case CategoryRepository.CategoryError.permissionDenied = error else {
                return XCTFail("Expected permissionDenied, got \(error)")
            }
        }
        XCTAssertThrowsError(
            try repository.archiveCategory(category)
        ) { error in
            guard case CategoryRepository.CategoryError.permissionDenied = error else {
                return XCTFail("Expected permissionDenied, got \(error)")
            }
        }

        owner.role = MemberRole.owner.rawValue
        XCTAssertTrue(repository.canManageCategories(in: group))
    }


    func testSharedMemberIdentityMappingUsesPrivateStore() throws {
        let persistence = PersistenceController(
            inMemory: true,
            inMemoryConfigurations: ["Private", "Shared"]
        )
        let context = persistence.container.viewContext
        let group = LedgerGroup(context: context)
        context.assign(group, to: persistence.sharedStore)
        group.id = UUID()
        group.name = "共享旅行"
        group.createdAt = Date()
        group.updatedAt = group.createdAt

        let pendingMember = Member(context: context)
        context.assign(pendingMember, to: persistence.sharedStore)
        pendingMember.id = UUID()
        pendingMember.displayName = "小華"
        pendingMember.invitationStatus = InvitationStatus.pending.rawValue
        pendingMember.role = MemberRole.member.rawValue
        pendingMember.group = group
        try context.save()

        let identityRepository = CurrentMemberIdentityRepository(persistence: persistence)
        XCTAssertNil(identityRepository.currentMember(in: group))
        XCTAssertTrue(identityRepository.needsResolution(for: group))

        let claimed = try GroupRepository(persistence: persistence)
            .claimCurrentMember(pendingMember, in: group)

        XCTAssertEqual(identityRepository.currentMember(in: group), claimed)
        XCTAssertFalse(identityRepository.needsResolution(for: group))
        XCTAssertEqual(claimed.invitationStatus, InvitationStatus.accepted.rawValue)

        let request = NSFetchRequest<LocalMemberIdentity>(entityName: "LocalMemberIdentity")
        request.affectedStores = [persistence.privateStore]
        let identities = try context.fetch(request)
        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(identities.first?.groupID, group.id)
        XCTAssertEqual(identities.first?.memberID, claimed.id)
        XCTAssertEqual(identities.first?.objectID.persistentStore, persistence.privateStore)

        claimed.role = MemberRole.administrator.rawValue
        XCTAssertTrue(
            CategoryRepository(persistence: persistence)
                .canManageCategories(in: group)
        )
    }

    func testSharedStoreCategoryAndAssignmentStayWithGroupRoot() throws {
        let persistence = PersistenceController(
            inMemory: true,
            inMemoryConfigurations: ["Private", "Shared"]
        )
        let context = persistence.container.viewContext
        let group = LedgerGroup(context: context)
        context.assign(group, to: persistence.sharedStore)
        group.id = UUID()
        group.name = "共享家庭"
        group.createdAt = Date()
        group.updatedAt = group.createdAt

        let owner = Member(context: context)
        context.assign(owner, to: persistence.sharedStore)
        owner.id = UUID()
        owner.displayName = "小明"
        owner.invitationStatus = InvitationStatus.accepted.rawValue
        owner.joinedAt = Date()
        owner.role = MemberRole.owner.rawValue
        owner.group = group
        CurrentMemberIdentityRepository(persistence: persistence)
            .setCurrentMember(owner, in: group)
        try context.save()

        let book = try BookRepository(persistence: persistence).createBook(
            from: BookDraft(name: "主要帳本"),
            in: group
        )
        let category = try CategoryRepository(persistence: persistence).createCategory(
            from: CategoryDraft(name: "餐飲"),
            in: group,
            parent: nil
        )
        let assignment = try XCTUnwrap(
            CategoryRepository(persistence: persistence).assignment(for: category, in: book)
        )

        XCTAssertEqual(group.objectID.persistentStore, persistence.sharedStore)
        XCTAssertEqual(book.objectID.persistentStore, persistence.sharedStore)
        XCTAssertEqual(category.objectID.persistentStore, persistence.sharedStore)
        XCTAssertEqual(assignment.objectID.persistentStore, persistence.sharedStore)
    }
}

final class CoreDataModelMigrationTests: XCTestCase {
    func testV4ToV5LightweightMappingCanBeInferred() throws {
        let bundle = Bundle(for: PersistenceController.self)
        let modelDirectory = try XCTUnwrap(
            bundle.url(forResource: "SharedLedger", withExtension: "momd")
        )
        let sourceModel = try XCTUnwrap(
            NSManagedObjectModel(
                contentsOf: modelDirectory.appendingPathComponent("SharedLedgerV4.mom")
            )
        )
        let destinationModel = try XCTUnwrap(
            NSManagedObjectModel(
                contentsOf: modelDirectory.appendingPathComponent("SharedLedgerV5.mom")
            )
        )

        XCTAssertNoThrow(
            try NSMappingModel.inferredMappingModel(
                forSourceModel: sourceModel,
                destinationModel: destinationModel
            )
        )
        let currencyAttribute = try XCTUnwrap(
            destinationModel.entitiesByName["LedgerGroup"]?
                .attributesByName["currencyCode"]
        )
        XCTAssertFalse(currencyAttribute.isOptional)
        XCTAssertEqual(currencyAttribute.defaultValue as? String, "TWD")
    }

    func testV3ToV4LightweightMappingCanBeInferred() throws {
        let bundle = Bundle(for: PersistenceController.self)
        let modelDirectory = try XCTUnwrap(
            bundle.url(forResource: "SharedLedger", withExtension: "momd")
        )
        let sourceModel = try XCTUnwrap(
            NSManagedObjectModel(
                contentsOf: modelDirectory.appendingPathComponent("SharedLedgerV3.mom")
            )
        )
        let destinationModel = try XCTUnwrap(
            NSManagedObjectModel(
                contentsOf: modelDirectory.appendingPathComponent("SharedLedgerV4.mom")
            )
        )

        XCTAssertNoThrow(
            try NSMappingModel.inferredMappingModel(
                forSourceModel: sourceModel,
                destinationModel: destinationModel
            )
        )
    }
}
