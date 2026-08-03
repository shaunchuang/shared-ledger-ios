import CoreData
import Foundation

struct TransactionAuditPayload: Codable, Equatable {
    struct Snapshot: Codable, Equatable {
        struct Payment: Codable, Equatable {
            let memberID: UUID
            let amount: String
        }

        struct Split: Codable, Equatable {
            let memberID: UUID
            let amount: String
            let inputValue: String?
        }

        let kind: String
        let amount: String
        let date: Date?
        let note: String
        let bookID: UUID?
        let categoryID: UUID?
        let sourceAccountID: UUID?
        let destinationAccountID: UUID?
        let splitMode: String
        let payments: [Payment]
        let splits: [Split]
        let isVoided: Bool
    }

    let entryID: UUID
    let message: String
    let before: Snapshot?
    let after: Snapshot?

    func encodedString() -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ string: String?) -> TransactionAuditPayload? {
        guard let string, let data = string.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TransactionAuditPayload.self, from: data)
    }
}

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
        let values = try validatedValues(
            from: draft,
            in: book,
            accounts: accounts,
            categories: categories,
            members: members
        )
        try EffectivePermissionRepository(persistence: persistence)
            .requireTransactionWrite(in: values.group)

        let context = persistence.container.viewContext
        let now = Date()
        let store = persistence.store(for: book)
        let entry = LedgerEntry(context: context)
        context.assign(entry, to: store)
        entry.id = UUID()
        entry.createdAt = now
        apply(values, to: entry, updatedAt: now)
        stampRevision(of: entry, with: values, in: store)

        if let entryID = entry.id {
            insertAudit(
                action: "transaction.created",
                entryID: entryID,
                message: "新增交易",
                before: nil,
                after: snapshot(from: values, isVoided: false),
                group: values.group,
                store: store,
                at: now
            )
        }

        do {
            try context.save()
            return entry
        } catch {
            context.rollback()
            throw error
        }
    }

    @discardableResult
    func updateEntry(
        _ entry: LedgerEntry,
        from draft: TransactionDraft,
        accounts: [LedgerAccount],
        categories: [LedgerCategory],
        members: [Member]
    ) throws -> LedgerEntry {
        guard let book = entry.book, let group = entry.group, book.group == group else {
            throw EntryError.crossScopeReference
        }
        guard let entryID = entry.id else { throw EntryError.missingEntryID }
        guard !isVoided(entry) else { throw EntryError.voidedEntry }

        let before = snapshot(from: entry, isVoided: false)
        let values = try validatedValues(
            from: draft,
            in: book,
            accounts: accounts,
            categories: categories,
            members: members
        )
        guard values.group == group else { throw EntryError.crossScopeReference }
        try EffectivePermissionRepository(persistence: persistence)
            .requireTransactionWrite(in: group)

        let context = persistence.container.viewContext
        let now = Date()
        let store = persistence.store(for: entry)
        apply(values, to: entry, updatedAt: now)
        stampRevision(of: entry, with: values, in: store)
        insertAudit(
            action: "transaction.updated",
            entryID: entryID,
            message: "編輯交易",
            before: before,
            after: snapshot(from: values, isVoided: false),
            group: group,
            store: store,
            at: now
        )

        do {
            try context.save()
            return entry
        } catch {
            context.rollback()
            throw error
        }
    }

    func voidEntry(_ entry: LedgerEntry) throws {
        guard let group = entry.group else { throw EntryError.missingGroup }
        guard let entryID = entry.id else { throw EntryError.missingEntryID }
        guard !isVoided(entry) else { throw EntryError.voidedEntry }
        try EffectivePermissionRepository(persistence: persistence)
            .requireTransactionWrite(in: group)

        let context = persistence.container.viewContext
        let now = Date()
        let store = persistence.store(for: entry)
        let before = snapshot(from: entry, isVoided: false)
        let after = TransactionAuditPayload.Snapshot(
            kind: before.kind,
            amount: before.amount,
            date: before.date,
            note: before.note,
            bookID: before.bookID,
            categoryID: before.categoryID,
            sourceAccountID: before.sourceAccountID,
            destinationAccountID: before.destinationAccountID,
            splitMode: before.splitMode,
            payments: before.payments,
            splits: before.splits,
            isVoided: true
        )

        // Keep the record and all split/payment history, but neutralize its
        // financial movement so existing balance calculations stop counting it.
        // The immutable audit payload above preserves the original amount.
        entry.amount = NSDecimalNumber.zero
        entry.updatedAt = now
        insertAudit(
            action: "transaction.voided",
            entryID: entryID,
            message: "作廢交易",
            before: before,
            after: after,
            group: group,
            store: store,
            at: now
        )

        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func isVoided(_ entry: LedgerEntry) -> Bool {
        guard let entryID = entry.id, let group = entry.group else { return false }
        return voidedEntryIDs(in: group).contains(entryID)
    }

    /// Fetched rather than walked through `group.auditEvents`: the audit log grows
    /// with every ledger change and never shrinks, so traversing the relationship
    /// pulls the whole thing into memory just to keep the void events. The predicate
    /// pushes that filter down to the store, leaving only the rows this actually
    /// decodes. Pending inserts are included, so a void is visible to the same
    /// `save()` that recorded it.
    func voidedEntryIDs(in group: LedgerGroup) -> Set<UUID> {
        let request = NSFetchRequest<AuditEvent>(entityName: "AuditEvent")
        request.predicate = NSPredicate(
            format: "group == %@ AND action == %@",
            group,
            "transaction.voided"
        )
        // Every returned row is decoded below, so hydrate them in one step instead of
        // firing a fault per row.
        request.returnsObjectsAsFaults = false
        guard let audits = try? persistence.container.viewContext.fetch(request) else { return [] }
        return Set(audits.compactMap { TransactionAuditPayload.decode($0.summary)?.entryID })
    }

    func auditPayloads(for entry: LedgerEntry) -> [TransactionAuditPayload] {
        guard let entryID = entry.id, let group = entry.group else { return [] }
        let audits = group.auditEvents as? Set<AuditEvent> ?? []
        return audits
            .filter { ($0.action ?? "").hasPrefix("transaction.") }
            .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
            .compactMap { TransactionAuditPayload.decode($0.summary) }
            .filter { $0.entryID == entryID }
    }

    /// - Parameter writableGroupIDs: see `BookRepository.backfillMissingBookRelationships(in:)`.
    ///   Payments are the source of truth for settlement, so repairing them for a
    ///   group this device cannot write to would make the device settle differently
    ///   from the owner.
    func migrateLegacyPayments(in writableGroupIDs: Set<UUID>) async throws {
        guard !writableGroupIDs.isEmpty else { return }
        let context = persistence.container.viewContext
        let request = NSFetchRequest<LedgerEntry>(entityName: "LedgerEntry")
        request.predicate = NSPredicate(format: "group.id IN %@", Array(writableGroupIDs))
        let entries = try context.fetch(request)
        var hasChanges = false

        for entry in entries {
            let payments = entry.payments as? Set<EntryPayment> ?? []
            guard payments.isEmpty,
                  let payer = entry.payer,
                  entry.kind != EntryKind.transfer.rawValue
            else { continue }

            let payment = EntryPayment(context: context)
            context.assign(payment, to: persistence.store(for: entry))
            payment.id = UUID()
            payment.amount = entry.amount ?? NSDecimalNumber.zero
            payment.sortOrder = 0
            // 補的是這筆交易目前這一版的付款明細，所以跟著交易現在的 revision 走；
            // 從未被 V9 編輯過的舊資料兩邊都是 `nil`，同樣成立。
            payment.entryRevisionID = entry.revisionID
            payment.entry = entry
            payment.member = payer
            if SplitMode(rawValue: entry.splitMode ?? "") == nil {
                entry.splitMode = SplitMode.equal.rawValue
            }
            hasChanges = true
        }

        if hasChanges {
            try context.save()
        }
    }

    /// 被取代的明細要靜置多久才清掉。
    ///
    /// CloudKit 不保證交易與它的明細照著同一個順序匯入，所以剛同步進來的交易可能
    /// 短暫地「交易是新的、明細還是舊的」。這段期間刪掉舊明細等於把還在路上的那一版
    /// 提前處決掉，而且刪除會同步出去，別台裝置也救不回來。交易已經一天沒有變動，
    /// 就可以確定匯入已經塵埃落定。使用者在 iCloud 同步頁按下清除時不受這個限制，
    /// 那是他自己選的當下。
    static let supersededChildRetention: TimeInterval = 24 * 60 * 60

    /// 使用者主動清除單一交易上被取代的明細。
    func discardSupersededChildren(of entry: LedgerEntry) throws {
        guard let group = entry.group else { throw EntryError.missingGroup }
        try EffectivePermissionRepository(persistence: persistence)
            .requireTransactionWrite(in: group)

        let context = persistence.container.viewContext
        let superseded = entry.supersededPayments.map { $0 as NSManagedObject }
            + entry.supersededSplits.map { $0 as NSManagedObject }
        guard !superseded.isEmpty else { return }
        superseded.forEach(context.delete)

        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    /// 背景修復：清掉已經穩定下來的交易上那些落選的明細。
    ///
    /// - Parameter writableGroupIDs: 與其他修復一致，只處理這台裝置真的寫得進去的
    ///   群組；刪除同樣會同步出去，對唯讀群組做這件事只會被 CloudKit 擋下來。
    func discardSupersededChildren(
        in writableGroupIDs: Set<UUID>,
        now: Date = Date()
    ) async throws {
        guard !writableGroupIDs.isEmpty else { return }
        let context = persistence.container.viewContext
        let request = NSFetchRequest<LedgerEntry>(entityName: "LedgerEntry")
        request.predicate = NSPredicate(
            format: "group.id IN %@ AND updatedAt < %@",
            Array(writableGroupIDs),
            now.addingTimeInterval(-Self.supersededChildRetention) as NSDate
        )
        request.relationshipKeyPathsForPrefetching = ["payments", "splits"]
        let entries = try context.fetch(request)

        var hasChanges = false
        for entry in entries {
            let superseded = entry.supersededPayments.map { $0 as NSManagedObject }
                + entry.supersededSplits.map { $0 as NSManagedObject }
            guard !superseded.isEmpty else { continue }
            superseded.forEach(context.delete)
            hasChanges = true
        }

        guard hasChanges else { return }
        do {
            try context.save()
        } catch {
            // 失敗時一定要把待刪除的狀態退掉。留著的話 view context 會帶著一批
            // 刪不掉的物件，之後任何一次儲存都會再撞上同一個錯誤。rollback 會連帶
            // 丟掉 context 裡其他未儲存的變更，但 repository 的每個寫入都在同一次
            // 呼叫裡 save，正常情況下這裡沒有別人的東西可丟。
            context.rollback()
            throw error
        }
    }

    private func validatedValues(
        from draft: TransactionDraft,
        in book: LedgerBook,
        accounts: [LedgerAccount],
        categories: [LedgerCategory],
        members: [Member]
    ) throws -> ValidatedEntryValues {
        guard draft.canSave, let amount = draft.amountValue else {
            throw EntryError.invalidDraft
        }
        guard let group = book.group else { throw EntryError.missingGroup }
        guard book.archivedAt == nil else { throw EntryError.archivedBook }
        let currencyCode = LedgerCurrency.normalizedCode(group.currencyCode)
        guard LedgerCurrency.isValidAmount(amount, currencyCode: currencyCode) else {
            throw EntryError.invalidCurrencyAmount(currencyCode)
        }

        let groupAccounts = accounts.filter { $0.group == group }
        let groupCategories = categories.filter { $0.group == group }
        let groupMembers = members.filter { $0.group == group }
        let sourceAccount = groupAccounts.first { $0.id == draft.sourceAccountID }
        let destinationAccount = groupAccounts.first { $0.id == draft.destinationAccountID }
        let requestedCategory = groupCategories.first { $0.id == draft.categoryID }
        let category = requestedCategory.flatMap {
            CategoryRepository(persistence: persistence).isCategoryAvailable($0, in: book) ? $0 : nil
        }
        let membersByID = Dictionary(uniqueKeysWithValues: groupMembers.compactMap { member in
            member.id.map { ($0, member) }
        })

        if sourceAccount?.archivedAt != nil || destinationAccount?.archivedAt != nil {
            throw EntryError.archivedAccount
        }
        if requestedCategory?.archivedAt != nil {
            throw EntryError.archivedCategory
        }

        let splitAllocations: [SplitAllocation]
        let paymentInputs: [PaymentInput]

        switch draft.kind {
        case .transfer:
            guard sourceAccount != nil, destinationAccount != nil else {
                throw EntryError.crossScopeReference
            }
            splitAllocations = []
            paymentInputs = []
        case .income, .expense:
            guard sourceAccount != nil, !draft.splitMemberIDs.isEmpty else {
                throw EntryError.crossScopeReference
            }
            if draft.categoryID != nil, category == nil {
                throw EntryError.crossScopeReference
            }
            let splitMembers = try resolvedMembers(
                ids: Array(draft.splitMemberIDs),
                membersByID: membersByID
            )
            let splitInputs = try splitMembers.map { member -> SplitInput in
                guard let memberID = member.id else { throw EntryError.crossScopeReference }
                return SplitInput(
                    memberID: memberID,
                    value: draft.splitMode == .equal
                        ? nil
                        : draft.splitValueTexts[memberID]
                            .flatMap(TransactionDraft.decimalValue(from:))
                )
            }
            splitAllocations = try AllocationCalculator.calculateSplits(
                total: amount,
                mode: draft.splitMode,
                inputs: splitInputs,
                currencyCode: currencyCode
            )

            let requestedPayments: [(UUID, Decimal)]
            if draft.paymentDrafts.isEmpty {
                guard let payerID = draft.payerMemberID else { throw EntryError.invalidDraft }
                requestedPayments = [(payerID, amount)]
            } else {
                requestedPayments = try draft.paymentDrafts.map { payment in
                    guard let memberID = payment.memberID,
                          let paymentAmount = payment.amountValue
                    else { throw EntryError.invalidDraft }
                    return (memberID, paymentAmount)
                }
            }
            _ = try resolvedMembers(
                ids: requestedPayments.map(\.0),
                membersByID: membersByID
            )
            paymentInputs = try AllocationCalculator.validatePayments(
                total: amount,
                inputs: requestedPayments.map {
                    PaymentInput(memberID: $0.0, amount: $0.1)
                },
                currencyCode: currencyCode
            )
        case .balanceAdjustment:
            throw EntryError.invalidDraft
        }

        return ValidatedEntryValues(
            kind: draft.kind,
            amount: amount,
            date: draft.date,
            note: draft.trimmedNote,
            group: group,
            book: book,
            category: category,
            sourceAccount: sourceAccount,
            destinationAccount: destinationAccount,
            splitMode: draft.kind == .transfer ? .equal : draft.splitMode,
            splitAllocations: splitAllocations,
            paymentInputs: paymentInputs,
            membersByID: membersByID
        )
    }

    private func apply(_ values: ValidatedEntryValues, to entry: LedgerEntry, updatedAt: Date) {
        entry.amount = values.amount as NSDecimalNumber
        entry.date = values.date
        entry.kind = values.kind.rawValue
        entry.note = values.note
        entry.updatedAt = updatedAt
        entry.group = values.group
        entry.book = values.book
        entry.category = values.category
        entry.sourceAccount = values.sourceAccount
        entry.destinationAccount = values.destinationAccount
        entry.splitMode = values.splitMode.rawValue
        entry.payer = values.paymentInputs.count == 1
            ? values.membersByID[values.paymentInputs[0].memberID]
            : nil
    }

    /// 換掉整組付款與分攤明細，並讓它們帶上這一次寫入的識別碼。
    ///
    /// 交易金額與明細必須一起成立，所以兩者在同一次寫入裡拿到同一個 `revisionID`：
    /// 之後不論 CloudKit 選了哪一台裝置的交易 record，讀取端都能只認那台裝置的明細，
    /// 不會把兩次編輯的付款或分攤加在一起。規則見 `EntryRevision`。
    private func stampRevision(
        of entry: LedgerEntry,
        with values: ValidatedEntryValues,
        in store: NSPersistentStore
    ) {
        let context = persistence.container.viewContext
        let revisionID = UUID()
        entry.revisionID = revisionID

        // 本機看得到的明細全部清掉，包含被其他裝置的編輯取代、還沒清乾淨的那些：
        // 使用者剛剛送出的這一版就是最新的答案。
        for split in entry.splits as? Set<EntrySplit> ?? [] {
            context.delete(split)
        }
        for payment in entry.payments as? Set<EntryPayment> ?? [] {
            context.delete(payment)
        }

        guard values.kind != .transfer else { return }
        for allocation in values.splitAllocations {
            let split = EntrySplit(context: context)
            context.assign(split, to: store)
            split.id = UUID()
            split.amount = allocation.amount as NSDecimalNumber
            split.inputValue = allocation.inputValue.map { NSDecimalNumber(decimal: $0) }
            split.entryRevisionID = revisionID
            split.entry = entry
            split.member = values.membersByID[allocation.memberID]
        }
        for (index, input) in values.paymentInputs.enumerated() {
            let payment = EntryPayment(context: context)
            context.assign(payment, to: store)
            payment.id = UUID()
            payment.amount = input.amount as NSDecimalNumber
            payment.sortOrder = Int32(index)
            payment.entryRevisionID = revisionID
            payment.entry = entry
            payment.member = values.membersByID[input.memberID]
        }
    }

    private func resolvedMembers(
        ids: [UUID],
        membersByID: [UUID: Member]
    ) throws -> [Member] {
        try ids.map { id in
            guard let member = membersByID[id] else {
                throw EntryError.crossScopeReference
            }
            guard member.archivedAt == nil else {
                throw EntryError.archivedMember
            }
            return member
        }
    }

    private func snapshot(from entry: LedgerEntry, isVoided: Bool) -> TransactionAuditPayload.Snapshot {
        // 快照記錄的是「修改前實際生效的內容」，所以和其他讀取端一樣只看目前這一版的
        // 明細；被別的裝置取代掉的那組不屬於使用者看到、也不屬於他改動的那筆交易。
        let payments = entry.livePayments
            .compactMap { payment -> TransactionAuditPayload.Snapshot.Payment? in
                guard let memberID = payment.member?.id else { return nil }
                return .init(
                    memberID: memberID,
                    amount: decimalString(payment.amount as Decimal?)
                )
            }
            .sorted { $0.memberID.uuidString < $1.memberID.uuidString }
        let splits = entry.liveSplits
            .compactMap { split -> TransactionAuditPayload.Snapshot.Split? in
                guard let memberID = split.member?.id else { return nil }
                return .init(
                    memberID: memberID,
                    amount: decimalString(split.amount as Decimal?),
                    inputValue: (split.inputValue as Decimal?).map { decimalString($0) }
                )
            }
            .sorted { $0.memberID.uuidString < $1.memberID.uuidString }

        return TransactionAuditPayload.Snapshot(
            kind: entry.kind ?? EntryKind.expense.rawValue,
            amount: decimalString(entry.amount as Decimal?),
            date: entry.date,
            note: entry.note ?? "",
            bookID: entry.book?.id,
            categoryID: entry.category?.id,
            sourceAccountID: entry.sourceAccount?.id,
            destinationAccountID: entry.destinationAccount?.id,
            splitMode: entry.splitMode ?? SplitMode.equal.rawValue,
            payments: payments,
            splits: splits,
            isVoided: isVoided
        )
    }

    private func snapshot(
        from values: ValidatedEntryValues,
        isVoided: Bool
    ) -> TransactionAuditPayload.Snapshot {
        let payments = values.paymentInputs.map {
            TransactionAuditPayload.Snapshot.Payment(
                memberID: $0.memberID,
                amount: decimalString($0.amount)
            )
        }.sorted { $0.memberID.uuidString < $1.memberID.uuidString }
        let splits = values.splitAllocations.map {
            TransactionAuditPayload.Snapshot.Split(
                memberID: $0.memberID,
                amount: decimalString($0.amount),
                inputValue: $0.inputValue.map { decimalString($0) }
            )
        }.sorted { $0.memberID.uuidString < $1.memberID.uuidString }

        return TransactionAuditPayload.Snapshot(
            kind: values.kind.rawValue,
            amount: decimalString(values.amount),
            date: values.date,
            note: values.note,
            bookID: values.book.id,
            categoryID: values.category?.id,
            sourceAccountID: values.sourceAccount?.id,
            destinationAccountID: values.destinationAccount?.id,
            splitMode: values.splitMode.rawValue,
            payments: payments,
            splits: splits,
            isVoided: isVoided
        )
    }

    private func insertAudit(
        action: String,
        entryID: UUID,
        message: String,
        before: TransactionAuditPayload.Snapshot?,
        after: TransactionAuditPayload.Snapshot?,
        group: LedgerGroup,
        store: NSPersistentStore,
        at date: Date
    ) {
        let context = persistence.container.viewContext
        let audit = AuditEvent(context: context)
        context.assign(audit, to: store)
        audit.id = UUID()
        audit.action = action
        audit.actorDisplayName = currentActorName(in: group)
        audit.createdAt = date
        let payload = TransactionAuditPayload(
            entryID: entryID,
            message: message,
            before: before,
            after: after
        )
        audit.summary = payload.encodedString() ?? message
        audit.group = group
    }

    private func currentActorName(in group: LedgerGroup) -> String {
        CurrentMemberIdentityRepository(persistence: persistence)
            .currentMember(in: group)?
            .displayName
            ?? LedgerStringKey.defaultMemberCurrentUser.string()
    }

    private func decimalString(_ value: Decimal?) -> String {
        guard let value else { return "0" }
        return NSDecimalNumber(decimal: value).stringValue
    }

    private struct ValidatedEntryValues {
        let kind: EntryKind
        let amount: Decimal
        let date: Date
        let note: String
        let group: LedgerGroup
        let book: LedgerBook
        let category: LedgerCategory?
        let sourceAccount: LedgerAccount?
        let destinationAccount: LedgerAccount?
        let splitMode: SplitMode
        let splitAllocations: [SplitAllocation]
        let paymentInputs: [PaymentInput]
        let membersByID: [UUID: Member]
    }

    enum EntryError: LocalizedError {
        case invalidDraft
        case invalidCurrencyAmount(String)
        case missingGroup
        case missingEntryID
        case archivedBook
        case archivedAccount
        case archivedCategory
        case archivedMember
        case crossScopeReference
        case voidedEntry

        var errorDescription: String? {
            switch self {
            case .invalidDraft:
                return LedgerStringKey.errorEntryInvalidDraft.string()
            case .invalidCurrencyAmount(let code):
                return LedgerStringKey.errorCurrencyFractionDigits.string(
                    arguments: [code, Int64(LedgerCurrency.fractionDigits(for: code))]
                )
            case .missingGroup:
                return LedgerStringKey.errorEntryMissingGroup.string()
            case .missingEntryID:
                return LedgerStringKey.errorEntryMissingIdentifier.string()
            case .archivedBook:
                return LedgerStringKey.errorEntryArchivedBook.string()
            case .archivedAccount:
                return LedgerStringKey.errorEntryArchivedAccount.string()
            case .archivedCategory:
                return LedgerStringKey.errorEntryArchivedCategory.string()
            case .archivedMember:
                return LedgerStringKey.errorEntryArchivedMember.string()
            case .crossScopeReference:
                return LedgerStringKey.errorEntryOutOfScope.string()
            case .voidedEntry:
                return LedgerStringKey.errorEntryVoided.string()
            }
        }
    }
}
