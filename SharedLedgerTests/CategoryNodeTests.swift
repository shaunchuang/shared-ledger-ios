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

    func testTWDPrecisionIsPinnedIndependentlyOfSystemData() throws {
        // ISO 4217 records TWD with 2 minor units and NumberFormatter follows the
        // OS's CLDR data, but the app settles TWD in whole dollars. Ledgers sync
        // across devices, so this must not drift with the iOS version.
        XCTAssertEqual(LedgerCurrency.fractionDigits(for: "TWD"), 0)
        XCTAssertTrue(LedgerCurrency.isValidAmount(100, currencyCode: "TWD"))
        XCTAssertFalse(
            LedgerCurrency.isValidAmount(
                try XCTUnwrap(Decimal(string: "33.33")),
                currencyCode: "TWD"
            )
        )
        XCTAssertEqual(
            LedgerCurrency.rounded(
                try XCTUnwrap(Decimal(string: "33.5")),
                currencyCode: "TWD"
            ),
            34
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
            },
            accountStatusProvider: { .available }
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

    func testPrepareShareExplainsMissingICloudAccount() async throws {
        let persistence = PersistenceController(
            inMemory: true,
            accountStatusProvider: { .noAccount }
        )
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(name: "家庭", ownerDisplayName: "小明")
        )

        do {
            _ = try await persistence.prepareShare(for: group)
            XCTFail("Expected the missing iCloud account error.")
        } catch let error as PersistenceController.SharingError {
            guard case .noICloudAccount = error else {
                return XCTFail("Expected noICloudAccount, got \(error)")
            }
            XCTAssertEqual(
                error.localizedDescription,
                "此裝置尚未登入 iCloud，請先在「設定」登入 Apple 帳號後再邀請成員。"
            )
        } catch {
            XCTFail("Expected SharingError, got \(error)")
        }
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

        let writableGroupIDs: Set<UUID> = [try XCTUnwrap(group.id)]
        try await repository.migrateLegacyBalanceAdjustments(in: writableGroupIDs)
        try await repository.migrateLegacyBalanceAdjustments(in: writableGroupIDs)
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
        let writableGroupIDs: Set<UUID> = [try XCTUnwrap(group.id)]
        try await repository.repairLegacyCategoryAssignments(in: writableGroupIDs)
        try await repository.repairLegacyCategoryAssignments(in: writableGroupIDs)
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
        // 這個測試比對的是完整的分類集合，所以從空目錄開始，不受內建分類影響。
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(name: "家庭", ownerDisplayName: "小明", usesDefaultCategories: false)
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
            guard case PermissionError.insufficientRole(.viewer) = error else {
                return XCTFail("Expected insufficientRole(.viewer), got \(error)")
            }
        }
        XCTAssertThrowsError(
            try repository.setCategory(category, enabled: false, in: book)
        ) { error in
            guard case PermissionError.insufficientRole(.viewer) = error else {
                return XCTFail("Expected insufficientRole(.viewer), got \(error)")
            }
        }
        XCTAssertThrowsError(
            try repository.archiveCategory(category)
        ) { error in
            guard case PermissionError.insufficientRole(.viewer) = error else {
                return XCTFail("Expected insufficientRole(.viewer), got \(error)")
            }
        }

        owner.role = MemberRole.owner.rawValue
        XCTAssertTrue(repository.canManageCategories(in: group))
    }


    func testSharedMemberIdentityMappingUsesPrivateStore() throws {
        let persistence = PersistenceController(
            inMemory: true,
            inMemoryConfigurations: ["Private", "Shared"],
            cloudPermissionCache: try makeIsolatedPermissionCache()
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

        // The claim itself does not need CloudKit: the share metadata may still be
        // syncing. Writing does, so an administrator whose participant permission
        // has never been resolved on this device stays fail-closed until it is.
        claimed.role = MemberRole.administrator.rawValue
        XCTAssertNil(claimed.cloudParticipantID)
        XCTAssertFalse(
            CategoryRepository(persistence: persistence)
                .canManageCategories(in: group)
        )
        XCTAssertEqual(
            EffectivePermissionRepository(persistence: persistence)
                .permission(in: group)
                .source,
            .cloudPermissionUnknown
        )
    }

    func testSharedStoreCategoryAndAssignmentStayWithGroupRoot() throws {
        let persistence = PersistenceController(
            inMemory: true,
            inMemoryConfigurations: ["Private", "Shared"],
            cloudPermissionCache: try makeIsolatedPermissionCache()
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

        // This test is about store placement, not permissions. Stand in for a share
        // whose participant permission was already resolved as read/write, otherwise
        // the shared-store writes below are correctly refused as unknown.
        persistence.cloudPermissionCache.store(true, for: group)

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

@MainActor
final class CategoryManagementTests: XCTestCase {
    func testRenameKeepsOneCategoryForEveryBookAndHistory() throws {
        let fixture = try makeFixture()
        let travelBook = try fixture.books.createBook(from: BookDraft(name: "旅行"), in: fixture.group)
        let category = try fixture.categories.createCategory(
            from: CategoryDraft(name: "餐飲"),
            in: fixture.group,
            parent: nil
        )
        let entry = try fixture.addExpense(100, category: category, in: fixture.book)

        try fixture.categories.renameCategory(category, using: CategoryDraft(name: "吃飯"))

        // 分類是群組共用的一份，所以帳本、歷史交易與報表看到的都是同一個新名稱。
        XCTAssertEqual(category.name, "吃飯")
        XCTAssertEqual(entry.category?.name, "吃飯")
        XCTAssertEqual(
            fixture.categories.availableCategories(in: travelBook).first(where: { $0 == category })?.name,
            "吃飯"
        )
        XCTAssertTrue(fixture.auditActions().contains("category.renamed"))
        XCTAssertEqual(fixture.categories.impact(of: category).entryCount, 1)
        XCTAssertEqual(fixture.categories.impact(of: category).bookCount, 2)
    }

    func testRenameRejectsEmptyNameAndArchivedCategory() throws {
        let fixture = try makeFixture()
        let category = try fixture.categories.createCategory(
            from: CategoryDraft(name: "餐飲"),
            in: fixture.group,
            parent: nil
        )

        XCTAssertThrowsError(
            try fixture.categories.renameCategory(category, using: CategoryDraft(name: "   "))
        ) { error in
            guard case CategoryRepository.CategoryError.invalidDraft = error else {
                return XCTFail("Expected invalidDraft, got \(error)")
            }
        }

        try fixture.categories.archiveCategory(category)
        XCTAssertThrowsError(
            try fixture.categories.renameCategory(category, using: CategoryDraft(name: "吃飯"))
        ) { error in
            guard case CategoryRepository.CategoryError.archivedCategory = error else {
                return XCTFail("Expected archivedCategory, got \(error)")
            }
        }
    }

    func testGroupOrderIsSharedWhileBookOrderStaysLocal() throws {
        let fixture = try makeFixture()
        let travelBook = try fixture.books.createBook(from: BookDraft(name: "旅行"), in: fixture.group)
        let food = try fixture.makeCategory("餐飲")
        let transport = try fixture.makeCategory("交通")
        let home = try fixture.makeCategory("居家")

        try fixture.categories.reorderCategories(
            [transport, home, food],
            parent: nil,
            in: fixture.group
        )

        XCTAssertEqual(
            fixture.categories.siblings(of: nil, in: fixture.group),
            [transport, home, food]
        )
        XCTAssertEqual(fixture.categories.availableCategories(in: fixture.book), [transport, home, food])
        XCTAssertEqual(fixture.categories.availableCategories(in: travelBook), [transport, home, food])

        try fixture.categories.reorderCategories(
            [food, transport, home],
            parent: nil,
            in: travelBook
        )

        // 帳本順序只寫在 assignment 上，群組目錄與其他帳本都不受影響。
        XCTAssertEqual(fixture.categories.availableCategories(in: travelBook), [food, transport, home])
        XCTAssertEqual(fixture.categories.availableCategories(in: fixture.book), [transport, home, food])
        XCTAssertEqual(
            fixture.categories.siblings(of: nil, in: fixture.group),
            [transport, home, food]
        )
    }

    func testBookOrderRejectsAnIncompleteSiblingList() throws {
        let fixture = try makeFixture()
        let food = try fixture.makeCategory("餐飲")
        let transport = try fixture.makeCategory("交通")
        try fixture.categories.setCategory(transport, enabled: false, in: fixture.book)

        // 停用的分類在這本帳本沒有位置，混進排序代表畫面與資料已經不同步。
        XCTAssertThrowsError(
            try fixture.categories.reorderCategories(
                [transport, food],
                parent: nil,
                in: fixture.book
            )
        ) { error in
            guard case CategoryRepository.CategoryError.invalidOrder = error else {
                return XCTFail("Expected invalidOrder, got \(error)")
            }
        }
        XCTAssertEqual(fixture.categories.enabledSiblings(of: nil, in: fixture.book), [food])
    }

    func testMergeMovesEntriesAndChildrenThenArchivesTheSource() throws {
        let fixture = try makeFixture()
        let travelBook = try fixture.books.createBook(from: BookDraft(name: "旅行"), in: fixture.group)
        let food = try fixture.makeCategory("餐飲")
        let dining = try fixture.makeCategory("外食")
        let child = try fixture.categories.createCategory(
            from: CategoryDraft(name: "早餐"),
            in: fixture.group,
            parent: dining
        )
        // 目標在旅行帳本被停用，合併之後必須跟著搬過去的交易一起重新啟用。
        try fixture.categories.setCategory(food, enabled: false, in: travelBook)
        let entry = try fixture.addExpense(120, category: dining, in: travelBook)

        try fixture.categories.mergeCategory(dining, into: food)

        XCTAssertEqual(entry.category, food)
        XCTAssertEqual(child.parent, food)
        XCTAssertNotNil(dining.archivedAt)
        XCTAssertFalse(fixture.categories.isCategoryAvailable(dining, in: fixture.book))
        XCTAssertTrue(fixture.categories.isCategoryAvailable(food, in: travelBook))
        XCTAssertTrue(fixture.categories.isCategoryAvailable(child, in: travelBook))
        XCTAssertTrue(fixture.auditActions().contains("category.merged"))

        // 合併只是換一個分類，帳務金額不能因此改變。
        XCTAssertEqual(entry.amount as Decimal?, 120)
        XCTAssertEqual(fixture.categories.impact(of: food).entryCount, 1)
    }

    func testMergeRefusesItselfAndItsOwnDescendants() throws {
        let fixture = try makeFixture()
        let parent = try fixture.makeCategory("交通")
        let child = try fixture.categories.createCategory(
            from: CategoryDraft(name: "捷運"),
            in: fixture.group,
            parent: parent
        )

        XCTAssertThrowsError(try fixture.categories.mergeCategory(parent, into: parent)) { error in
            guard case CategoryRepository.CategoryError.invalidMergeTarget = error else {
                return XCTFail("Expected invalidMergeTarget, got \(error)")
            }
        }
        XCTAssertThrowsError(try fixture.categories.mergeCategory(parent, into: child)) { error in
            guard case CategoryRepository.CategoryError.invalidMergeTarget = error else {
                return XCTFail("Expected invalidMergeTarget, got \(error)")
            }
        }
        XCTAssertFalse(fixture.categories.mergeTargets(for: parent).contains(child))
        XCTAssertNil(parent.archivedAt)
    }

    func testMergeAcrossGroupsIsRejected() throws {
        let fixture = try makeFixture()
        let source = try fixture.makeCategory("餐飲")
        let otherGroup = try GroupRepository(persistence: fixture.persistence).createGroup(
            from: GroupDraft(name: "室友", ownerDisplayName: "小華", usesDefaultCategories: false)
        )
        let foreign = try fixture.categories.createCategory(
            from: CategoryDraft(name: "餐飲"),
            in: otherGroup,
            parent: nil
        )

        XCTAssertThrowsError(try fixture.categories.mergeCategory(source, into: foreign)) { error in
            guard case CategoryRepository.CategoryError.crossGroupCategory = error else {
                return XCTFail("Expected crossGroupCategory, got \(error)")
            }
        }
    }

    func testNewGroupsStartWithTheBuiltInCatalog() throws {
        let persistence = PersistenceController(inMemory: true)
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(name: "家庭", ownerDisplayName: "小明")
        )
        let repository = CategoryRepository(persistence: persistence)
        let book = try XCTUnwrap(BookRepository(persistence: persistence).defaultBook(in: group))

        let roots = repository.siblings(of: nil, in: group)
        XCTAssertEqual(roots.map { $0.name ?? "" }, DefaultCategoryCatalog.categories.map(\.name))
        for node in DefaultCategoryCatalog.categories {
            let category = try XCTUnwrap(roots.first { $0.name == node.name })
            XCTAssertEqual(
                repository.siblings(of: category, in: group).map { $0.name ?? "" },
                node.children.map(\.name)
            )
            XCTAssertTrue(repository.isCategoryAvailable(category, in: book))
        }
    }

    func testDefaultCatalogCanBeSkippedAndReappliedWithoutDuplicates() throws {
        let persistence = PersistenceController(inMemory: true)
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(name: "家庭", ownerDisplayName: "小明", usesDefaultCategories: false)
        )
        let repository = CategoryRepository(persistence: persistence)
        XCTAssertTrue(repository.categories(in: group).isEmpty)

        let created = try repository.installDefaultCategories(in: group)
        let afterFirstRun = repository.categories(in: group).count
        XCTAssertEqual(created, afterFirstRun)

        // 重複套用只會沿用同名分類，不會長出第二份目錄。
        XCTAssertEqual(try repository.installDefaultCategories(in: group), 0)
        XCTAssertEqual(repository.categories(in: group).count, afterFirstRun)
    }

    func testManagementActionsRequireLedgerSettingsPermission() throws {
        let fixture = try makeFixture()
        let source = try fixture.makeCategory("餐飲")
        let target = try fixture.makeCategory("交通")
        let owner = try XCTUnwrap(
            CurrentMemberIdentityRepository(persistence: fixture.persistence)
                .currentMember(in: fixture.group)
        )
        owner.role = MemberRole.viewer.rawValue

        XCTAssertThrowsError(
            try fixture.categories.renameCategory(source, using: CategoryDraft(name: "吃飯"))
        ) { assertViewerRefused($0) }
        XCTAssertThrowsError(
            try fixture.categories.reorderCategories([target, source], parent: nil, in: fixture.group)
        ) { assertViewerRefused($0) }
        XCTAssertThrowsError(
            try fixture.categories.reorderCategories([target, source], parent: nil, in: fixture.book)
        ) { assertViewerRefused($0) }
        XCTAssertThrowsError(
            try fixture.categories.mergeCategory(source, into: target)
        ) { assertViewerRefused($0) }
        XCTAssertThrowsError(
            try fixture.categories.installDefaultCategories(in: fixture.group)
        ) { assertViewerRefused($0) }

        XCTAssertEqual(source.name, "餐飲")
        XCTAssertNil(source.archivedAt)
    }

    private func assertViewerRefused(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case PermissionError.insufficientRole(.viewer) = error else {
            return XCTFail("Expected insufficientRole(.viewer), got \(error)", file: file, line: line)
        }
    }

    /// 這些測試比對的是自己建立的分類，所以群組從空目錄開始，不受內建分類影響。
    private func makeFixture() throws -> Fixture {
        let persistence = PersistenceController(inMemory: true)
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(name: "家庭", ownerDisplayName: "小明", usesDefaultCategories: false)
        )
        let books = BookRepository(persistence: persistence)
        return Fixture(
            persistence: persistence,
            group: group,
            book: try XCTUnwrap(books.defaultBook(in: group)),
            account: try AccountRepository(persistence: persistence).createAccount(
                from: AccountDraft(name: "現金"),
                in: group
            ),
            categories: CategoryRepository(persistence: persistence),
            books: books
        )
    }

    @MainActor
    private struct Fixture {
        let persistence: PersistenceController
        let group: LedgerGroup
        let book: LedgerBook
        let account: LedgerAccount
        let categories: CategoryRepository
        let books: BookRepository

        func makeCategory(_ name: String) throws -> LedgerCategory {
            try categories.createCategory(from: CategoryDraft(name: name), in: group, parent: nil)
        }

        @discardableResult
        func addExpense(
            _ amount: Decimal,
            category: LedgerCategory,
            in book: LedgerBook
        ) throws -> LedgerEntry {
            let members = Array(group.members as? Set<Member> ?? [])
            let ownerID = try XCTUnwrap(members.first?.id)
            return try EntryRepository(persistence: persistence).createEntry(
                from: TransactionDraft(
                    kind: .expense,
                    amountText: "\(amount)",
                    categoryID: category.id,
                    sourceAccountID: account.id,
                    payerMemberID: ownerID,
                    splitMemberIDs: [ownerID]
                ),
                in: book,
                accounts: [account],
                categories: Array(group.categories as? Set<LedgerCategory> ?? []),
                members: members
            )
        }

        func auditActions() -> [String] {
            let events = group.auditEvents as? Set<AuditEvent> ?? []
            return events.compactMap(\.action)
        }
    }
}

final class CoreDataModelMigrationTests: XCTestCase {
    func testV5ToV6LightweightMappingCanBeInferred() throws {
        let sourceModel = try loadVersionedModel(named: "SharedLedgerV5")
        let destinationModel = try loadVersionedModel(named: "SharedLedgerV6")

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

    func testV4ToV5LightweightMappingCanBeInferred() throws {
        let sourceModel = try loadVersionedModel(named: "SharedLedgerV4")
        let destinationModel = try loadVersionedModel(named: "SharedLedgerV5")

        XCTAssertNoThrow(
            try NSMappingModel.inferredMappingModel(
                forSourceModel: sourceModel,
                destinationModel: destinationModel
            )
        )
    }

    func testV3ToV4LightweightMappingCanBeInferred() throws {
        let sourceModel = try loadVersionedModel(named: "SharedLedgerV3")
        let destinationModel = try loadVersionedModel(named: "SharedLedgerV4")

        XCTAssertNoThrow(
            try NSMappingModel.inferredMappingModel(
                forSourceModel: sourceModel,
                destinationModel: destinationModel
            )
        )
    }
}

@MainActor
final class CategorySheetRouteTests: XCTestCase {
    /// 三張表單原本各自掛一個 `.sheet`，後面的會蓋掉前面的，「新增子分類」因此按了
    /// 沒反應。改成單一路由之後，每個入口都要有自己的 identity，`.sheet(item:)` 才會
    /// 換成對的那一張表單。
    func testEveryEntryPointHasItsOwnIdentity() throws {
        let fixture = try makeFixture()
        let food = try fixture.makeCategory("餐飲")
        let travel = try fixture.makeCategory("旅行")

        let ids = [
            CategorySheetRoute.newCategory(parent: nil).id,
            CategorySheetRoute.newCategory(parent: food).id,
            CategorySheetRoute.newCategory(parent: travel).id,
            CategorySheetRoute.rename(food).id,
            CategorySheetRoute.merge(food).id
        ]

        XCTAssertEqual(Set(ids).count, ids.count)
    }

    /// 同一個入口重開時 identity 必須一樣，否則 `.sheet(item:)` 會把還開著的表單
    /// 換掉。
    func testTheSameEntryPointKeepsItsIdentity() throws {
        let fixture = try makeFixture()
        let food = try fixture.makeCategory("餐飲")

        XCTAssertEqual(
            CategorySheetRoute.newCategory(parent: food).id,
            CategorySheetRoute.newCategory(parent: food).id
        )
        XCTAssertEqual(
            CategorySheetRoute.newCategory(parent: nil).id,
            CategorySheetRoute.newCategory(parent: nil).id
        )
    }

    /// popover 裡選到的動作要先關閉 popover，等內容消失後只能取出並執行一次。
    func testCategoryRowActionWaitsForPopoverDismissalAndIsConsumedOnce() {
        let coordinator = CategoryRowActionCoordinator()

        coordinator.present()
        XCTAssertTrue(coordinator.isPresented)
        XCTAssertNil(coordinator.pendingAction)

        coordinator.select(.addChild)
        XCTAssertFalse(coordinator.isPresented)
        XCTAssertEqual(coordinator.pendingAction, .addChild)
        XCTAssertEqual(coordinator.takePendingAction(), .addChild)
        XCTAssertNil(coordinator.takePendingAction())
    }

    func testCategoryRowActionCoversEveryPopoverCommand() {
        let actions: [CategoryRowAction] = [
            .rename,
            .addChild,
            .move(-1),
            .move(1),
            .merge,
            .archive
        ]

        XCTAssertEqual(Set(actions).count, actions.count)
    }

    /// 父分類跟著路由一起走，所以先開過「新增最上層分類」再開「新增子分類」時，
    /// 表單拿到的是這次選到的父分類，而不是上一次留在另一個 `@State` 裡的值。
    func testTheChildEntryPointCarriesTheParentItWasOpenedWith() throws {
        let fixture = try makeFixture()
        let food = try fixture.makeCategory("餐飲")

        // 先開一次「新增最上層分類」，再從「餐飲」的選單開「新增子分類」。
        var route: CategorySheetRoute?
        route = .newCategory(parent: nil)
        XCTAssertNotEqual(route?.id, CategorySheetRoute.newCategory(parent: food).id)

        route = .newCategory(parent: food)
        let presentedRoute = try XCTUnwrap(route)
        guard case let .newCategory(parent) = presentedRoute else {
            return XCTFail("Expected a newCategory route")
        }

        let child = try fixture.categories.createCategory(
            from: CategoryDraft(name: "早餐"),
            in: fixture.group,
            parent: parent
        )
        XCTAssertEqual(child.parent, food)
        XCTAssertEqual(fixture.categories.siblings(of: food, in: fixture.group), [child])
    }

    private func makeFixture() throws -> Fixture {
        let persistence = PersistenceController(inMemory: true)
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(name: "家庭", ownerDisplayName: "小明", usesDefaultCategories: false)
        )
        return Fixture(group: group, categories: CategoryRepository(persistence: persistence))
    }

    @MainActor
    private struct Fixture {
        let group: LedgerGroup
        let categories: CategoryRepository

        func makeCategory(_ name: String) throws -> LedgerCategory {
            try categories.createCategory(from: CategoryDraft(name: name), in: group, parent: nil)
        }
    }
}
