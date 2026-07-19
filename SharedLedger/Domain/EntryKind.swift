import Foundation

enum EntryKind: String, CaseIterable, Codable, Sendable {
    case income
    case expense
    case transfer
    case balanceAdjustment

    static let userCreatableCases: [EntryKind] = [.expense, .income, .transfer]

    var displayName: String {
        switch self {
        case .income: return "收入"
        case .expense: return "支出"
        case .transfer: return "轉帳"
        case .balanceAdjustment: return "餘額調整"
        }
    }
}
