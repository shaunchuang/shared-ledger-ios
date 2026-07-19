import CoreData
import Foundation

@MainActor
struct AccountRepository {
    private let persistence: PersistenceController

    init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    @discardableResult
    func createAccount(from draft: AccountDraft, in group: LedgerGroup) throws -> LedgerAccount {
        let book = try BookRepository(persistence: persistence).ensureDefaultBook(in: group)
        return try createAccount(from: draft, in: book)
    }

    @discardableResult
    func createAccount(from draft: AccountDraft, in book: LedgerBook) throws -> LedgerAccount {
        guard draft.canCreate else { throw AccountError.invalidDraft }
        guard let group = book.group else { throw AccountError.missingGroup }

        let context = persistence.container.viewContext
        let store = persistence.store(for: book)

        let account = LedgerAccount(context: context)
        context.assign(account, to: store)
        account.id = UUID()
        account.name = draft.trimmedName
        account.accountType = draft.type.rawValue
        account.createdAt = Date()
        account.group = group
        account.book = book

        do {
            try context.save()
            return account
        } catch {
            context.rollback()
            throw error
        }
    }

    func archiveAccount(_ account: LedgerAccount) throws {
        let context = persistence.container.viewContext
        account.archivedAt = Date()

        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    enum AccountError: LocalizedError {
        case invalidDraft
        case missingGroup

        var errorDescription: String? {
            switch self {
            case .invalidDraft:
                return "請輸入帳號名稱。"
            case .missingGroup:
                return "找不到這個帳本所屬的群組。"
            }
        }
    }
}
