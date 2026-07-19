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
        guard draft.canCreate, let openingBalance = draft.openingBalanceValue else {
            throw AccountError.invalidDraft
        }

        let context = persistence.container.viewContext

        let account = LedgerAccount(context: context)
        account.id = UUID()
        account.name = draft.trimmedName
        account.accountType = draft.type.rawValue
        account.openingBalance = openingBalance as NSDecimalNumber
        account.createdAt = Date()
        account.group = group
        context.assign(account, to: persistence.store(for: group))

        do {
            try context.save()
            return account
        } catch {
            context.rollback()
            throw error
        }
    }

    func archiveAccount(_ account: LedgerAccount) throws {
        guard let group = account.group else { throw AccountError.missingGroup }

        let context = persistence.container.viewContext
        let now = Date()
        account.archivedAt = now

        let audit = AuditEvent(context: context)
        audit.id = UUID()
        audit.action = "account.archived"
        audit.actorDisplayName = currentActorName(in: group)
        audit.createdAt = now
        audit.summary = "封存帳號「\(account.name ?? "未命名帳號")」，歷史交易保持不變"
        audit.group = group
        context.assign(audit, to: persistence.store(for: account))

        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func currentBalance(for account: LedgerAccount) -> Decimal {
        let sourceEntries = account.sourceEntries as? Set<LedgerEntry> ?? []
        let destinationEntries = account.destinationEntries as? Set<LedgerEntry> ?? []
        let entries = sourceEntries.union(destinationEntries)
        let movements = entries.compactMap { entry -> AccountBalanceMovement? in
            guard let rawKind = entry.kind, let kind = EntryKind(rawValue: rawKind) else {
                return nil
            }
            return AccountBalanceMovement(
                kind: kind,
                amount: (entry.amount as Decimal?) ?? 0,
                isSourceAccount: entry.sourceAccount == account,
                isDestinationAccount: entry.destinationAccount == account
            )
        }
        return AccountBalanceCalculator.balance(
            openingBalance: (account.openingBalance as Decimal?) ?? 0,
            movements: movements
        )
    }

    @discardableResult
    func adjustBalance(
        of account: LedgerAccount,
        to targetBalance: Decimal,
        note: String
    ) throws -> LedgerEntry? {
        guard account.archivedAt == nil else { throw AccountError.archivedAccount }

        let currentBalance = currentBalance(for: account)
        let difference = targetBalance - currentBalance
        guard difference != 0 else { return nil }
        guard let group = account.group else { throw AccountError.missingGroup }

        let context = persistence.container.viewContext
        let now = Date()
        let store = persistence.store(for: account)
        let entry = LedgerEntry(context: context)
        entry.id = UUID()
        entry.amount = difference as NSDecimalNumber
        entry.date = now
        entry.kind = EntryKind.balanceAdjustment.rawValue
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.note = trimmedNote.isEmpty ? "帳號餘額調整" : trimmedNote
        entry.createdAt = now
        entry.updatedAt = now
        entry.group = group
        entry.sourceAccount = account
        context.assign(entry, to: store)

        let actorName = currentActorName(in: group)
        let audit = AuditEvent(context: context)
        audit.id = UUID()
        audit.action = "account.balance.adjusted"
        audit.actorDisplayName = actorName
        audit.createdAt = now
        audit.summary = "將帳號「\(account.name ?? "未命名帳號")」餘額由 \(currentBalance) 調整為 \(targetBalance)"
        audit.group = group
        context.assign(audit, to: store)

        do {
            try context.save()
            return entry
        } catch {
            context.rollback()
            throw error
        }
    }

    func reconcile(_ account: LedgerAccount, at date: Date = Date()) throws {
        guard account.archivedAt == nil else { throw AccountError.archivedAccount }
        guard let group = account.group else { throw AccountError.missingGroup }

        let context = persistence.container.viewContext
        let balance = currentBalance(for: account)
        account.lastReconciledAt = date
        account.lastReconciledBalance = balance as NSDecimalNumber

        let audit = AuditEvent(context: context)
        audit.id = UUID()
        audit.action = "account.reconciled"
        audit.actorDisplayName = currentActorName(in: group)
        audit.createdAt = date
        audit.summary = "完成帳號「\(account.name ?? "未命名帳號")」對帳，餘額為 \(balance)"
        audit.group = group
        context.assign(audit, to: persistence.store(for: account))

        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func hasTransactions(_ account: LedgerAccount) -> Bool {
        let sourceCount = (account.sourceEntries as? Set<LedgerEntry>)?.count ?? 0
        let destinationCount = (account.destinationEntries as? Set<LedgerEntry>)?.count ?? 0
        return sourceCount + destinationCount > 0
    }

    private func currentActorName(in group: LedgerGroup) -> String {
        let members = group.members as? Set<Member> ?? []
        return members.first(where: \.isCurrentUser)?.displayName ?? "目前使用者"
    }

    enum AccountError: LocalizedError {
        case invalidDraft
        case missingGroup
        case archivedAccount

        var errorDescription: String? {
            switch self {
            case .invalidDraft:
                return "請輸入帳號名稱與有效的期初餘額。"
            case .missingGroup:
                return "找不到這個帳號所屬的群組。"
            case .archivedAccount:
                return "已封存的帳號不能再調整餘額或對帳。"
            }
        }
    }
}
