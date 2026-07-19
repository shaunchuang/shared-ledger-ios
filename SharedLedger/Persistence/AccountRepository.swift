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
        let store = persistence.store(for: group)

        let account = LedgerAccount(context: context)
        context.assign(account, to: store)
        account.id = UUID()
        account.name = draft.trimmedName
        account.accountType = draft.type.rawValue
        account.openingBalance = openingBalance as NSDecimalNumber
        account.createdAt = Date()
        account.group = group

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
        guard account.archivedAt == nil else { return }

        let context = persistence.container.viewContext
        let now = Date()
        account.archivedAt = now

        let audit = AuditEvent(context: context)
        audit.id = UUID()
        audit.action = "account.archived"
        audit.actorDisplayName = currentActorName(in: group)
        audit.createdAt = now
        audit.summary = "封存帳戶「\(account.name ?? "未命名帳戶")」，歷史交易與餘額調整保持不變"
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
        let transactionBalance = AccountBalanceCalculator.balance(
            openingBalance: (account.openingBalance as Decimal?) ?? 0,
            movements: movements
        )
        return transactionBalance + adjustmentTotal(for: account)
    }

    func totalBalance(for accounts: [LedgerAccount]) -> Decimal {
        guard !accounts.isEmpty else { return 0 }

        let openingBalance = accounts.reduce(Decimal.zero) { partialResult, account in
            partialResult + ((account.openingBalance as Decimal?) ?? 0)
        }
        let adjustmentTotal = accounts.reduce(Decimal.zero) { partialResult, account in
            partialResult + self.adjustmentTotal(for: account)
        }

        let context = persistence.container.viewContext
        let request: NSFetchRequest<LedgerEntry> = LedgerEntry.fetchRequest()
        request.predicate = NSPredicate(
            format: "sourceAccount IN %@ OR destinationAccount IN %@",
            accounts,
            accounts
        )

        do {
            let entries = try context.fetch(request)
            let accountIDs = Set(accounts.map(\.objectID))
            let movementTotal = entries.reduce(Decimal.zero) { partialResult, entry in
                guard let rawKind = entry.kind,
                      let kind = EntryKind(rawValue: rawKind) else {
                    return partialResult
                }
                let amount = (entry.amount as Decimal?) ?? 0
                let isSource = entry.sourceAccount.map { accountIDs.contains($0.objectID) } ?? false
                let isDestination = entry.destinationAccount.map { accountIDs.contains($0.objectID) } ?? false
                guard isSource || isDestination else { return partialResult }
                let movement = AccountBalanceMovement(
                    kind: kind,
                    amount: amount,
                    isSourceAccount: isSource,
                    isDestinationAccount: isDestination
                )
                return partialResult + AccountBalanceCalculator.effect(of: movement)
            }
            return openingBalance + movementTotal + adjustmentTotal
        } catch {
            NSLog("Failed to fetch entries for account total balance: \(error.localizedDescription)")
            return openingBalance + adjustmentTotal
        }
    }

    @discardableResult
    func adjustBalance(
        of account: LedgerAccount,
        to targetBalance: Decimal,
        note: String
    ) throws -> AccountAdjustment? {
        guard account.archivedAt == nil else { throw AccountError.archivedAccount }

        let currentBalance = currentBalance(for: account)
        let difference = targetBalance - currentBalance
        guard difference != 0 else { return nil }
        guard let group = account.group else { throw AccountError.missingGroup }

        let context = persistence.container.viewContext
        let now = Date()
        let store = persistence.store(for: account)
        let adjustment = AccountAdjustment(context: context)
        context.assign(adjustment, to: store)
        adjustment.id = UUID()
        adjustment.amount = difference as NSDecimalNumber
        adjustment.createdAt = now
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        adjustment.note = trimmedNote.isEmpty ? "帳戶餘額調整" : trimmedNote
        adjustment.account = account

        let actorName = currentActorName(in: group)
        let audit = AuditEvent(context: context)
        audit.id = UUID()
        audit.action = "account.balance.adjusted"
        audit.actorDisplayName = actorName
        audit.createdAt = now
        audit.summary = "將帳戶「\(account.name ?? "未命名帳戶")」餘額由 \(currentBalance) 調整為 \(targetBalance)"
        audit.group = group
        context.assign(audit, to: store)

        do {
            try context.save()
            return adjustment
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
        audit.summary = "完成帳戶「\(account.name ?? "未命名帳戶")」對帳，餘額為 \(balance)"
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

    func hasHistory(_ account: LedgerAccount) -> Bool {
        hasTransactions(account) || !adjustments(for: account).isEmpty
    }

    /// Converts the V2 representation (a bookless balance-adjustment entry)
    /// into the V3 account-owned entity. The conversion is atomic and safe to
    /// repeat after CloudKit remote changes.
    func migrateLegacyBalanceAdjustments() async throws {
        let context = persistence.container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        try await context.perform {
            let adjustmentRequest = NSFetchRequest<AccountAdjustment>(entityName: "AccountAdjustment")
            var existingIDs = Set(try context.fetch(adjustmentRequest).compactMap(\.id))

            let entryRequest = NSFetchRequest<LedgerEntry>(entityName: "LedgerEntry")
            entryRequest.predicate = NSPredicate(
                format: "kind == %@",
                EntryKind.balanceAdjustment.rawValue
            )

            for entry in try context.fetch(entryRequest) {
                guard let account = entry.sourceAccount ?? entry.destinationAccount,
                      let store = entry.objectID.persistentStore ?? account.objectID.persistentStore
                else { continue }

                let identifier = entry.id ?? UUID()
                if !existingIDs.contains(identifier) {
                    let adjustment = AccountAdjustment(context: context)
                    context.assign(adjustment, to: store)
                    adjustment.id = identifier
                    adjustment.amount = entry.amount
                    adjustment.createdAt = entry.date ?? entry.createdAt
                    adjustment.note = entry.note ?? "帳戶餘額調整"
                    adjustment.account = account
                    existingIDs.insert(identifier)
                }
                context.delete(entry)
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

    private func adjustments(for account: LedgerAccount) -> Set<AccountAdjustment> {
        account.adjustments as? Set<AccountAdjustment> ?? []
    }

    private func adjustmentTotal(for account: LedgerAccount) -> Decimal {
        adjustments(for: account).reduce(Decimal.zero) { partialResult, adjustment in
            partialResult + ((adjustment.amount as Decimal?) ?? 0)
        }
    }

    private func currentActorName(in group: LedgerGroup) -> String {
        CurrentMemberIdentityRepository(persistence: persistence)
            .currentMember(in: group)?
            .displayName
            ?? "目前使用者"
    }

    enum AccountError: LocalizedError {
        case invalidDraft
        case missingGroup
        case archivedAccount

        var errorDescription: String? {
            switch self {
            case .invalidDraft:
                return "請輸入帳戶名稱與有效的期初餘額。"
            case .missingGroup:
                return "找不到這個帳戶所屬的群組。"
            case .archivedAccount:
                return "已封存的帳戶不能再調整餘額或對帳。"
            }
        }
    }
}
