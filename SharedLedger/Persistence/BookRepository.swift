import CoreData
import Foundation

enum BookCategorySource {
    case allGroupCategories
    case copy(LedgerBook)
    case empty
}

@MainActor
struct BookRepository {
    private let persistence: PersistenceController

    init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    func books(in group: LedgerGroup, includeArchived: Bool = false) -> [LedgerBook] {
        let books = group.books as? Set<LedgerBook> ?? []
        return books
            .filter { includeArchived || $0.archivedAt == nil }
            .sorted {
                if $0.sortOrder == $1.sortOrder {
                    return ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
                }
                return $0.sortOrder < $1.sortOrder
            }
    }

    /// 解析一個統計或搜尋範圍實際涵蓋哪些帳本。
    ///
    /// 總覽與交易搜尋都要回答「這些數字包含哪些帳本」，範圍規則只能有一份，否則
    /// 同一個「目前帳本」在兩個畫面可能收斂出不同的帳本集合。已封存帳本一律不納入，
    /// 傳入的 `currentBook` 屬於別的群組時視為沒有選擇，而不是靜靜地跨群組取用。
    func books(
        in group: LedgerGroup,
        scope: ReportBookScope,
        currentBook: LedgerBook?,
        selectedBookIDs: Set<UUID>
    ) -> [LedgerBook] {
        let activeBooks = books(in: group)
        switch scope {
        case .allActiveBooks:
            return activeBooks
        case .currentBook:
            guard let currentBook,
                  currentBook.group == group,
                  currentBook.archivedAt == nil
            else { return [] }
            return [currentBook]
        case .selectedBookIDs:
            return activeBooks.filter { book in
                guard let id = book.id else { return false }
                return selectedBookIDs.contains(id)
            }
        }
    }

    func defaultBook(in group: LedgerGroup) -> LedgerBook? {
        let activeBooks = books(in: group)
        return activeBooks.first(where: \.isDefault) ?? activeBooks.first
    }

    @discardableResult
    func createBook(
        from draft: BookDraft,
        in group: LedgerGroup,
        categorySource: BookCategorySource = .allGroupCategories
    ) throws -> LedgerBook {
        guard draft.canCreate else { throw BookError.invalidDraft }
        try EffectivePermissionRepository(persistence: persistence)
            .requireLedgerSettingsManagement(in: group)

        let activeBooks = books(in: group)
        let allBooks = books(in: group, includeArchived: true)
        let nextSortOrder = (allBooks.map(\.sortOrder).max() ?? -1) + 1
        let book = insertBook(
            name: draft.trimmedName,
            in: group,
            isDefault: activeBooks.isEmpty,
            sortOrder: nextSortOrder
        )
        try insertCategoryAssignments(for: book, from: categorySource, in: group)
        group.updatedAt = Date()
        insertAudit(
            action: "book.created",
            summary: "建立帳本「\(draft.trimmedName)」",
            in: group,
            store: persistence.store(for: group)
        )
        try saveOrRollback()
        return book
    }

    @discardableResult
    func ensureDefaultBook(in group: LedgerGroup) throws -> LedgerBook {
        let activeBooks = books(in: group)
        if let selectedBook = activeBooks.first(where: \.isDefault) ?? activeBooks.first {
            var changed = false
            if !selectedBook.isDefault {
                selectedBook.isDefault = true
                changed = true
            }
            for book in activeBooks where book != selectedBook && book.isDefault {
                book.isDefault = false
                changed = true
            }
            if changed {
                try saveOrRollback()
            }
            return selectedBook
        }

        return try createBook(
            from: BookDraft(name: BookDraft.defaultName),
            in: group
        )
    }

    func archiveBook(_ book: LedgerBook) throws {
        guard let group = book.group else { throw BookError.missingGroup }
        guard book.archivedAt == nil else { return }
        try EffectivePermissionRepository(persistence: persistence)
            .requireLedgerSettingsManagement(in: group)

        let remainingBooks = books(in: group).filter { $0 != book }
        guard let replacement = remainingBooks.first else {
            throw BookError.cannotArchiveOnlyBook
        }

        book.archivedAt = Date()
        book.updatedAt = book.archivedAt
        group.updatedAt = book.archivedAt
        if book.isDefault {
            book.isDefault = false
            replacement.isDefault = true
        }
        insertAudit(
            action: "book.archived",
            summary: "封存帳本「\(book.name ?? "未命名帳本")」",
            in: group,
            store: persistence.store(for: book)
        )
        try saveOrRollback()
    }

    func renameBook(_ book: LedgerBook, using draft: BookDraft) throws {
        guard draft.canCreate else { throw BookError.invalidDraft }
        guard let group = book.group else { throw BookError.missingGroup }
        guard book.archivedAt == nil else { throw BookError.archivedBook }

        let oldName = book.name ?? "未命名帳本"
        guard oldName != draft.trimmedName else { return }
        try EffectivePermissionRepository(persistence: persistence)
            .requireLedgerSettingsManagement(in: group)

        let now = Date()
        book.name = draft.trimmedName
        book.updatedAt = now
        group.updatedAt = now
        insertAudit(
            action: "book.renamed",
            summary: "將帳本「\(oldName)」重新命名為「\(draft.trimmedName)」",
            in: group,
            store: persistence.store(for: book)
        )
        try saveOrRollback()
    }

    func setDefaultBook(_ book: LedgerBook) throws {
        guard let group = book.group else { throw BookError.missingGroup }
        guard book.archivedAt == nil else { throw BookError.archivedBook }
        guard !book.isDefault else { return }
        try EffectivePermissionRepository(persistence: persistence)
            .requireLedgerSettingsManagement(in: group)

        let now = Date()
        for candidate in books(in: group) {
            candidate.isDefault = candidate == book
            if candidate == book {
                candidate.updatedAt = now
            }
        }
        group.updatedAt = now
        insertAudit(
            action: "book.default.changed",
            summary: "將「\(book.name ?? "未命名帳本")」設為預設帳本",
            in: group,
            store: persistence.store(for: book)
        )
        try saveOrRollback()
    }

    func reorderBooks(_ orderedBooks: [LedgerBook], in group: LedgerGroup) throws {
        let activeBooks = books(in: group)
        guard Set(activeBooks.map(\.objectID)) == Set(orderedBooks.map(\.objectID)) else {
            throw BookError.invalidOrder
        }

        let hasChanges = orderedBooks.enumerated().contains { index, book in
            book.sortOrder != Int32(index)
        }
        guard hasChanges else { return }
        try EffectivePermissionRepository(persistence: persistence)
            .requireLedgerSettingsManagement(in: group)

        let now = Date()
        for (index, book) in orderedBooks.enumerated() {
            book.sortOrder = Int32(index)
            book.updatedAt = now
        }
        group.updatedAt = now
        insertAudit(
            action: "book.reordered",
            summary: "調整帳本排序",
            in: group,
            store: persistence.store(for: group)
        )
        try saveOrRollback()
    }

    /// Idempotent post-migration repair for V1 data and CloudKit records that
    /// arrive without a book relationship.
    /// - Parameter writableGroupIDs: groups this device may write to. Repairs create
    ///   synced objects, so a group the current user cannot write to is skipped
    ///   rather than repaired into rows CloudKit will refuse.
    func backfillMissingBookRelationships(in writableGroupIDs: Set<UUID>) async throws {
        guard !writableGroupIDs.isEmpty else { return }
        let context = persistence.container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        try await context.perform {
            let request = NSFetchRequest<LedgerGroup>(entityName: "LedgerGroup")
            request.predicate = NSPredicate(format: "id IN %@", Array(writableGroupIDs))
            let groups = try context.fetch(request)

            for group in groups {
                guard let store = group.objectID.persistentStore else { continue }
                let allBooks = (group.books as? Set<LedgerBook> ?? []).sorted {
                    if $0.sortOrder == $1.sortOrder {
                        return ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
                    }
                    return $0.sortOrder < $1.sortOrder
                }
                let activeBooks = allBooks.filter { $0.archivedAt == nil }
                let defaultBook: LedgerBook

                if let existingDefault = activeBooks.first(where: \.isDefault) {
                    defaultBook = existingDefault
                    for book in activeBooks where book != existingDefault && book.isDefault {
                        book.isDefault = false
                    }
                } else if let firstActive = activeBooks.first {
                    firstActive.isDefault = true
                    defaultBook = firstActive
                } else {
                    let now = Date()
                    let book = LedgerBook(context: context)
                    context.assign(book, to: store)
                    book.id = UUID()
                    book.name = BookDraft.defaultName
                    book.createdAt = now
                    book.updatedAt = now
                    book.isDefault = true
                    book.sortOrder = 0
                    book.group = group
                    defaultBook = book

                    let audit = AuditEvent(context: context)
                    context.assign(audit, to: store)
                    audit.id = UUID()
                    audit.action = "book.migrated"
                    audit.actorDisplayName = LedgerStringKey.defaultActorMigration.string()
                    audit.createdAt = now
                    audit.summary = "為既有群組建立預設帳本「\(BookDraft.defaultName)」"
                    audit.group = group
                }

                let entries = group.entries as? Set<LedgerEntry> ?? []
                for entry in entries where entry.book == nil {
                    entry.book = defaultBook
                }
            }

            if context.hasChanges {
                do {
                    try context.save()
                } catch {
                    context.rollback()
                    throw error
                }
            }
        }
    }

    private func insertBook(
        name: String,
        in group: LedgerGroup,
        isDefault: Bool,
        sortOrder: Int32
    ) -> LedgerBook {
        let context = persistence.container.viewContext
        let store = persistence.store(for: group)
        let now = Date()
        let book = LedgerBook(context: context)
        context.assign(book, to: store)
        book.id = UUID()
        book.name = name
        book.createdAt = now
        book.updatedAt = now
        book.isDefault = isDefault
        book.sortOrder = sortOrder
        book.group = group
        return book
    }

    private func insertCategoryAssignments(
        for book: LedgerBook,
        from source: BookCategorySource,
        in group: LedgerGroup
    ) throws {
        // 每個分類帶著自己的顯示順序：沿用其他帳本時連順序一起帶走，
        // 從群組目錄套用時交給 `CategoryRepository.followsGroupOrder`，
        // 之後在群組調整的順序才會跟著出現在這本新帳本。
        let assignedCategories: [(category: LedgerCategory, sortOrder: Int32)]
        switch source {
        case .allGroupCategories:
            assignedCategories = (group.categories as? Set<LedgerCategory> ?? [])
                .filter { $0.archivedAt == nil }
                .sorted {
                    if $0.sortOrder == $1.sortOrder {
                        return ($0.name ?? "") < ($1.name ?? "")
                    }
                    return $0.sortOrder < $1.sortOrder
                }
                .map { ($0, CategoryRepository.followsGroupOrder) }
        case let .copy(sourceBook):
            guard sourceBook.group == group else { throw BookError.crossGroupCategorySource }
            assignedCategories = (sourceBook.categoryAssignments as? Set<BookCategoryAssignment> ?? [])
                .filter { $0.isEnabled && $0.category?.archivedAt == nil }
                .sorted { $0.sortOrder < $1.sortOrder }
                .compactMap { assignment in
                    assignment.category.map { ($0, assignment.sortOrder) }
                }
        case .empty:
            assignedCategories = []
        }

        let context = persistence.container.viewContext
        let store = persistence.store(for: group)
        for (category, sortOrder) in assignedCategories {
            guard category.group == group else { throw BookError.crossGroupCategorySource }
            let assignment = BookCategoryAssignment(context: context)
            context.assign(assignment, to: store)
            assignment.id = UUID()
            assignment.createdAt = Date()
            assignment.isEnabled = true
            assignment.sortOrder = sortOrder
            assignment.book = book
            assignment.category = category
        }
    }

    private func insertAudit(
        action: String,
        summary: String,
        in group: LedgerGroup,
        store: NSPersistentStore
    ) {
        let context = persistence.container.viewContext
        let audit = AuditEvent(context: context)
        context.assign(audit, to: store)
        audit.id = UUID()
        audit.action = action
        audit.actorDisplayName = CurrentMemberIdentityRepository(persistence: persistence)
            .currentMember(in: group)?
            .displayName
            ?? LedgerStringKey.defaultMemberCurrentUser.string()
        audit.createdAt = Date()
        audit.summary = summary
        audit.group = group
    }

    private func saveOrRollback() throws {
        let context = persistence.container.viewContext
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    enum BookError: LocalizedError {
        case invalidDraft
        case missingGroup
        case cannotArchiveOnlyBook
        case archivedBook
        case invalidOrder
        case crossGroupCategorySource

        var errorDescription: String? {
            switch self {
            case .invalidDraft:
                return LedgerStringKey.errorBookMissingName.string()
            case .missingGroup:
                return LedgerStringKey.errorBookMissingGroup.string()
            case .cannotArchiveOnlyBook:
                return LedgerStringKey.errorBookLastActiveBook.string()
            case .archivedBook:
                return LedgerStringKey.errorBookArchived.string()
            case .invalidOrder:
                return LedgerStringKey.errorBookIncompleteOrder.string()
            case .crossGroupCategorySource:
                return LedgerStringKey.errorBookCrossGroupCopy.string()
            }
        }
    }
}

@MainActor
enum BookSelectionStorage {
    static func key(for group: LedgerGroup) -> String {
        let identifier = group.id?.uuidString ?? group.objectID.uriRepresentation().absoluteString
        return "selectedBook.\(identifier)"
    }
}
