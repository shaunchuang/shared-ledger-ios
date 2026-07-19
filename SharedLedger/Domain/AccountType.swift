import Foundation

enum AccountType: String, CaseIterable, Identifiable, Codable, Sendable {
    case cash
    case bank
    case creditCard
    case other

    var id: Self { self }

    var displayName: String {
        switch self {
        case .cash: return "現金"
        case .bank: return "銀行帳戶"
        case .creditCard: return "信用卡"
        case .other: return "其他"
        }
    }

    var systemImage: String {
        switch self {
        case .cash: return "banknote"
        case .bank: return "building.columns"
        case .creditCard: return "creditcard"
        case .other: return "square.grid.2x2"
        }
    }
}
