import Foundation

enum EntryKind: String, CaseIterable, Codable, Sendable {
    case income
    case expense
    case transfer

    var displayName: String {
        switch self {
        case .income: return "收入"
        case .expense: return "支出"
        case .transfer: return "轉帳"
        }
    }
}

