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
        entry.splitMode = draft.kind == .transfer ? SplitMode.equal.rawValue : draft.splitMode.rawValue
        entry.payer = paymentInputs.count == 1
            ? membersByID[paymentInputs[0].memberID]
            : nil

        if draft.kind != .transfer {
            for allocation in splitAllocations {
                let split = EntrySplit(context: context)
                context.assign(split, to: store)
                split.id = UUID()
                split.amount = allocation.amount as NSDecimalNumber
                split.inputValue = allocation.inputValue.map { NSDecimalNumber(decimal: $0) }
                split.entry = entry
                split.member = membersByID[allocation.memberID]
            }
            for (index, input) in paymentInputs.enumerated() {
                let payment = EntryPayment(context: context)
                context.assign(payment, to: store)
                payment.id = UUID()
                payment.amount = input.amount as NSDecimalNumber
                payment.sortOrder = Int32(index)
                payment.entry = entry
                payment.member = membersByID[input.memberID]
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

    func migrateLegacyPayments() async throws {
        let context = persistence.container.viewContext
        let request = NSFetchRequest<LedgerEntry>(entityName: "LedgerEntry")
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

    enum EntryError: LocalizedError {
        case invalidDraft
        case invalidCurrencyAmount(String)
        case missingGroup
        case archivedBook
        case archivedAccount
        case archivedCategory
        case archivedMember
        case crossScopeReference

        var errorDescription: String? {
            switch self {
            case .invalidDraft:
                return "請確認金額、帳戶與分攤成員都已填寫。"
            case .invalidCurrencyAmount(let code):
                let digits = LedgerCurrency.fractionDigits(for: code)
                return "\(code) 金額最多只能有 \(digits) 位小數。"
            case .missingGroup:
                return "找不到這個帳本所屬的群組。"
            case .archivedBook:
                return "已封存的帳本不能新增交易。"
            case .archivedAccount:
                return "已封存的帳戶不能用於新交易。"
            case .archivedCategory:
                return "已封存的分類不能用於新交易。"
            case .archivedMember:
                return "已封存的成員不能加入付款或分攤。"
            case .crossScopeReference:
                return "交易帳戶與分類必須屬於目前群組，且分類需已在目前帳本啟用。"
            }
        }
    }
}
