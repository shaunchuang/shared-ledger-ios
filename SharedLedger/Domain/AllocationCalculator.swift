import Foundation

enum SplitMode: String, CaseIterable, Codable, Sendable {
    case equal
    case percentage
    case fixedAmount
}

struct SplitInput: Equatable, Sendable {
    let memberID: UUID
    let value: Decimal?
}

struct SplitAllocation: Equatable, Sendable {
    let memberID: UUID
    let amount: Decimal
    let inputValue: Decimal?
}

struct PaymentInput: Equatable, Sendable {
    let memberID: UUID
    let amount: Decimal
}

enum AllocationCalculator {
    static func calculateSplits(
        total: Decimal,
        mode: SplitMode,
        inputs: [SplitInput],
        currencyCode: String
    ) throws -> [SplitAllocation] {
        let orderedInputs = inputs.sorted { $0.memberID.uuidString < $1.memberID.uuidString }
        guard total > 0, !orderedInputs.isEmpty else { throw AllocationError.invalidTotal }
        guard LedgerCurrency.isValidAmount(total, currencyCode: currencyCode) else {
            throw AllocationError.invalidCurrencyAmount(currencyCode)
        }
        guard Set(orderedInputs.map(\.memberID)).count == orderedInputs.count else {
            throw AllocationError.duplicateMember
        }

        switch mode {
        case .equal:
            let totalUnits = try minorUnits(for: total, currencyCode: currencyCode)
            let count = Int64(orderedInputs.count)
            let baseUnits = totalUnits / count
            var remainder = totalUnits % count

            return orderedInputs.map { input in
                var units = baseUnits
                if remainder != 0 {
                    units += remainder > 0 ? 1 : -1
                    remainder += remainder > 0 ? -1 : 1
                }
                return SplitAllocation(
                    memberID: input.memberID,
                    amount: amount(fromMinorUnits: units, currencyCode: currencyCode),
                    inputValue: nil
                )
            }

        case .percentage:
            let percentages = try orderedInputs.map { input -> Decimal in
                guard let value = input.value, value > 0 else {
                    throw AllocationError.invalidPercentage
                }
                return value
            }
            guard percentages.reduce(0, +) == 100 else {
                throw AllocationError.percentageTotalMismatch
            }

            let rounded = percentages.map {
                LedgerCurrency.rounded(
                    total * $0 / 100,
                    currencyCode: currencyCode,
                    mode: .plain
                )
            }
            return try adjustedAllocations(
                total: total,
                inputs: orderedInputs,
                proposedAmounts: rounded,
                currencyCode: currencyCode
            )

        case .fixedAmount:
            let amounts = try orderedInputs.map { input -> Decimal in
                guard let value = input.value, value >= 0 else {
                    throw AllocationError.invalidFixedAmount
                }
                guard LedgerCurrency.isValidAmount(value, currencyCode: currencyCode) else {
                    throw AllocationError.invalidCurrencyAmount(currencyCode)
                }
                return value
            }
            guard amounts.reduce(0, +) == total else {
                throw AllocationError.fixedAmountTotalMismatch
            }
            return zip(orderedInputs, amounts).map { input, amount in
                SplitAllocation(
                    memberID: input.memberID,
                    amount: amount,
                    inputValue: input.value
                )
            }
        }
    }

    static func validatePayments(
        total: Decimal,
        inputs: [PaymentInput],
        currencyCode: String
    ) throws -> [PaymentInput] {
        guard total > 0, !inputs.isEmpty else { throw AllocationError.invalidTotal }
        guard Set(inputs.map(\.memberID)).count == inputs.count else {
            throw AllocationError.duplicatePayer
        }
        guard inputs.allSatisfy({
            $0.amount > 0 && LedgerCurrency.isValidAmount($0.amount, currencyCode: currencyCode)
        }) else {
            throw AllocationError.invalidPaymentAmount(currencyCode)
        }
        guard inputs.reduce(Decimal.zero, { $0 + $1.amount }) == total else {
            throw AllocationError.paymentTotalMismatch
        }
        return inputs.sorted { $0.memberID.uuidString < $1.memberID.uuidString }
    }

    private static func adjustedAllocations(
        total: Decimal,
        inputs: [SplitInput],
        proposedAmounts: [Decimal],
        currencyCode: String
    ) throws -> [SplitAllocation] {
        let proposedTotal = proposedAmounts.reduce(0, +)
        var adjustmentUnits = try minorUnits(
            for: total - proposedTotal,
            currencyCode: currencyCode
        )
        var adjusted = proposedAmounts
        var index = 0

        while adjustmentUnits != 0 {
            let unitDelta: Int64 = adjustmentUnits > 0 ? 1 : -1
            adjusted[index] += amount(fromMinorUnits: unitDelta, currencyCode: currencyCode)
            adjustmentUnits -= unitDelta
            index = (index + 1) % adjusted.count
        }

        return zip(inputs, adjusted).map { input, amount in
            SplitAllocation(
                memberID: input.memberID,
                amount: amount,
                inputValue: input.value
            )
        }
    }

    private static func minorUnits(
        for amount: Decimal,
        currencyCode: String
    ) throws -> Int64 {
        guard LedgerCurrency.isValidAmount(amount, currencyCode: currencyCode) else {
            throw AllocationError.invalidCurrencyAmount(currencyCode)
        }
        let digits = LedgerCurrency.fractionDigits(for: currencyCode)
        let scaled = NSDecimalNumber(decimal: amount).multiplying(byPowerOf10: Int16(digits))
        return scaled.int64Value
    }

    private static func amount(fromMinorUnits units: Int64, currencyCode: String) -> Decimal {
        let digits = LedgerCurrency.fractionDigits(for: currencyCode)
        return NSDecimalNumber(value: units)
            .multiplying(byPowerOf10: -Int16(digits))
            .decimalValue
    }

    enum AllocationError: LocalizedError, Equatable {
        case invalidTotal
        case invalidCurrencyAmount(String)
        case duplicateMember
        case invalidPercentage
        case percentageTotalMismatch
        case invalidFixedAmount
        case fixedAmountTotalMismatch
        case duplicatePayer
        case invalidPaymentAmount(String)
        case paymentTotalMismatch

        var errorDescription: String? {
            switch self {
            case .invalidTotal:
                return "交易金額與分攤成員必須有效。"
            case .invalidCurrencyAmount(let code):
                return "金額不符合 \(code) 的最小貨幣單位。"
            case .duplicateMember:
                return "同一位成員不能重複分攤。"
            case .invalidPercentage:
                return "每位成員的分攤比例必須大於 0%。"
            case .percentageTotalMismatch:
                return "分攤比例合計必須等於 100%。"
            case .invalidFixedAmount:
                return "指定分攤金額不可小於 0。"
            case .fixedAmountTotalMismatch:
                return "指定分攤金額合計必須等於交易金額。"
            case .duplicatePayer:
                return "同一位付款人不能重複加入。"
            case .invalidPaymentAmount(let code):
                return "每位付款人的金額必須大於 0，並符合 \(code) 的最小貨幣單位。"
            case .paymentTotalMismatch:
                return "付款金額合計必須等於交易金額。"
            }
        }
    }
}
