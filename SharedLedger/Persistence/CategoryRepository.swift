import CoreData
import Foundation

@MainActor
struct CategoryRepository {
    private let persistence: PersistenceController

    init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    func categories(in group: LedgerGroup, includeArchived: Bool = false) -> [LedgerCategory] {
        let categories = group.categories as? Set<LedgerCategory> ?? []
        return categories
            .filter { includeArchived || $0.archivedAt == nil }
            .sorted(by: categorySort)
    }

    func assignments(in book: LedgerBook, includeDisabled: Bool = false) -> [BookCategoryAssignment] {
        let assignments = book.categoryAssignments as? Set<BookCategoryAssignment> ?? []
        return assignments
            .filter { includeDisabled || $0.isEnabled }
            .sorted {
                if $0.sortOrder == $1.sortOrder {
                    guard let lhs = $0.category else { return false }
                    guard let rhs = $1.category else { return true }
                    return categorySort(lhs, rhs)
                }
                return $0.sortOrder < $1.sortOrder
            }
    }

    func availableCategories(in book: LedgerBook, includeArchived: Bool = false) -> [LedgerCategory] {
        guard let group = book.group else { return [] }
        var seen = Set<NSManagedObjectID>()
        return assignments(in: book)
            .compactMap(\.category)
            .filter { category in
                guard category.group == group,
                      includeArchived || isCategoryAvailable(category, in: book),
                      !seen.contains(category.objectID)
                else { return false }
                seen.insert(category.objectID)
                return true
            }
    }

    func assignment(for category: LedgerCategory, in book: LedgerBook) -> BookCategoryAssignment? {
        let assignments = book.categoryAssignments as? Set<BookCategoryAssignment> ?? []
        return assignments.first { $0.category == category }
    }

    func isCategoryAvailable(_ category: LedgerCategory, in book: LedgerBook) -> Bool {
        guard let group = book.group,
              book.archivedAt == nil
        else { return false }

        var current: LedgerCategory? = category
        var visited = Set<NSManagedObjectID>()
        while let value = current {
            guard visited.insert(value.objectID).inserted,
                  value.group == group,
                  value.archivedAt == nil,
                  assignment(for: value, in: book)?.isEnabled == true
            else { return false }
            current = value.parent
        }
        return true
    }

    func canManageCategories(in group: LedgerGroup) -> Bool {
        let members = group.members as? Set<Member> ?? []
        let currentMembers = members.filter {
            $0.isCurrentUser
                && $0.invitationStatus == InvitationStatus.accepted.rawValue
        }
        guard currentMembers.count == 1,
              let rawRole = currentMembers.first?.role,
              let role = MemberRole(rawValue: rawRole)
        else { return false }
        return role.canManageLedgerSettings
    }

    @discardableResult
    func createCategory(
        from draft: CategoryDraft,
        in group: LedgerGroup,
        parent: LedgerCategory?
    ) throws -> LedgerCategory {
        let activeBooks = BookRepository(persistence: persistence).books(in: group)
        return try createCategory(
            from: draft,
            in: group,
            parent: parent,
            enabledBooks: activeBooks
        )
    }

    @discardableResult
    func createCategory(
        from draft: CategoryDraft,
        in book: LedgerBook,
        parent: LedgerCategory?
    ) throws -> LedgerCategory {
        guard let group = book.group else { throw CategoryError.missingGroup }
        guard book.archivedAt == nil else { throw CategoryError.archivedBook }
        return try createCategory(
            from: draft,
            in: group,
            parent: parent,
            enabledBooks: [book]
        )
    }

    func setCategory(_ category: LedgerCategory, enabled: Bool, in book: LedgerBook) throws {
        guard let group = book.group else { throw CategoryError.missingGroup }
        guard canManageCategories(in: group) else { throw CategoryError.permissionDenied }
        guard book.archivedAt == nil else { throw CategoryError.archivedBook }
        guard category.group == group else { throw CategoryError.crossGroupCategory }
        guard category.archivedAt == nil else { throw CategoryError.archivedCategory }

        let affectedCategories = enabled ? ancestorsIncludingSelf(of: category) : descendantsIncludingSelf(of: category)
        let context = persistence.container.viewContext
        let store = persistence.store(for: book)
        var changed = false

        for affectedCategory in affectedCategories {
            if let existing = assignment(for: affectedCategory, in: book) {
                if existing.isEnabled != enabled {
                    existing.isEnabled = enabled
                    changed = true
                }
            } else if enabled {
                insertAssignment(
                    for: affectedCategory,
                    in: book,
                    sortOrder: Int32(assignments(in: book, includeDisabled: true).count),
                    context: context,
                    store: store
                )
                changed = true
            }
        }

        guard changed else { return }
        group.updatedAt = Date()
        insertAudit(
            action: enabled ? "category.enabled" : "category.disabled",
            summary: "在帳本「\(book.name ?? "未命名帳本")」\(enabled ? "啟用" : "停用")分類「\(category.name ?? "未命名分類")」",
            in: group,
            store: store
        )
        try saveOrRollback()
    }

    func archiveCategory(_ category: LedgerCategory) throws {
        guard let group = category.group else { throw CategoryError.missingGroup }
        guard canManageCategories(in: group) else { throw CategoryError.permissionDenied }
        guard category.archivedAt == nil else { return }
        let children = category.children as? Set<LedgerCategory> ?? []
        guard !children.contains(where: { $0.archivedAt == nil }) else {
            throw CategoryError.hasActiveChildren
        }

        let now = Date()
        category.archivedAt = now
        let assignments = category.bookAssignments as? Set<BookCategoryAssignment> ?? []
        assignments.forEach { $0.isEnabled = false }
        group.updatedAt = now
        insertAudit(
            action: "category.archived",
            summary: "封存群組分類「\(category.name ?? "未命名分類")」",
            in: group,
            store: persistence.store(for: category)
        )
        try saveOrRollback()
    }

    /// Idempotent V4 repair. Legacy categories keep `book` temporarily so
    /// delayed V3 CloudKit records can be mapped to an assignment safely.
    func repairLegacyCategoryAssignments() async throws {
        let context = persistence.container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        try await context.perform {
            let request = NSFetchRequest<LedgerCategory>(entityName: "LedgerCategory")
            let categories = try context.fetch(request)

            for category in categories {
                let legacyBook = category.book
                let categoryGroup = category.group
                let legacyGroup = legacyBook?.group
                if let categoryGroup, let legacyGroup, categoryGroup != legacyGroup {
                    throw CategoryError.inconsistentLegacyGroup
                }
                guard let group = categoryGroup ?? legacyGroup else { continue }
                if category.group == nil {
                    category.group = group
                }

                let assignments = (category.bookAssignments as? Set<BookCategoryAssignment> ?? [])
                    .filter { $0.book?.group == group }
                    .sorted {
                        let lhsDate = $0.createdAt ?? .distantPast
                        let rhsDate = $1.createdAt ?? .distantPast
                        if lhsDate == rhsDate {
                            return ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "")
                        }
                        return lhsDate < rhsDate
                    }

                var canonicalByBook: [NSManagedObjectID: BookCategoryAssignment] = [:]
                for assignment in assignments {
                    guard let book = assignment.book else {
                        context.delete(assignment)
                        continue
                    }
                    assignment.category = category
                    assignment.id = assignment.id ?? UUID()
                    assignment.createdAt = assignment.createdAt ?? Date()
                    if let canonical = canonicalByBook[book.objectID] {
                        canonical.isEnabled = canonical.isEnabled || assignment.isEnabled
                        canonical.sortOrder = min(canonical.sortOrder, assignment.sortOrder)
                        context.delete(assignment)
                    } else {
                        canonicalByBook[book.objectID] = assignment
                    }
                }

                if canonicalByBook.isEmpty {
                    let books = (group.books as? Set<LedgerBook> ?? []).sorted {
                        if $0.sortOrder == $1.sortOrder {
                            return ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
                        }
                        return $0.sortOrder < $1.sortOrder
                    }
                    guard let targetBook = legacyBook
                        ?? books.first(where: { $0.archivedAt == nil && $0.isDefault })
                        ?? books.first(where: { $0.archivedAt == nil })
                        ?? books.first
                    else { continue }
                    guard let store = category.objectID.persistentStore ?? targetBook.objectID.persistentStore else {
                        continue
                    }
                    let assignment = BookCategoryAssignment(context: context)
                    context.assign(assignment, to: store)
                    assignment.id = UUID()
                    assignment.createdAt = Date()
                    assignment.isEnabled = targetBook.archivedAt == nil && category.archivedAt == nil
                    assignment.sortOrder = category.sortOrder
                    assignment.book = targetBook
                    assignment.category = category
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

    private func createCategory(
        from draft: CategoryDraft,
        in group: LedgerGroup,
        parent: LedgerCategory?,
        enabledBooks: [LedgerBook]
    ) throws -> LedgerCategory {
        guard canManageCategories(in: group) else { throw CategoryError.permissionDenied }
        guard draft.canCreate else { throw CategoryError.invalidDraft }
        guard parent == nil || parent?.group == group else { throw CategoryError.crossGroupParent }
        guard parent?.archivedAt == nil else { throw CategoryError.archivedParent }
        guard enabledBooks.allSatisfy({ $0.group == group && $0.archivedAt == nil }) else {
            throw CategoryError.crossGroupBook
        }

        let booksToEnable: [LedgerBook]
        if let parent {
            booksToEnable = enabledBooks.filter {
                isCategoryAvailable(parent, in: $0)
            }
        } else {
            booksToEnable = enabledBooks
        }

        let context = persistence.container.viewContext
        let store = persistence.store(for: group)
        let category = LedgerCategory(context: context)
        context.assign(category, to: store)
        category.id = UUID()
        category.name = draft.trimmedName
        category.sortOrder = Int32(siblingCount(of: parent, in: group))
        category.group = group
        category.parent = parent
        category.book = nil

        for book in booksToEnable {
            insertAssignment(
                for: category,
                in: book,
                sortOrder: Int32(assignments(in: book, includeDisabled: true).count),
                context: context,
                store: store
            )
        }

        let now = Date()
        group.updatedAt = now
        insertAudit(
            action: "category.created",
            summary: "建立群組分類「\(draft.trimmedName)」",
            in: group,
            store: store
        )
        try saveOrRollback()
        return category
    }

    private func insertAssignment(
        for category: LedgerCategory,
        in book: LedgerBook,
        sortOrder: Int32,
        context: NSManagedObjectContext,
        store: NSPersistentStore
    ) {
        let assignment = BookCategoryAssignment(context: context)
        context.assign(assignment, to: store)
        assignment.id = UUID()
        assignment.createdAt = Date()
        assignment.isEnabled = true
        assignment.sortOrder = sortOrder
        assignment.book = book
        assignment.category = category
    }

    private func ancestorsIncludingSelf(of category: LedgerCategory) -> [LedgerCategory] {
        var result: [LedgerCategory] = []
        var current: LedgerCategory? = category
        while let value = current {
            result.insert(value, at: 0)
            current = value.parent
        }
        return result
    }

    private func descendantsIncludingSelf(of category: LedgerCategory) -> [LedgerCategory] {
        let children = (category.children as? Set<LedgerCategory> ?? []).sorted(by: categorySort)
        return [category] + children.flatMap(descendantsIncludingSelf)
    }

    private func siblingCount(of parent: LedgerCategory?, in group: LedgerGroup) -> Int {
        if let parent {
            return (parent.children as? Set<LedgerCategory> ?? []).count
        }
        let categories = group.categories as? Set<LedgerCategory> ?? []
        return categories.filter { $0.parent == nil }.count
    }

    private func categorySort(_ lhs: LedgerCategory, _ rhs: LedgerCategory) -> Bool {
        if lhs.sortOrder == rhs.sortOrder {
            return (lhs.name ?? "") < (rhs.name ?? "")
        }
        return lhs.sortOrder < rhs.sortOrder
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

    enum CategoryError: LocalizedError {
        case invalidDraft
        case missingGroup
        case permissionDenied
        case archivedBook
        case archivedCategory
        case archivedParent
        case crossGroupBook
        case crossGroupCategory
        case crossGroupParent
        case hasActiveChildren
        case inconsistentLegacyGroup

        var errorDescription: String? {
            switch self {
            case .invalidDraft:
                return "請輸入分類名稱。"
            case .missingGroup:
                return "找不到分類或帳本所屬的群組。"
            case .permissionDenied:
                return "只有群組擁有者或管理員可以修改分類設定。"
            case .archivedBook:
                return "已封存的帳本不能修改可用分類。"
            case .archivedCategory:
                return "已封存的分類不能重新啟用。"
            case .archivedParent:
                return "已封存的分類不能新增子分類。"
            case .crossGroupBook:
                return "分類只能啟用於同一群組的帳本。"
            case .crossGroupCategory:
                return "分類與帳本必須屬於同一個群組。"
            case .crossGroupParent:
                return "子分類與父分類必須屬於同一個群組。"
            case .hasActiveChildren:
                return "請先封存所有子分類，再封存這個分類。"
            case .inconsistentLegacyGroup:
                return "既有分類的群組與帳本資料不一致，無法自動遷移。"
            }
        }
    }
}
