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
        guard draft.canSave, let amount = draft.amountValue else {
            throw EntryError.invalidDraft
        }

        let context = persistence.container.viewContext
        let now = Date()

        let entry = LedgerEntry(context: context)
        entry.id = UUID()
        entry.amount = amount as NSDecimalNumber
        entry.date = draft.date
        entry.kind = draft.kind.rawValue
        entry.note = draft.trimmedNote
        entry.createdAt = now
        entry.updatedAt = now
        entry.group = group
        entry.category = categories.first { $0.id == draft.categoryID }
        entry.sourceAccount = accounts.first { $0.id == draft.sourceAccountID }
        entry.destinationAccount = accounts.first { $0.id == draft.destinationAccountID }
        entry.payer = members.first { $0.id == draft.payerMemberID }
        context.assign(entry, to: persistence.privateStore)

        if draft.kind != .transfer {
            let participants = members.filter { member in
                guard let id = member.id else { return false }
                return draft.splitMemberIDs.contains(id)
            }
            for (member, share) in zip(participants, splitAmounts(total: amount, count: participants.count)) {
                let split = EntrySplit(context: context)
                split.id = UUID()
                split.amount = share as NSDecimalNumber
                split.entry = entry
                split.member = member
                context.assign(split, to: persistence.privateStore)
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

        var errorDescription: String? {
            "請確認金額、帳戶與分攤成員都已填寫。"
        }
    }
}
