import CoreData
import Foundation

enum BookCategorySource {
    case allGroupCategories
    case copy(LedgerBook)
    case empty
}

@MainActor
struct BookRepository {
    private let persistence: PersistenceController

    init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    func books(in group: LedgerGroup, includeArchived: Bool = false) -> [LedgerBook] {
        let books = group.books as? Set<LedgerBook> ?? []
        return books
            .filter { includeArchived || $0.archivedAt == nil }
            .sorted {
                if $0.sortOrder == $1.sortOrder {
                    return ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
                }
                return $0.sortOrder < $1.sortOrder
            }
    }

    func defaultBook(in group: LedgerGroup) -> LedgerBook? {
        let activeBooks = books(in: group)
        return activeBooks.first(where: \.isDefault) ?? activeBooks.first
    }

    @discardableResult
    func createBook(
        from draft: BookDraft,
        in group: LedgerGroup,
        categorySource: BookCategorySource = .allGroupCategories
    ) throws -> LedgerBook {
        guard draft.canCreate else { throw BookError.invalidDraft }
        try EffectivePermissionRepository(persistence: persistence)
            .requireLedgerSettingsManagement(in: group)

        let activeBooks = books(in: group)
        let allBooks = books(in: group, includeArchived: true)
        let nextSortOrder = (allBooks.map(\.sortOrder).max() ?? -1) + 1
        let book = insertBook(
            name: draft.trimmedName,
            in: group,
            isDefault: activeBooks.isEmpty,
            sortOrder: nextSortOrder
        )
        try insertCategoryAssignments(for: book, from: categorySource, in: group)
        group.updatedAt = Date()
        insertAudit(
            action: "book.created",
            summary: "建立帳本「\(draft.trimmedName)」",
            in: group,
            store: persistence.store(for: group)
        )
        try saveOrRollback()
        return book
    }

    @discardableResult
    func ensureDefaultBook(in group: LedgerGroup) throws -> LedgerBook {
        let activeBooks = books(in: group)
        if let selectedBook = activeBooks.first(where: \.isDefault) ?? activeBooks.first {
            var changed = false
            if !selectedBook.isDefault {
                selectedBook.isDefault = true
                changed = true
            }
            for book in activeBooks where book != selectedBook && book.isDefault {
                book.isDefault = false
                changed = true
            }
            if changed {
                try saveOrRollback()
            }
            return selectedBook
        }

        return try createBook(
            from: BookDraft(name: BookDraft.defaultName),
            in: group
        )
    }

    func archiveBook(_ book: LedgerBook) throws {
        guard let group = book.group else { throw BookError.missingGroup }
        guard book.archivedAt == nil else { return }
        try EffectivePermissionRepository(persistence: persistence)
            .requireLedgerSettingsManagement(in: group)

        let remainingBooks = books(in: group).filter { $0 != book }
        guard let replacement = remainingBooks.first else {
            throw BookError.cannotArchiveOnlyBook
        }

        book.archivedAt = Date()
        book.updatedAt = book.archivedAt
        group.updatedAt = book.archivedAt
        if book.isDefault {
            book.isDefault = false
            replacement.isDefault = true
        }
        insertAudit(
            action: "book.archived",
            summary: "封存帳本「\(book.name ?? "未命名帳本")」",
            in: group,
            store: persistence.store(for: book)
        )
        try saveOrRollback()
    }

    func renameBook(_ book: LedgerBook, using draft: BookDraft) throws {
        guard draft.canCreate else { throw BookError.invalidDraft }
        guard let group = book.group else { throw BookError.missingGroup }
        guard book.archivedAt == nil else { throw BookError.archivedBook }

        let oldName = book.name ?? "未命名帳本"
        guard oldName != draft.trimmedName else { return }
        try EffectivePermissionRepository(persistence: persistence)
            .requireLedgerSettingsManagement(in: group)

        let now = Date()
        book.name = draft.trimmedName
        book.updatedAt = now
        group.updatedAt = now
        insertAudit(
            action: "book.renamed",
            summary: "將帳本「\(oldName)」重新命名為「\(draft.trimmedName)」",
            in: group,
            store: persistence.store(for: book)
        )
        try saveOrRollback()
    }

    func setDefaultBook(_ book: LedgerBook) throws {
        guard let group = book.group else { throw BookError.missingGroup }
        guard book.archivedAt == nil else { throw BookError.archivedBook }
        guard !book.isDefault else { return }
        try EffectivePermissionRepository(persistence: persistence)
            .requireLedgerSettingsManagement(in: group)

        let now = Date()
        for candidate in books(in: group) {
            candidate.isDefault = candidate == book
            if candidate == book {
                candidate.updatedAt = now
            }
        }
        group.updatedAt = now
        insertAudit(
            action: "book.default.changed",
            summary: "將「\(book.name ?? "未命名帳本")」設為預設帳本",
            in: group,
            store: persistence.store(for: book)
        )
        try saveOrRollback()
    }

    func reorderBooks(_ orderedBooks: [LedgerBook], in group: LedgerGroup) throws {
        let activeBooks = books(in: group)
        guard Set(activeBooks.map(\.objectID)) == Set(orderedBooks.map(\.objectID)) else {
            throw BookError.invalidOrder
        }

        let hasChanges = orderedBooks.enumerated().contains { index, book in
            book.sortOrder != Int32(index)
        }
        guard hasChanges else { return }
        try EffectivePermissionRepository(persistence: persistence)
            .requireLedgerSettingsManagement(in: group)

        let now = Date()
        for (index, book) in orderedBooks.enumerated() {
            book.sortOrder = Int32(index)
            book.updatedAt = now
        }
        group.updatedAt = now
        insertAudit(
            action: "book.reordered",
            summary: "調整帳本排序",
            in: group,
            store: persistence.store(for: group)
        )
        try saveOrRollback()
    }

    /// Idempotent post-migration repair for V1 data and CloudKit records that
    /// arrive without a book relationship.
    func backfillMissingBookRelationships() async throws {
        let context = persistence.container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        try await context.perform {
            let request = NSFetchRequest<LedgerGroup>(entityName: "LedgerGroup")
            let groups = try context.fetch(request)

            for group in groups {
                guard let store = group.objectID.persistentStore else { continue }
                let allBooks = (group.books as? Set<LedgerBook> ?? []).sorted {
                    if $0.sortOrder == $1.sortOrder {
                        return ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
                    }
                    return $0.sortOrder < $1.sortOrder
                }
                let activeBooks = allBooks.filter { $0.archivedAt == nil }
                let defaultBook: LedgerBook

                if let existingDefault = activeBooks.first(where: \.isDefault) {
                    defaultBook = existingDefault
                    for book in activeBooks where book != existingDefault && book.isDefault {
                        book.isDefault = false
                    }
                } else if let firstActive = activeBooks.first {
                    firstActive.isDefault = true
                    defaultBook = firstActive
                } else {
                    let now = Date()
                    let book = LedgerBook(context: context)
                    context.assign(book, to: store)
                    book.id = UUID()
                    book.name = BookDraft.defaultName
                    book.createdAt = now
                    book.updatedAt = now
                    book.isDefault = true
                    book.sortOrder = 0
                    book.group = group
                    defaultBook = book

                    let audit = AuditEvent(context: context)
                    context.assign(audit, to: store)
                    audit.id = UUID()
                    audit.action = "book.migrated"
                    audit.actorDisplayName = "資料遷移"
                    audit.createdAt = now
                    audit.summary = "為既有群組建立預設帳本「\(BookDraft.defaultName)」"
                    audit.group = group
                }

                let entries = group.entries as? Set<LedgerEntry> ?? []
                for entry in entries where entry.book == nil {
                    entry.book = defaultBook
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

    private func insertBook(
        name: String,
        in group: LedgerGroup,
        isDefault: Bool,
        sortOrder: Int32
    ) -> LedgerBook {
        let context = persistence.container.viewContext
        let store = persistence.store(for: group)
        let now = Date()
        let book = LedgerBook(context: context)
        context.assign(book, to: store)
        book.id = UUID()
        book.name = name
        book.createdAt = now
        book.updatedAt = now
        book.isDefault = isDefault
        book.sortOrder = sortOrder
        book.group = group
        return book
    }

    private func insertCategoryAssignments(
        for book: LedgerBook,
        from source: BookCategorySource,
        in group: LedgerGroup
    ) throws {
        let categories: [LedgerCategory]
        switch source {
        case .allGroupCategories:
            categories = (group.categories as? Set<LedgerCategory> ?? [])
                .filter { $0.archivedAt == nil }
                .sorted {
                    if $0.sortOrder == $1.sortOrder {
                        return ($0.name ?? "") < ($1.name ?? "")
                    }
                    return $0.sortOrder < $1.sortOrder
                }
        case let .copy(sourceBook):
            guard sourceBook.group == group else { throw BookError.crossGroupCategorySource }
            categories = (sourceBook.categoryAssignments as? Set<BookCategoryAssignment> ?? [])
                .filter { $0.isEnabled && $0.category?.archivedAt == nil }
                .sorted { $0.sortOrder < $1.sortOrder }
                .compactMap(\.category)
        case .empty:
            categories = []
        }

        let context = persistence.container.viewContext
        let store = persistence.store(for: group)
        for (index, category) in categories.enumerated() {
            guard category.group == group else { throw BookError.crossGroupCategorySource }
            let assignment = BookCategoryAssignment(context: context)
            context.assign(assignment, to: store)
            assignment.id = UUID()
            assignment.createdAt = Date()
            assignment.isEnabled = true
            assignment.sortOrder = Int32(index)
            assignment.book = book
            assignment.category = category
        }
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

    enum BookError: LocalizedError {
        case invalidDraft
        case missingGroup
        case cannotArchiveOnlyBook
        case archivedBook
        case invalidOrder
        case crossGroupCategorySource

        var errorDescription: String? {
            switch self {
            case .invalidDraft:
                return "請輸入帳本名稱。"
            case .missingGroup:
                return "找不到這個帳本所屬的群組。"
            case .cannotArchiveOnlyBook:
                return "群組至少需要保留一個使用中的帳本。"
            case .archivedBook:
                return "已封存的帳本不能再修改。"
            case .invalidOrder:
                return "帳本排序資料不完整，請重新整理後再試。"
            case .crossGroupCategorySource:
                return "只能沿用同一群組內帳本的分類設定。"
            }
        }
    }
}

@MainActor
enum BookSelectionStorage {
    static func key(for group: LedgerGroup) -> String {
        let identifier = group.id?.uuidString ?? group.objectID.uriRepresentation().absoluteString
        return "selectedBook.\(identifier)"
    }
}

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
