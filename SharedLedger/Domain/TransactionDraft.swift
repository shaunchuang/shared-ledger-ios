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
}

struct TransactionPaymentDraft: Identifiable, Equatable, Sendable {
    var id = UUID()
    var memberID: UUID?
    var amountText = ""

    var amountValue: Decimal? {
        TransactionDraft.decimalValue(from: amountText)
    }
}
