import Foundation

enum SplitMode: String, CaseIterable, Codable, Sendable {
    case equal
    case percentage
    case fixedAmount

    var displayNameKey: LedgerStringKey {
        switch self {
        case .equal: return .splitModeEqual
        case .percentage: return .splitModePercentage
        case .fixedAmount: return .splitModeFixedAmount
        }
    }

    var displayName: String { displayNameKey.string() }
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
                    amount: LedgerCurrency.amount(
                        fromMinorUnits: units,
                        currencyCode: currencyCode
                    ),
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
        // 回傳順序即使用者輸入的付款人順序：呼叫端據此寫入 EntryPayment.sortOrder，
        // 而 sortOrder 決定多付款人清單的顯示順序與編輯時的草稿還原順序。
        // 稽核快照不依賴這裡的順序，它在建立時會自行依 memberID 排序。
        return inputs
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
            adjusted[index] += LedgerCurrency.amount(
                fromMinorUnits: unitDelta,
                currencyCode: currencyCode
            )
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
        guard let units = LedgerCurrency.minorUnits(amount, currencyCode: currencyCode) else {
            throw AllocationError.invalidCurrencyAmount(currencyCode)
        }
        return units
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
                return LedgerStringKey.errorAllocationInvalidInput.string()
            case .invalidCurrencyAmount(let code):
                return LedgerStringKey.errorCurrencyMinorUnit.string(arguments: [code])
            case .duplicateMember:
                return LedgerStringKey.errorAllocationDuplicateSplitMember.string()
            case .invalidPercentage:
                return LedgerStringKey.errorAllocationPercentagePositive.string()
            case .percentageTotalMismatch:
                return LedgerStringKey.errorAllocationPercentageTotal.string()
            case .invalidFixedAmount:
                return LedgerStringKey.errorAllocationFixedAmountNegative.string()
            case .fixedAmountTotalMismatch:
                return LedgerStringKey.errorAllocationFixedAmountTotal.string()
            case .duplicatePayer:
                return LedgerStringKey.errorAllocationDuplicatePayer.string()
            case .invalidPaymentAmount(let code):
                return LedgerStringKey.errorAllocationPaymentAmount.string(arguments: [code])
            case .paymentTotalMismatch:
                return LedgerStringKey.errorAllocationPaymentTotal.string()
            }
        }
    }
}
