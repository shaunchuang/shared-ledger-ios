import CoreData
import Foundation

@MainActor
struct WatchLedgerService {
    static let selectionKey = "watch.selectedBookID"
    static let selectionChanged = Notification.Name("WatchLedgerSelectionChanged")
    let persistence: PersistenceController
    var defaults: UserDefaults = .standard

    func context(now: Date = Date()) throws -> WatchLedgerContext {
        // Both application-context pushes and direct refresh replies must only
        // describe committed data. The watch keeps its dated cache while busy.
        guard !persistence.container.viewContext.hasChanges else { throw WatchLedgerError.busy }
        guard let id = defaults.string(forKey: Self.selectionKey).flatMap(UUID.init(uuidString:)),
              let book = try book(id), let group = book.group else {
            return WatchLedgerContext(restriction: LedgerStringKey.watchSetup.string())
        }
        let accounts = (group.accounts as? Set<LedgerAccount> ?? [])
            .filter { $0.archivedAt == nil }
            .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        let members = activeMembers(in: group)
        let payer = CurrentMemberIdentityRepository(persistence: persistence).currentMember(in: group)
        var result = WatchLedgerContext(
            snapshot: try LedgerWidgetSnapshotService(persistence: persistence).snapshot(bookID: id, now: now),
            groupID: group.id,
            accounts: accounts.compactMap { account in account.id.map {
                WatchLedgerChoice(id: $0, name: account.name ?? LedgerStringKey.commonPlaceholderUnnamedAccount.string())
            } },
            categories: CategoryRepository(persistence: persistence).availableCategories(in: book).compactMap { category in
                category.id.map { WatchLedgerChoice(id: $0, name: category.name ?? LedgerStringKey.commonPlaceholderUnnamedCategory.string()) }
            },
            payer: payer.flatMap { member in member.id.map {
                WatchLedgerChoice(id: $0, name: member.displayName ?? LedgerStringKey.commonPlaceholderUnnamedMember.string())
            } },
            members: members.compactMap { member in member.id.map {
                WatchLedgerChoice(id: $0, name: member.displayName ?? LedgerStringKey.commonPlaceholderUnnamedMember.string())
            } },
            restriction: EffectivePermissionRepository(persistence: persistence)
                .transactionWriteRestriction(in: group)?.errorDescription
        )
        if result.restriction == nil && !result.canCreate {
            result.restriction = LedgerStringKey.watchSetup.string()
        }
        return result
    }

    @discardableResult
    func save(_ request: WatchLedgerRequest) throws -> UUID {
        guard request.isValid else { throw WatchLedgerError.invalid }
        // A lost reply must still be acknowledged while the phone has unrelated
        // edits. Use a fresh context so pending inserts/edits cannot impersonate
        // a committed receipt, and never save or roll back the phone's edits.
        if try hasCommittedEntry(request) { return request.id }
        let context = persistence.container.viewContext
        guard !context.hasChanges else { throw WatchLedgerError.busy }
        guard defaults.string(forKey: Self.selectionKey) == request.bookID.uuidString,
              let book = try book(request.bookID), let group = book.group,
              group.id == request.groupID,
              LedgerCurrency.normalizedCode(group.currencyCode) == request.currencyCode,
              CurrentMemberIdentityRepository(persistence: persistence).currentMember(in: group)?.id == request.payerID
        else { throw WatchLedgerError.changed }
        let members = activeMembers(in: group)
        guard Set(members.compactMap(\.id)) == Set(request.memberIDs) else { throw WatchLedgerError.changed }
        let accounts = (group.accounts as? Set<LedgerAccount> ?? []).filter { $0.archivedAt == nil }
        let categories = CategoryRepository(persistence: persistence).availableCategories(in: book)
        try EntryRepository(persistence: persistence).createEntry(
            from: TransactionDraft(
                kind: request.kind,
                amountText: NSDecimalNumber(decimal: request.amount).stringValue,
                date: request.date, categoryID: request.categoryID, sourceAccountID: request.accountID,
                payerMemberID: request.payerID, splitMemberIDs: Set(request.memberIDs)
            ),
            in: book, accounts: Array(accounts), categories: categories, members: members,
            identifier: request.id
        )
        return request.id
    }

    private func hasCommittedEntry(_ request: WatchLedgerRequest) throws -> Bool {
        let committedContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        committedContext.persistentStoreCoordinator = persistence.container.persistentStoreCoordinator
        let fetch = NSFetchRequest<LedgerEntry>(entityName: "LedgerEntry")
        fetch.predicate = NSPredicate(format: "id == %@", request.id as CVarArg)
        fetch.fetchLimit = 1
        guard let entry = try committedContext.fetch(fetch).first else { return false }
        // A later edit or void does not undo the original successful submission.
        guard entry.book?.id == request.bookID, entry.group?.id == request.groupID else {
            throw WatchLedgerError.changed
        }
        return true
    }

    private func book(_ id: UUID) throws -> LedgerBook? {
        let fetch = NSFetchRequest<LedgerBook>(entityName: "LedgerBook")
        fetch.predicate = NSPredicate(format: "id == %@ AND archivedAt == nil", id as CVarArg)
        fetch.fetchLimit = 1
        return try persistence.container.viewContext.fetch(fetch).first
    }

    private func activeMembers(in group: LedgerGroup) -> [Member] {
        (group.members as? Set<Member> ?? []).filter { $0.archivedAt == nil }
            .sorted { ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "") }
    }
}
