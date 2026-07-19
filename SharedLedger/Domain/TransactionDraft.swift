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
                && payerMemberID != nil
                && !splitMemberIDs.isEmpty
        }
    }
}
