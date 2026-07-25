import CoreData
import Foundation

struct TransactionDraft: Equatable, Sendable {
    var kind: EntryKind = .expense
    var amountText = ""
    var date = Date()
    var note = ""
    var categoryID: UUID?
    var sourceAccountID: UUID?
    var destinationAccountID: UUID?
    var payerMemberID: UUID?
    var splitMemberIDs: Set<UUID> = []
    var splitMode: SplitMode = .equal
    var splitValueTexts: [UUID: String] = [:]
    var paymentDrafts: [TransactionPaymentDraft] = []

    init(
        kind: EntryKind = .expense,
        amountText: String = "",
        date: Date = Date(),
        note: String = "",
        categoryID: UUID? = nil,
        sourceAccountID: UUID? = nil,
        destinationAccountID: UUID? = nil,
        payerMemberID: UUID? = nil,
        splitMemberIDs: Set<UUID> = [],
        splitMode: SplitMode = .equal,
        splitValueTexts: [UUID: String] = [:],
        paymentDrafts: [TransactionPaymentDraft] = []
    ) {
        self.kind = kind
        self.amountText = amountText
        self.date = date
        self.note = note
        self.categoryID = categoryID
        self.sourceAccountID = sourceAccountID
        self.destinationAccountID = destinationAccountID
        self.payerMemberID = payerMemberID
        self.splitMemberIDs = splitMemberIDs
        self.splitMode = splitMode
        self.splitValueTexts = splitValueTexts
        self.paymentDrafts = paymentDrafts
    }

    @MainActor
    init(entry: LedgerEntry) {
        kind = EntryKind(rawValue: entry.kind ?? "") ?? .expense
        amountText = Self.decimalString(entry.amount as Decimal?)
        date = entry.date ?? Date()
        note = entry.note ?? ""
        categoryID = entry.category?.id
        sourceAccountID = entry.sourceAccount?.id
        destinationAccountID = entry.destinationAccount?.id
        splitMode = SplitMode(rawValue: entry.splitMode ?? "") ?? .equal

        let splits = (entry.splits as? Set<EntrySplit> ?? [])
            .compactMap { split -> (UUID, EntrySplit)? in
                guard let memberID = split.member?.id else { return nil }
                return (memberID, split)
            }
            .sorted { $0.0.uuidString < $1.0.uuidString }
        splitMemberIDs = Set(splits.map(\.0))
        splitValueTexts = Dictionary(uniqueKeysWithValues: splits.compactMap { memberID, split in
            guard splitMode != .equal, let input = split.inputValue as Decimal? else { return nil }
            return (memberID, Self.decimalString(input))
        })

        let payments = (entry.payments as? Set<EntryPayment> ?? [])
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                return (lhs.member?.id?.uuidString ?? "") < (rhs.member?.id?.uuidString ?? "")
            }
        paymentDrafts = payments.compactMap { payment in
            guard let memberID = payment.member?.id else { return nil }
            return TransactionPaymentDraft(
                memberID: memberID,
                amountText: Self.decimalString(payment.amount as Decimal?)
            )
        }

        if paymentDrafts.isEmpty, let payerID = entry.payer?.id {
            payerMemberID = payerID
            paymentDrafts = [
                TransactionPaymentDraft(memberID: payerID, amountText: amountText)
            ]
        } else {
            payerMemberID = paymentDrafts.count == 1 ? paymentDrafts.first?.memberID : nil
        }
    }

    var amountValue: Decimal? {
        Decimal(string: amountText.trimmingCharacters(in: .whitespaces))
    }

    var trimmedNote: String {
        note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSave: Bool {
        guard let amount = amountValue, amount > 0 else { return false }
        switch kind {
        case .transfer:
            return sourceAccountID != nil
                && destinationAccountID != nil
                && sourceAccountID != destinationAccountID
        case .income, .expense:
            return sourceAccountID != nil
                && hasPaymentDetails
                && !splitMemberIDs.isEmpty
                && hasSplitDetails
        case .balanceAdjustment:
            return false
        }
    }

    private var hasPaymentDetails: Bool {
        if paymentDrafts.isEmpty {
            return payerMemberID != nil
        }
        return paymentDrafts.allSatisfy {
            $0.memberID != nil && $0.amountValue.map { $0 > 0 } == true
        }
    }

    private var hasSplitDetails: Bool {
        guard splitMode != .equal else { return true }
        return splitMemberIDs.allSatisfy {
            splitValueTexts[$0].flatMap(Self.decimalValue(from:)) != nil
        }
    }

    static func decimalValue(from text: String) -> Decimal? {
        Decimal(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func decimalString(_ value: Decimal?) -> String {
        guard let value else { return "" }
        return NSDecimalNumber(decimal: value).stringValue
    }
}

struct TransactionPaymentDraft: Identifiable, Equatable, Sendable {
    var id = UUID()
    var memberID: UUID?
    var amountText = ""

    var amountValue: Decimal? {
        TransactionDraft.decimalValue(from: amountText)
    }
}
