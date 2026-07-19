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
        guard draft.canCreate else { throw CategoryError.invalidDraft }

        let context = persistence.container.viewContext

        let category = LedgerCategory(context: context)
        category.id = UUID()
        category.name = draft.trimmedName
        category.sortOrder = Int32(siblingCount(of: parent, in: group))
        category.group = group
        category.parent = parent
        context.assign(category, to: persistence.store(for: group))

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

    private func siblingCount(of parent: LedgerCategory?, in group: LedgerGroup) -> Int {
        if let parent {
            let children = parent.children as? Set<LedgerCategory> ?? []
            return children.count
        }
        let categories = group.categories as? Set<LedgerCategory> ?? []
        return categories.filter { $0.parent == nil }.count
    }

    enum CategoryError: LocalizedError {
        case invalidDraft

        var errorDescription: String? {
            "請輸入分類名稱。"
        }
    }
}
