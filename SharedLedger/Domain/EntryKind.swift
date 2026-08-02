import Foundation

enum EntryKind: String, CaseIterable, Codable, Sendable {
    case income
    case expense
    case transfer
    case balanceAdjustment

    static let userCreatableCases: [EntryKind] = [.expense, .income, .transfer]

    var displayNameKey: LedgerStringKey {
        switch self {
        case .income: return .entryKindIncome
        case .expense: return .entryKindExpense
        case .transfer: return .entryKindTransfer
        case .balanceAdjustment: return .entryKindBalanceAdjustment
        }
    }

    var displayName: String { displayNameKey.string() }
}
