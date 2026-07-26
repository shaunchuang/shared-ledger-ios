import CoreData
import Foundation

struct SettlementHistoryItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let bookID: UUID
    let fromMemberID: UUID
    let toMemberID: UUID
    let amount: Decimal
    let note: String
    let recordedAt: Date
    let reversedAt: Date?

    var isReversed: Bool { reversedAt != nil }
}

struct SettlementSnapshot: Equatable, Sendable {
    let result: SettlementResult
    /// Entries in the book that could not be interpreted yet, typically because the
    /// shared store has not finished importing their payment/split/member records.
    let skippedEntryCount: Int

    static let empty = SettlementSnapshot(result: .empty, skippedEntryCount: 0)

    var hasSkippedEntries: Bool { skippedEntryCount > 0 }
}

private struct SettlementAuditPayload: Codable, Equatable {
    let settlementID: UUID
    let bookID: UUID
    let fromMemberID: UUID
    let toMemberID: UUID
    let amount: String
    let note: String

    func encodedString() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ string: String?) -> SettlementAuditPayload? {
        guard let string, let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SettlementAuditPayload.self, from: data)
    }
}

@MainActor
struct SettlementRepository {
    private let persistence: PersistenceController

    init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    func result(in book: LedgerBook) throws -> SettlementResult {
        try snapshot(in: book).result
    }

    /// Builds the settlement view of a book, quarantining entries that cannot be
    /// interpreted yet instead of failing the whole book.
    ///
    /// A shared store syncs `LedgerEntry`, `EntryPayment`, `EntrySplit` and `Member`
    /// records independently, so a freshly imported entry can legitimately be missing
    /// some of its payment/split rows — or the `Member` they point at — for a while.
    /// Those entries are skipped and reported through `skippedEntryCount` so the
    /// remaining balances stay usable while CloudKit catches up.
    func snapshot(in book: LedgerBook) throws -> SettlementSnapshot {
        guard let group = book.group else { throw RepositoryError.missingGroup }
        let currencyCode = LedgerCurrency.normalizedCode(group.currencyCode)
        let voidedEntryIDs = EntryRepository(persistence: persistence).voidedEntryIDs(in: group)
        let entries = book.entries as? Set<LedgerEntry> ?? []

        var transactions: [SettlementTransactionInput] = []
        var skippedEntryCount = 0

        for entry in entries {
            guard entry.id.map({ !voidedEntryIDs.contains($0) }) ?? true,
                  let rawKind = entry.kind,
                  let kind = EntryKind(rawValue: rawKind),
                  kind == .expense || kind == .income else {
                continue
            }

            let storedPayments = entry.payments as? Set<EntryPayment> ?? []
            var payments = storedPayments.compactMap { payment -> PaymentInput? in
                guard let memberID = payment.member?.id else { return nil }
                return PaymentInput(
                    memberID: memberID,
                    amount: (payment.amount as Decimal?) ?? 0
                )
            }
            // A dropped row means the referenced Member has not arrived yet; the
            // remaining rows would silently under-count this entry.
            let hasUnresolvedPayment = payments.count != storedPayments.count

            if payments.isEmpty, !hasUnresolvedPayment, let payerID = entry.payer?.id {
                payments = [
                    PaymentInput(
                        memberID: payerID,
                        amount: (entry.amount as Decimal?) ?? 0
                    )
                ]
            }

            let storedSplits = entry.splits as? Set<EntrySplit> ?? []
            let splits = storedSplits.compactMap { split -> SettlementShareInput? in
                guard let memberID = split.member?.id else { return nil }
                return SettlementShareInput(
                    memberID: memberID,
                    amount: (split.amount as Decimal?) ?? 0
                )
            }
            let hasUnresolvedSplit = splits.count != storedSplits.count

            let transaction = SettlementTransactionInput(
                kind: kind,
                payments: payments,
                splits: splits
            )

            guard !hasUnresolvedPayment, !hasUnresolvedSplit else {
                skippedEntryCount += 1
                continue
            }
            do {
                try SettlementCalculator.validate(transaction, currencyCode: currencyCode)
            } catch {
                skippedEntryCount += 1
                continue
            }
            transactions.append(transaction)
        }

        let activeSettlements = history(in: book)
            .filter { !$0.isReversed }
            .map {
                SettlementRecordInput(
                    id: $0.id,
                    fromMemberID: $0.fromMemberID,
                    toMemberID: $0.toMemberID,
                    amount: $0.amount
                )
            }

        let result = try SettlementCalculator.calculate(
            transactions: transactions,
            settlements: activeSettlements,
            currencyCode: currencyCode
        )
        return SettlementSnapshot(result: result, skippedEntryCount: skippedEntryCount)
    }

    func history(in book: LedgerBook) -> [SettlementHistoryItem] {
        guard let group = book.group, let bookID = book.id else { return [] }
        let audits = (group.auditEvents as? Set<AuditEvent> ?? [])
            .filter { $0.action == "settlement.recorded" || $0.action == "settlement.reversed" }
            .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }

        var recorded: [UUID: (SettlementAuditPayload, Date)] = [:]
        var reversedAt: [UUID: Date] = [:]

        for audit in audits {
            guard let payload = SettlementAuditPayload.decode(audit.summary),
                  payload.bookID == bookID else {
                continue
            }
            let date = audit.createdAt ?? .distantPast
            if audit.action == "settlement.recorded" {
                recorded[payload.settlementID] = (payload, date)
            } else if audit.action == "settlement.reversed" {
                reversedAt[payload.settlementID] = date
            }
        }

        return recorded.values.compactMap { payload, date in
            guard let amount = Decimal(string: payload.amount) else { return nil }
            return SettlementHistoryItem(
                id: payload.settlementID,
                bookID: payload.bookID,
                fromMemberID: payload.fromMemberID,
                toMemberID: payload.toMemberID,
                amount: amount,
                note: payload.note,
                recordedAt: date,
                reversedAt: reversedAt[payload.settlementID]
            )
        }
        .sorted { $0.recordedAt > $1.recordedAt }
    }

    /// Mirrors `requireSettlementWrite` so the UI can hide the action instead of
    /// letting the user reach an error, including when CloudKit has clamped the
    /// App role down to read-only.
    func canRecordSettlements(in book: LedgerBook) -> Bool {
        guard book.archivedAt == nil, let group = book.group else { return false }
        return EffectivePermissionRepository(persistence: persistence)
            .permission(in: group)
            .canEditTransactions
    }

    private func requireSettlementWrite(in book: LedgerBook) throws {
        guard book.archivedAt == nil else { throw RepositoryError.archivedBook }
        guard let group = book.group else { throw RepositoryError.missingGroup }
        try EffectivePermissionRepository(persistence: persistence)
            .requireTransactionWrite(in: group)
    }

    @discardableResult
    func recordSettlement(
        from payer: Member,
        to recipient: Member,
        amount: Decimal,
        note: String,
        in book: LedgerBook
    ) throws -> SettlementHistoryItem {
        guard let group = book.group, let bookID = book.id else { throw RepositoryError.missingGroup }
        try requireSettlementWrite(in: book)
        guard payer.group == group,
              recipient.group == group,
              let payerID = payer.id,
              let recipientID = recipient.id,
              payerID != recipientID else {
            throw RepositoryError.crossGroupMember
        }

        let currencyCode = LedgerCurrency.normalizedCode(group.currencyCode)
        guard amount > 0, LedgerCurrency.isValidAmount(amount, currencyCode: currencyCode) else {
            throw RepositoryError.invalidAmount(currencyCode)
        }

        let current = try result(in: book)
        let payerBalance = current.balances.first { $0.memberID == payerID }?.amount ?? 0
        let recipientBalance = current.balances.first { $0.memberID == recipientID }?.amount ?? 0
        guard payerBalance < 0,
              recipientBalance > 0,
              amount <= min(-payerBalance, recipientBalance) else {
            throw RepositoryError.exceedsOutstandingBalance
        }

        let now = Date()
        let settlementID = UUID()
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = SettlementAuditPayload(
            settlementID: settlementID,
            bookID: bookID,
            fromMemberID: payerID,
            toMemberID: recipientID,
            amount: NSDecimalNumber(decimal: amount).stringValue,
            note: trimmedNote
        )
        try insertAudit(
            action: "settlement.recorded",
            payload: payload,
            group: group,
            book: book,
            at: now
        )

        return SettlementHistoryItem(
            id: settlementID,
            bookID: bookID,
            fromMemberID: payerID,
            toMemberID: recipientID,
            amount: amount,
            note: trimmedNote,
            recordedAt: now,
            reversedAt: nil
        )
    }

    func reverseSettlement(_ settlement: SettlementHistoryItem, in book: LedgerBook) throws {
        guard let group = book.group,
              let bookID = book.id,
              settlement.bookID == bookID else {
            throw RepositoryError.missingGroup
        }
        try requireSettlementWrite(in: book)
        guard let active = history(in: book).first(where: { $0.id == settlement.id }),
              !active.isReversed else {
            throw RepositoryError.alreadyReversed
        }

        let payload = SettlementAuditPayload(
            settlementID: active.id,
            bookID: active.bookID,
            fromMemberID: active.fromMemberID,
            toMemberID: active.toMemberID,
            amount: NSDecimalNumber(decimal: active.amount).stringValue,
            note: active.note
        )
        try insertAudit(
            action: "settlement.reversed",
            payload: payload,
            group: group,
            book: book,
            at: Date()
        )
    }

    private func insertAudit(
        action: String,
        payload: SettlementAuditPayload,
        group: LedgerGroup,
        book: LedgerBook,
        at date: Date
    ) throws {
        let context = persistence.container.viewContext
        let audit = AuditEvent(context: context)
        context.assign(audit, to: persistence.store(for: book))
        audit.id = UUID()
        audit.action = action
        audit.actorDisplayName = CurrentMemberIdentityRepository(persistence: persistence)
            .currentMember(in: group)?
            .displayName
            ?? "目前使用者"
        audit.createdAt = date
        audit.summary = payload.encodedString() ?? "結算紀錄"
        audit.group = group
        book.updatedAt = date
        group.updatedAt = date

        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    enum RepositoryError: LocalizedError {
        case missingGroup
        case archivedBook
        case crossGroupMember
        case invalidAmount(String)
        case exceedsOutstandingBalance
        case alreadyReversed

        var errorDescription: String? {
            switch self {
            case .missingGroup:
                return "找不到這筆結算所屬的帳本或群組。"
            case .archivedBook:
                return "已封存的帳本不能新增結算。"
            case .crossGroupMember:
                return "結算付款人與收款人必須屬於目前群組，且不能是同一人。"
            case .invalidAmount(let code):
                return "結算金額必須大於 0，並符合 \(code) 的最小貨幣單位。"
            case .exceedsOutstandingBalance:
                return "結算金額超過目前應付或應收餘額。"
            case .alreadyReversed:
                return "這筆結算已撤銷，不能重複撤銷。"
            }
        }
    }
}
