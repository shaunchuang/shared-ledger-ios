import CoreData
import Foundation

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

    func defaultBook(in group: LedgerGroup) -> LedgerBook? {
        let activeBooks = books(in: group)
        return activeBooks.first(where: \.isDefault) ?? activeBooks.first
    }

    @discardableResult
    func createBook(from draft: BookDraft, in group: LedgerGroup) throws -> LedgerBook {
        guard draft.canCreate else { throw BookError.invalidDraft }

        let activeBooks = books(in: group)
        let allBooks = books(in: group, includeArchived: true)
        let nextSortOrder = (allBooks.map(\.sortOrder).max() ?? -1) + 1
        let book = insertBook(
            name: draft.trimmedName,
            in: group,
            isDefault: activeBooks.isEmpty,
            sortOrder: nextSortOrder
        )
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

    /// Idempotent post-migration repair for V1 data and CloudKit records that
    /// arrive without a book relationship.
    func backfillMissingBookRelationships() async throws {
        let context = persistence.container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        try await context.perform {
            let request = NSFetchRequest<LedgerGroup>(entityName: "LedgerGroup")
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

                    let members = group.members as? Set<Member> ?? []
                    let audit = AuditEvent(context: context)
                    context.assign(audit, to: store)
                    audit.id = UUID()
                    audit.action = "book.migrated"
                    audit.actorDisplayName = members.first(where: \.isCurrentUser)?.displayName ?? "目前使用者"
                    audit.createdAt = now
                    audit.summary = "為既有群組建立預設帳本「\(BookDraft.defaultName)」"
                    audit.group = group
                }

                let accounts = group.accounts as? Set<LedgerAccount> ?? []
                for account in accounts where account.book == nil {
                    account.book = defaultBook
                }

                let categories = group.categories as? Set<LedgerCategory> ?? []
                for category in categories where category.book == nil {
                    category.book = defaultBook
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

    private func insertAudit(
        action: String,
        summary: String,
        in group: LedgerGroup,
        store: NSPersistentStore
    ) {
        let context = persistence.container.viewContext
        let members = group.members as? Set<Member> ?? []
        let audit = AuditEvent(context: context)
        context.assign(audit, to: store)
        audit.id = UUID()
        audit.action = action
        audit.actorDisplayName = members.first(where: \.isCurrentUser)?.displayName ?? "目前使用者"
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

        var errorDescription: String? {
            switch self {
            case .invalidDraft:
                return "請輸入帳本名稱。"
            case .missingGroup:
                return "找不到這個帳本所屬的群組。"
            case .cannotArchiveOnlyBook:
                return "群組至少需要保留一個使用中的帳本。"
            }
        }
    }
}
