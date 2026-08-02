import CoreData
import Foundation

@MainActor
struct CategoryRepository {
    /// `BookCategoryAssignment.sortOrder` 的哨兵值：這本帳本沒有自己排過這一層，
    /// 順序沿用群組目錄。
    ///
    /// 沒有這個值的話，assignment 建立當下的順序就會被永久釘住，之後在群組分類管理
    /// 調整的順序永遠不會出現在交易的分類選單裡。
    static let followsGroupOrder: Int32 = -1

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

    /// 這本帳本目前可以選用的分類，依帳本自己的顯示順序由上而下、父分類在子分類之前。
    ///
    /// 順序只在同一層之間比較：帳本排過的那一層照 `BookCategoryAssignment.sortOrder`，
    /// 沒排過的沿用群組目錄，所以同一個分類可以在不同帳本排在不同位置。
    func availableCategories(in book: LedgerBook, includeArchived: Bool = false) -> [LedgerCategory] {
        guard let group = book.group else { return [] }
        var result: [LedgerCategory] = []
        var visited = Set<NSManagedObjectID>()

        func visit(_ parent: LedgerCategory?) {
            for category in siblings(of: parent, in: group, includeArchived: includeArchived, orderedIn: book) {
                let isIncluded = includeArchived
                    ? assignment(for: category, in: book) != nil
                    : isCategoryAvailable(category, in: book)
                guard isIncluded, visited.insert(category.objectID).inserted else { continue }
                result.append(category)
                visit(category)
            }
        }

        visit(nil)
        return result
    }

    /// 群組分類管理畫面看到的同層分類。
    func siblings(of parent: LedgerCategory?, in group: LedgerGroup) -> [LedgerCategory] {
        siblings(of: parent, in: group, includeArchived: false, orderedIn: nil)
    }

    /// 帳本裡已啟用、可以互相調整顯示順序的同層分類。
    ///
    /// 沒有啟用的分類不參與排序：它在這本帳本沒有 assignment 可以記錄位置，硬排也存不
    /// 下來。
    func enabledSiblings(of parent: LedgerCategory?, in book: LedgerBook) -> [LedgerCategory] {
        guard let group = book.group else { return [] }
        return siblings(of: parent, in: group, includeArchived: false, orderedIn: book)
            .filter { assignment(for: $0, in: book)?.isEnabled == true }
    }

    /// 帳本分類設定畫面的同層順序：已啟用的照這本帳本的順序在前，未啟用的照群組順序在後。
    func manageableSiblings(of parent: LedgerCategory?, in book: LedgerBook) -> [LedgerCategory] {
        guard let group = book.group else { return [] }
        let enabled = enabledSiblings(of: parent, in: book)
        let enabledIDs = Set(enabled.map(\.objectID))
        return enabled + siblings(of: parent, in: group).filter { !enabledIDs.contains($0.objectID) }
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

    /// Reflects the same effective permission the mutations enforce, so a read-only
    /// CloudKit participant sees the management UI disabled rather than failing on
    /// save.
    func canManageCategories(in group: LedgerGroup) -> Bool {
        EffectivePermissionRepository(persistence: persistence)
            .permission(in: group)
            .canManageLedgerSettings
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
        try EffectivePermissionRepository(persistence: persistence)
            .requireLedgerSettingsManagement(in: group)
        guard book.archivedAt == nil else { throw CategoryError.archivedBook }
        guard category.group == group else { throw CategoryError.crossGroupCategory }
        guard category.archivedAt == nil else { throw CategoryError.archivedCategory }

        guard applyAvailability(enabled, for: category, in: book) else { return }
        let store = persistence.store(for: book)
        group.updatedAt = Date()
        insertAudit(
            action: enabled ? "category.enabled" : "category.disabled",
            summary: "在帳本「\(book.name ?? "未命名帳本")」\(enabled ? "啟用" : "停用")分類「\(category.name ?? "未命名分類")」",
            in: group,
            store: store
        )
        try saveOrRollback()
    }

    /// 群組層級改名；名稱由整個群組共用，所有帳本會同時看到新名稱。
    func renameCategory(_ category: LedgerCategory, using draft: CategoryDraft) throws {
        guard let group = category.group else { throw CategoryError.missingGroup }
        guard draft.canCreate else { throw CategoryError.invalidDraft }
        guard category.archivedAt == nil else { throw CategoryError.archivedCategory }
        let oldName = category.name ?? "未命名分類"
        guard oldName != draft.trimmedName else { return }
        try EffectivePermissionRepository(persistence: persistence)
            .requireLedgerSettingsManagement(in: group)

        category.name = draft.trimmedName
        group.updatedAt = Date()
        insertAudit(
            action: "category.renamed",
            summary: "將群組分類「\(oldName)」重新命名為「\(draft.trimmedName)」",
            in: group,
            store: persistence.store(for: category)
        )
        try saveOrRollback()
    }

    /// 調整群組分類目錄裡同一層的順序，所有帳本共用這個順序作為預設。
    func reorderCategories(
        _ orderedCategories: [LedgerCategory],
        parent: LedgerCategory?,
        in group: LedgerGroup
    ) throws {
        let currentSiblings = siblings(of: parent, in: group)
        guard Set(currentSiblings.map(\.objectID)) == Set(orderedCategories.map(\.objectID)) else {
            throw CategoryError.invalidOrder
        }
        let hasChanges = orderedCategories.enumerated().contains { index, category in
            category.sortOrder != Int32(index)
        }
        guard hasChanges else { return }
        try EffectivePermissionRepository(persistence: persistence)
            .requireLedgerSettingsManagement(in: group)

        for (index, category) in orderedCategories.enumerated() {
            category.sortOrder = Int32(index)
        }
        group.updatedAt = Date()
        insertAudit(
            action: "category.reordered",
            summary: "調整群組分類「\(parent?.name ?? "最上層")」底下的順序",
            in: group,
            store: persistence.store(for: group)
        )
        try saveOrRollback()
    }

    /// 只調整這本帳本的顯示順序，不動群組目錄，也不影響其他帳本。
    func reorderCategories(
        _ orderedCategories: [LedgerCategory],
        parent: LedgerCategory?,
        in book: LedgerBook
    ) throws {
        guard let group = book.group else { throw CategoryError.missingGroup }
        guard book.archivedAt == nil else { throw CategoryError.archivedBook }
        let currentSiblings = enabledSiblings(of: parent, in: book)
        guard Set(currentSiblings.map(\.objectID)) == Set(orderedCategories.map(\.objectID)) else {
            throw CategoryError.invalidOrder
        }
        let assignments = orderedCategories.map { assignment(for: $0, in: book) }
        guard !assignments.contains(where: { $0 == nil }) else { throw CategoryError.invalidOrder }
        let hasChanges = assignments.enumerated().contains { index, assignment in
            assignment?.sortOrder != Int32(index)
        }
        guard hasChanges else { return }
        try EffectivePermissionRepository(persistence: persistence)
            .requireLedgerSettingsManagement(in: group)

        for (index, assignment) in assignments.enumerated() {
            assignment?.sortOrder = Int32(index)
        }
        group.updatedAt = Date()
        insertAudit(
            action: "category.book.reordered",
            summary: "調整帳本「\(book.name ?? "未命名帳本")」的分類顯示順序",
            in: group,
            store: persistence.store(for: book)
        )
        try saveOrRollback()
    }

    /// 把 `source` 合併進 `target`：歷史交易與子分類都改掛到目標，來源本身封存。
    ///
    /// 來源是封存而不是刪除。交易與分攤都指向分類物件，刪除一個可能還在別台裝置上被
    /// 引用的共享物件，換來的是同步之後指向空分類的歷史；封存則保證任何時間點的歷史
    /// 都還讀得到名稱。
    func mergeCategory(_ source: LedgerCategory, into target: LedgerCategory) throws {
        guard let group = source.group else { throw CategoryError.missingGroup }
        guard target.group == group else { throw CategoryError.crossGroupCategory }
        guard source != target else { throw CategoryError.invalidMergeTarget }
        guard source.archivedAt == nil, target.archivedAt == nil else {
            throw CategoryError.archivedCategory
        }
        // 目標在來源底下時，來源封存後整條路徑都不可用，搬過去的交易會被關進一個
        // 選不到的分類裡。
        guard !isDescendant(target, of: source) else { throw CategoryError.invalidMergeTarget }
        try EffectivePermissionRepository(persistence: persistence)
            .requireLedgerSettingsManagement(in: group)

        let movedChildren = (source.children as? Set<LedgerCategory> ?? []).sorted(by: categorySort)
        let movedEntries = source.entries as? Set<LedgerEntry> ?? []
        var nextSortOrder = Int32(siblings(of: target, in: group).count)
        for child in movedChildren {
            child.parent = target
            child.sortOrder = nextSortOrder
            nextSortOrder += 1
        }
        for entry in movedEntries {
            entry.category = target
        }

        // 來源啟用過的帳本，目標也要跟著啟用，否則搬過去的交易之後會因為分類不可用而
        // 無法再編輯。
        let sourceAssignments = source.bookAssignments as? Set<BookCategoryAssignment> ?? []
        for assignment in sourceAssignments {
            guard assignment.isEnabled,
                  let book = assignment.book,
                  book.archivedAt == nil
            else { continue }
            _ = applyAvailability(true, for: target, in: book)
        }
        sourceAssignments.forEach { $0.isEnabled = false }

        let now = Date()
        let sourceName = source.name ?? "未命名分類"
        source.archivedAt = now
        group.updatedAt = now
        insertAudit(
            action: "category.merged",
            summary: "將分類「\(sourceName)」合併到「\(target.name ?? "未命名分類")」，"
                + "搬移 \(movedEntries.count) 筆交易與 \(movedChildren.count) 個子分類",
            in: group,
            store: persistence.store(for: source)
        )
        try saveOrRollback()
    }

    /// 套用內建分類目錄；已存在的同名分類會沿用，不重複建立。
    @discardableResult
    func installDefaultCategories(
        in group: LedgerGroup,
        catalog: [CategoryNode] = DefaultCategoryCatalog.categories
    ) throws -> Int {
        try EffectivePermissionRepository(persistence: persistence)
            .requireLedgerSettingsManagement(in: group)

        let books = BookRepository(persistence: persistence).books(in: group)
        let created = insertDefaultCategories(in: group, books: books, catalog: catalog)
        guard created > 0 else { return 0 }

        group.updatedAt = Date()
        insertAudit(
            action: "category.defaults.installed",
            summary: "套用內建分類，新增 \(created) 個群組分類",
            in: group,
            store: persistence.store(for: group)
        )
        try saveOrRollback()
        return created
    }

    /// 建立群組時使用：插入內建分類但不存檔，讓呼叫端把整個群組一次寫進去。
    ///
    /// 這裡不檢查權限。呼叫端是「正在建立群組的人」，群組還沒存檔，也還沒有成員身分
    /// 對應可以判斷角色；權限檢查留給對外的 `installDefaultCategories(in:catalog:)`。
    @discardableResult
    func insertDefaultCategories(
        in group: LedgerGroup,
        books: [LedgerBook],
        catalog: [CategoryNode] = DefaultCategoryCatalog.categories
    ) -> Int {
        insertCatalog(catalog, parent: nil, in: group, enabledBooks: books)
    }

    /// 改名、封存或合併之前要告訴使用者的影響範圍。
    func impact(of category: LedgerCategory) -> CategoryImpact {
        let assignments = category.bookAssignments as? Set<BookCategoryAssignment> ?? []
        let children = category.children as? Set<LedgerCategory> ?? []
        return CategoryImpact(
            entryCount: (category.entries as? Set<LedgerEntry> ?? []).count,
            bookCount: assignments.filter { $0.isEnabled && $0.book?.archivedAt == nil }.count,
            childCount: children.filter { $0.archivedAt == nil }.count
        )
    }

    /// 可以作為合併目標的分類：同群組、未封存、不是自己也不在自己底下。
    func mergeTargets(for category: LedgerCategory) -> [LedgerCategory] {
        guard let group = category.group else { return [] }
        return categories(in: group).filter { candidate in
            candidate != category && !isDescendant(candidate, of: category)
        }
    }

    func archiveCategory(_ category: LedgerCategory) throws {
        guard let group = category.group else { throw CategoryError.missingGroup }
        try EffectivePermissionRepository(persistence: persistence)
            .requireLedgerSettingsManagement(in: group)
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
    /// - Parameter writableGroupIDs: see `BookRepository.backfillMissingBookRelationships(in:)`.
    func repairLegacyCategoryAssignments(in writableGroupIDs: Set<UUID>) async throws {
        guard !writableGroupIDs.isEmpty else { return }
        let context = persistence.container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        try await context.perform {
            let request = NSFetchRequest<LedgerCategory>(entityName: "LedgerCategory")
            request.predicate = NSPredicate(
                format: "group.id IN %@ OR book.group.id IN %@",
                Array(writableGroupIDs),
                Array(writableGroupIDs)
            )
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
                    assignment.sortOrder = CategoryRepository.followsGroupOrder
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
        try EffectivePermissionRepository(persistence: persistence)
            .requireLedgerSettingsManagement(in: group)
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

        let category = insertCategory(
            named: draft.trimmedName,
            parent: parent,
            in: group,
            enabledBooks: booksToEnable
        )

        group.updatedAt = Date()
        insertAudit(
            action: "category.created",
            summary: "建立群組分類「\(draft.trimmedName)」",
            in: group,
            store: persistence.store(for: group)
        )
        try saveOrRollback()
        return category
    }

    private func insertCategory(
        named name: String,
        parent: LedgerCategory?,
        in group: LedgerGroup,
        enabledBooks: [LedgerBook]
    ) -> LedgerCategory {
        let context = persistence.container.viewContext
        let store = persistence.store(for: group)
        let category = LedgerCategory(context: context)
        context.assign(category, to: store)
        category.id = UUID()
        category.name = name
        category.sortOrder = Int32(siblingCount(of: parent, in: group))
        category.group = group
        category.parent = parent
        category.book = nil

        for book in enabledBooks {
            insertAssignment(
                for: category,
                in: book,
                sortOrder: Self.followsGroupOrder,
                context: context,
                store: store
            )
        }
        return category
    }

    /// 逐層套用目錄；同名的既有分類直接沿用，重複套用不會長出第二份同名樹。
    private func insertCatalog(
        _ nodes: [CategoryNode],
        parent: LedgerCategory?,
        in group: LedgerGroup,
        enabledBooks: [LedgerBook]
    ) -> Int {
        var created = 0
        var existingByName = Dictionary(
            siblings(of: parent, in: group).map { ($0.name ?? "", $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for node in nodes {
            let category: LedgerCategory
            if let existing = existingByName[node.name] {
                category = existing
            } else {
                category = insertCategory(
                    named: node.name,
                    parent: parent,
                    in: group,
                    enabledBooks: enabledBooks
                )
                existingByName[node.name] = category
                created += 1
            }

            guard !node.children.isEmpty else { continue }
            created += insertCatalog(
                node.children,
                parent: category,
                in: group,
                enabledBooks: enabledBooks.filter { isCategoryAvailable(category, in: $0) }
            )
        }
        return created
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

    /// 啟用時往上補齊祖先，停用時往下帶走子孫；回傳是否真的有東西改變。
    ///
    /// 不負責存檔或稽核，讓「啟用一個分類」與「合併時順手啟用目標」共用同一套串接規則。
    @discardableResult
    private func applyAvailability(
        _ enabled: Bool,
        for category: LedgerCategory,
        in book: LedgerBook
    ) -> Bool {
        let affectedCategories = enabled
            ? ancestorsIncludingSelf(of: category)
            : descendantsIncludingSelf(of: category)
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
                    sortOrder: Self.followsGroupOrder,
                    context: context,
                    store: store
                )
                changed = true
            }
        }
        return changed
    }

    private func siblings(
        of parent: LedgerCategory?,
        in group: LedgerGroup,
        includeArchived: Bool,
        orderedIn book: LedgerBook?
    ) -> [LedgerCategory] {
        let candidates: [LedgerCategory]
        if let parent {
            candidates = Array(parent.children as? Set<LedgerCategory> ?? [])
        } else {
            candidates = (group.categories as? Set<LedgerCategory> ?? [])
                .filter { $0.parent == nil }
        }

        return candidates
            .filter { $0.group == group && (includeArchived || $0.archivedAt == nil) }
            .sorted { lhs, rhs in
                guard let book else { return categorySort(lhs, rhs) }
                let lhsOrder = bookOrder(of: lhs, in: book)
                let rhsOrder = bookOrder(of: rhs, in: book)
                if lhsOrder == rhsOrder { return categorySort(lhs, rhs) }
                return lhsOrder < rhsOrder
            }
    }

    /// 帳本自己排過的分類排在前面並照它的順序；其餘沿用群組順序排在後面，
    /// 所以新啟用的分類會落在這一層的最後，而不是插進使用者排好的位置中間。
    private func bookOrder(of category: LedgerCategory, in book: LedgerBook) -> (Int, Int32) {
        guard let sortOrder = assignment(for: category, in: book)?.sortOrder,
              sortOrder != Self.followsGroupOrder
        else { return (1, category.sortOrder) }
        return (0, sortOrder)
    }

    private func isDescendant(_ candidate: LedgerCategory, of ancestor: LedgerCategory) -> Bool {
        var current = candidate.parent
        var visited = Set<NSManagedObjectID>()
        while let value = current, visited.insert(value.objectID).inserted {
            if value == ancestor { return true }
            current = value.parent
        }
        return false
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
        let audit = AuditEvent(context: context)
        context.assign(audit, to: store)
        audit.id = UUID()
        audit.action = action
        audit.actorDisplayName = CurrentMemberIdentityRepository(persistence: persistence)
            .currentMember(in: group)?
            .displayName
            ?? "目前使用者"
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

    /// 改名、封存或合併之前要說明的影響範圍。
    struct CategoryImpact: Equatable, Sendable {
        let entryCount: Int
        let bookCount: Int
        let childCount: Int

        var isEmpty: Bool { entryCount == 0 && bookCount == 0 && childCount == 0 }

        var summary: String {
            var parts: [String] = []
            if bookCount > 0 { parts.append("\(bookCount) 本帳本使用") }
            if childCount > 0 { parts.append("\(childCount) 個子分類") }
            if entryCount > 0 { parts.append("\(entryCount) 筆歷史交易") }
            guard !parts.isEmpty else { return "目前沒有帳本或交易使用這個分類。" }
            return "影響 " + parts.joined(separator: "、") + "。"
        }
    }

    enum CategoryError: LocalizedError {
        case invalidDraft
        case missingGroup
        case archivedBook
        case archivedCategory
        case archivedParent
        case crossGroupBook
        case crossGroupCategory
        case crossGroupParent
        case hasActiveChildren
        case invalidMergeTarget
        case invalidOrder
        case inconsistentLegacyGroup

        var errorDescription: String? {
            switch self {
            case .invalidDraft:
                return "請輸入分類名稱。"
            case .missingGroup:
                return "找不到分類或帳本所屬的群組。"
            case .archivedBook:
                return "已封存的帳本不能修改可用分類。"
            case .archivedCategory:
                return "已封存的分類不能重新啟用或修改。"
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
            case .invalidMergeTarget:
                return "請選擇另一個不在這個分類底下的分類作為合併目標。"
            case .invalidOrder:
                return "分類排序資料不完整，請重新整理後再試。"
            case .inconsistentLegacyGroup:
                return "既有分類的群組與帳本資料不一致，無法自動遷移。"
            }
        }
    }
}
