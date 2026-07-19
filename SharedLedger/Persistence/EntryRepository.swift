import CoreData
import Foundation

@MainActor
struct EntryRepository {
    private let persistence: PersistenceController

    init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    @discardableResult
    func createEntry(
        from draft: TransactionDraft,
        in group: LedgerGroup,
        accounts: [LedgerAccount],
        categories: [LedgerCategory],
        members: [Member]
    ) throws -> LedgerEntry {
        let book = try BookRepository(persistence: persistence).ensureDefaultBook(in: group)
        for account in accounts where account.book == nil && account.group == group {
            account.book = book
        }
        for category in categories where category.book == nil && category.group == group {
            category.book = book
        }
        return try createEntry(
            from: draft,
            in: book,
            accounts: accounts,
            categories: categories,
            members: members
        )
    }

    @discardableResult
    func createEntry(
        from draft: TransactionDraft,
        in book: LedgerBook,
        accounts: [LedgerAccount],
        categories: [LedgerCategory],
        members: [Member]
    ) throws -> LedgerEntry {
        guard draft.canSave, let amount = draft.amountValue else {
            throw EntryError.invalidDraft
        }
        guard let group = book.group else { throw EntryError.missingGroup }

        let bookAccounts = accounts.filter { $0.book == book && $0.archivedAt == nil }
        let bookCategories = categories.filter { $0.book == book && $0.archivedAt == nil }
        let groupMembers = members.filter { $0.group == group }
        let sourceAccount = bookAccounts.first { $0.id == draft.sourceAccountID }
        let destinationAccount = bookAccounts.first { $0.id == draft.destinationAccountID }
        let category = bookCategories.first { $0.id == draft.categoryID }
        let payer = groupMembers.first { $0.id == draft.payerMemberID }
        let participants = groupMembers.filter { member in
            guard let id = member.id else { return false }
            return draft.splitMemberIDs.contains(id)
        }

        switch draft.kind {
        case .transfer:
            guard sourceAccount != nil, destinationAccount != nil else {
                throw EntryError.crossBookReference
            }
        case .income, .expense:
            guard sourceAccount != nil, payer != nil, !participants.isEmpty else {
                throw EntryError.crossBookReference
            }
            if draft.categoryID != nil, category == nil {
                throw EntryError.crossBookReference
            }
        case .balanceAdjustment:
            throw EntryError.invalidDraft
        }

        let context = persistence.container.viewContext
        let now = Date()
        let store = persistence.store(for: book)

        let entry = LedgerEntry(context: context)
        context.assign(entry, to: store)
        entry.id = UUID()
        entry.amount = amount as NSDecimalNumber
        entry.date = draft.date
        entry.kind = draft.kind.rawValue
        entry.note = draft.trimmedNote
        entry.createdAt = now
        entry.updatedAt = now
        entry.group = group
        entry.book = book
        entry.category = category
        entry.sourceAccount = sourceAccount
        entry.destinationAccount = destinationAccount
        entry.payer = payer

        if draft.kind != .transfer {
            for (member, share) in zip(participants, splitAmounts(total: amount, count: participants.count)) {
                let split = EntrySplit(context: context)
                context.assign(split, to: store)
                split.id = UUID()
                split.amount = share as NSDecimalNumber
                split.entry = entry
                split.member = member
            }
        }

        do {
            try context.save()
            return entry
        } catch {
            context.rollback()
            throw error
        }
    }

    private func splitAmounts(total: Decimal, count: Int) -> [Decimal] {
        guard count > 0 else { return [] }
        let base = rounded(total / Decimal(count))
        var amounts = Array(repeating: base, count: count)
        let distributed = base * Decimal(count)
        amounts[amounts.count - 1] += (total - distributed)
        return amounts
    }

    private func rounded(_ value: Decimal, scale: Int = 2) -> Decimal {
        var result = Decimal()
        var mutableValue = value
        NSDecimalRound(&result, &mutableValue, scale, .plain)
        return result
    }

    enum EntryError: LocalizedError {
        case invalidDraft
        case missingGroup
        case crossBookReference

        var errorDescription: String? {
            switch self {
            case .invalidDraft:
                return "請確認金額、帳戶與分攤成員都已填寫。"
            case .missingGroup:
                return "找不到這個帳本所屬的群組。"
            case .crossBookReference:
                return "交易使用的帳號與分類必須屬於同一個帳本。"
            }
        }
    }
}
