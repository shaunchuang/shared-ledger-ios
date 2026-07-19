import CoreData
import Foundation

@MainActor
struct CategoryRepository {
    private let persistence: PersistenceController

    init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    @discardableResult
    func createCategory(from draft: CategoryDraft, in group: LedgerGroup, parent: LedgerCategory?) throws -> LedgerCategory {
        let book = try BookRepository(persistence: persistence).ensureDefaultBook(in: group)
        if let parent, parent.book == nil, parent.group == group {
            parent.book = book
        }
        return try createCategory(from: draft, in: book, parent: parent)
    }

    @discardableResult
    func createCategory(from draft: CategoryDraft, in book: LedgerBook, parent: LedgerCategory?) throws -> LedgerCategory {
        guard draft.canCreate else { throw CategoryError.invalidDraft }
        guard let group = book.group else { throw CategoryError.missingGroup }
        guard parent == nil || parent?.book == book else { throw CategoryError.crossBookParent }

        let context = persistence.container.viewContext
        let store = persistence.store(for: book)

        let category = LedgerCategory(context: context)
        context.assign(category, to: store)
        category.id = UUID()
        category.name = draft.trimmedName
        category.sortOrder = Int32(siblingCount(of: parent, in: book))
        category.group = group
        category.book = book
        category.parent = parent

        do {
            try context.save()
            return category
        } catch {
            context.rollback()
            throw error
        }
    }

    func archiveCategory(_ category: LedgerCategory) throws {
        let context = persistence.container.viewContext
        category.archivedAt = Date()

        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    private func siblingCount(of parent: LedgerCategory?, in book: LedgerBook) -> Int {
        if let parent {
            let children = parent.children as? Set<LedgerCategory> ?? []
            return children.count
        }
        let categories = book.categories as? Set<LedgerCategory> ?? []
        return categories.filter { $0.parent == nil }.count
    }

    enum CategoryError: LocalizedError {
        case invalidDraft
        case missingGroup
        case crossBookParent

        var errorDescription: String? {
            switch self {
            case .invalidDraft:
                return "請輸入分類名稱。"
            case .missingGroup:
                return "找不到這個帳本所屬的群組。"
            case .crossBookParent:
                return "子分類與父分類必須屬於同一個帳本。"
            }
        }
    }
}
