import Foundation

struct AccountDraft: Equatable, Sendable {
    var name = ""
    var type: AccountType = .cash
    var openingBalanceText = "0"

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var openingBalanceValue: Decimal? {
        Decimal(string: openingBalanceText.trimmingCharacters(in: .whitespaces))
    }

    var canCreate: Bool {
        !trimmedName.isEmpty && openingBalanceValue != nil
    }
}

struct AccountBalanceMovement: Equatable, Sendable {
    let kind: EntryKind
    let amount: Decimal
    let isSourceAccount: Bool
    let isDestinationAccount: Bool
}

enum AccountBalanceCalculator {
    static func balance(
        openingBalance: Decimal,
        movements: [AccountBalanceMovement]
    ) -> Decimal {
        movements.reduce(openingBalance) { partialResult, movement in
            partialResult + effect(of: movement)
        }
    }

    static func effect(of movement: AccountBalanceMovement) -> Decimal {
        switch movement.kind {
        case .income:
            return movement.isSourceAccount ? movement.amount : 0
        case .expense:
            return movement.isSourceAccount ? -movement.amount : 0
        case .transfer:
            var result: Decimal = 0
            if movement.isSourceAccount {
                result -= movement.amount
            }
            if movement.isDestinationAccount {
                result += movement.amount
            }
            return result
        case .balanceAdjustment:
            return movement.isSourceAccount ? movement.amount : 0
        }
    }
}
