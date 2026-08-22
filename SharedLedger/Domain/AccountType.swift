import Foundation

enum AccountType: String, CaseIterable, Identifiable, Codable, Sendable {
    case cash
    case bank
    case creditCard
    case other

    var id: Self { self }

    var displayNameKey: LedgerStringKey {
        switch self {
        case .cash: return .accountTypeCash
        case .bank: return .accountTypeBank
        case .creditCard: return .accountTypeCreditCard
        case .other: return .accountTypeOther
        }
    }

    var displayName: String { displayNameKey.string() }

    var systemImage: String {
        switch self {
        case .cash: return "banknote"
        case .bank: return "building.columns"
        case .creditCard: return "creditcard"
        case .other: return "square.grid.2x2"
        }
    }
}
