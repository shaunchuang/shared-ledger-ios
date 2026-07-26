import Foundation

struct SettlementShareInput: Equatable, Sendable {
    let memberID: UUID
    let amount: Decimal
}

struct SettlementTransactionInput: Equatable, Sendable {
    let kind: EntryKind
    let payments: [PaymentInput]
    let splits: [SettlementShareInput]
}

struct SettlementRecordInput: Equatable, Sendable {
    let id: UUID
    let fromMemberID: UUID
    let toMemberID: UUID
    let amount: Decimal
}

struct MemberBalance: Equatable, Sendable {
    let memberID: UUID
    let amount: Decimal
}

struct SettlementTransfer: Equatable, Sendable {
    let fromMemberID: UUID
    let toMemberID: UUID
    let amount: Decimal
}

struct SettlementResult: Equatable, Sendable {
    let balances: [MemberBalance]
    let suggestedTransfers: [SettlementTransfer]

    static let empty = SettlementResult(balances: [], suggestedTransfers: [])
}

enum SettlementCalculator {
    static func calculate(
        transactions: [SettlementTransactionInput],
        settlements: [SettlementRecordInput] = [],
        currencyCode: String
    ) throws -> SettlementResult {
        var unitsByMember: [UUID: Int64] = [:]

        for transaction in transactions {
            guard transaction.kind == .expense || transaction.kind == .income else { continue }

            let normalized = try normalize(transaction, currencyCode: currencyCode)

            // Expenses credit members who actually paid and debit the members who
            // should bear the cost. Income/refunds move the obligation in the
            // opposite direction so a shared refund reduces outstanding debt.
            let paymentDirection: Int64 = transaction.kind == .expense ? 1 : -1
            for (memberID, units) in normalized.payments {
                unitsByMember[memberID, default: 0] += paymentDirection * units
            }
            for (memberID, units) in normalized.splits {
                unitsByMember[memberID, default: 0] -= paymentDirection * units
            }
        }

        for settlement in settlements {
            guard settlement.fromMemberID != settlement.toMemberID else {
                throw SettlementError.invalidSettlement
            }
            let units = try minorUnits(for: settlement.amount, currencyCode: currencyCode)
            guard units > 0 else { throw SettlementError.invalidSettlement }

            // A completed settlement reduces both sides of the outstanding debt.
            unitsByMember[settlement.fromMemberID, default: 0] += units
            unitsByMember[settlement.toMemberID, default: 0] -= units
        }

        guard unitsByMember.values.reduce(Int64.zero, +) == 0 else {
            throw SettlementError.unbalancedResult
        }

        let orderedBalances = unitsByMember
            .map { memberID, units in
                MemberBalance(
                    memberID: memberID,
                    amount: LedgerCurrency.amount(fromMinorUnits: units, currencyCode: currencyCode)
                )
            }
            .sorted { $0.memberID.uuidString < $1.memberID.uuidString }

        let transfers = try minimalTransfers(
            unitsByMember: unitsByMember,
            currencyCode: currencyCode
        )
        return SettlementResult(balances: orderedBalances, suggestedTransfers: transfers)
    }

    /// Throws the same errors `calculate` would raise for this single transaction.
    ///
    /// Callers that read transactions out of a partially synchronised store use this
    /// to quarantine an individual inconsistent entry instead of failing the whole book.
    static func validate(
        _ transaction: SettlementTransactionInput,
        currencyCode: String
    ) throws {
        guard transaction.kind == .expense || transaction.kind == .income else { return }
        _ = try normalize(transaction, currencyCode: currencyCode)
    }

    private static func normalize(
        _ transaction: SettlementTransactionInput,
        currencyCode: String
    ) throws -> (payments: [(UUID, Int64)], splits: [(UUID, Int64)]) {
        let payments = try transaction.payments.map { payment -> (UUID, Int64) in
            let units = try minorUnits(for: payment.amount, currencyCode: currencyCode)
            guard units > 0 else { throw SettlementError.invalidTransactionAmount }
            return (payment.memberID, units)
        }
        let splits = try transaction.splits.map { split -> (UUID, Int64) in
            let units = try minorUnits(for: split.amount, currencyCode: currencyCode)
            guard units >= 0 else { throw SettlementError.invalidTransactionAmount }
            return (split.memberID, units)
        }

        guard payments.reduce(Int64.zero, { $0 + $1.1 })
                == splits.reduce(Int64.zero, { $0 + $1.1 }) else {
            throw SettlementError.transactionTotalsMismatch
        }
        return (payments, splits)
    }

    private struct UnitTransfer: Equatable {
        let fromIndex: Int
        let toIndex: Int
        let units: Int64
    }

    /// A member's remaining debt or credit while the greedy pass drains it.
    private struct OutstandingBalance {
        let index: Int
        var units: Int64
    }

    /// Above this many members with a non-zero balance the exact minimum-transfer
    /// search becomes exponential, so the deterministic greedy fallback is used
    /// instead. Greedy still yields at most `n - 1` transfers.
    private static let exactSearchMemberLimit = 10

    private static func minimalTransfers(
        unitsByMember: [UUID: Int64],
        currencyCode: String
    ) throws -> [SettlementTransfer] {
        let members = unitsByMember
            .filter { $0.value != 0 }
            .sorted { $0.key.uuidString < $1.key.uuidString }
        guard !members.isEmpty else { return [] }

        let memberIDs = members.map(\.key)
        let initialState = members.map(\.value)

        // `memberIDs` is sorted by UUID string, so index order is already the stable
        // tie-break order and transfers can be compared numerically by index.
        let unitTransfers = memberIDs.count <= exactSearchMemberLimit
            ? exactMinimalTransfers(from: initialState)
            : greedyTransfers(from: initialState)

        guard unitTransfers.allSatisfy({ $0.units > 0 }) else {
            throw SettlementError.unbalancedResult
        }
        return unitTransfers.map {
            SettlementTransfer(
                fromMemberID: memberIDs[$0.fromIndex],
                toMemberID: memberIDs[$0.toIndex],
                amount: LedgerCurrency.amount(
                    fromMinorUnits: $0.units,
                    currencyCode: currencyCode
                )
            )
        }
    }

    private static func exactMinimalTransfers(from initialState: [Int64]) -> [UnitTransfer] {
        // Keying the memo on the state array avoids rebuilding a joined string for
        // every visited state, which dominated the previous implementation's cost.
        var memo: [[Int64]: [UnitTransfer]] = [:]

        func isBetter(_ candidate: [UnitTransfer], than current: [UnitTransfer]) -> Bool {
            if candidate.count != current.count { return candidate.count < current.count }
            for (lhs, rhs) in zip(candidate, current) {
                if lhs.fromIndex != rhs.fromIndex { return lhs.fromIndex < rhs.fromIndex }
                if lhs.toIndex != rhs.toIndex { return lhs.toIndex < rhs.toIndex }
                if lhs.units != rhs.units { return lhs.units < rhs.units }
            }
            return false
        }

        func search(_ state: [Int64]) -> [UnitTransfer] {
            if let cached = memo[state] { return cached }
            guard let firstIndex = state.firstIndex(where: { $0 != 0 }) else {
                memo[state] = []
                return []
            }

            var best: [UnitTransfer]?
            var seenCounterpartyBalances = Set<Int64>()

            for index in state.indices where index != firstIndex {
                guard state[firstIndex].signum() != state[index].signum(),
                      state[index] != 0,
                      seenCounterpartyBalances.insert(state[index]).inserted else {
                    continue
                }

                let units = min(abs(state[firstIndex]), abs(state[index]))
                var next = state
                let transfer: UnitTransfer

                if state[firstIndex] < 0 {
                    next[firstIndex] += units
                    next[index] -= units
                    transfer = UnitTransfer(fromIndex: firstIndex, toIndex: index, units: units)
                } else {
                    next[firstIndex] -= units
                    next[index] += units
                    transfer = UnitTransfer(fromIndex: index, toIndex: firstIndex, units: units)
                }

                let candidate = [transfer] + search(next)
                if let currentBest = best {
                    if isBetter(candidate, than: currentBest) { best = candidate }
                } else {
                    best = candidate
                }
            }

            let resolved = best ?? []
            memo[state] = resolved
            return resolved
        }

        return search(initialState)
    }

    /// Repeatedly settles the largest debtor against the largest creditor. This
    /// produces at most `n - 1` transfers in `O(n log n)` and stays responsive for
    /// group sizes where the exact search is not affordable on the main thread.
    private static func greedyTransfers(from initialState: [Int64]) -> [UnitTransfer] {
        var debtors: [OutstandingBalance] = []
        var creditors: [OutstandingBalance] = []
        for (index, units) in initialState.enumerated() {
            if units < 0 {
                debtors.append(OutstandingBalance(index: index, units: -units))
            } else if units > 0 {
                creditors.append(OutstandingBalance(index: index, units: units))
            }
        }

        // Largest balance first; ties break on index so the suggestion list stays
        // stable between reloads.
        let byDescendingUnits: (OutstandingBalance, OutstandingBalance) -> Bool = { lhs, rhs in
            if lhs.units != rhs.units { return lhs.units > rhs.units }
            return lhs.index < rhs.index
        }
        debtors.sort(by: byDescendingUnits)
        creditors.sort(by: byDescendingUnits)

        var transfers: [UnitTransfer] = []
        var debtorIndex = 0
        var creditorIndex = 0

        while debtorIndex < debtors.count, creditorIndex < creditors.count {
            let debtor = debtors[debtorIndex]
            let creditor = creditors[creditorIndex]
            let units = min(debtor.units, creditor.units)

            if units > 0 {
                transfers.append(
                    UnitTransfer(fromIndex: debtor.index, toIndex: creditor.index, units: units)
                )
            }

            debtors[debtorIndex].units -= units
            creditors[creditorIndex].units -= units
            if debtors[debtorIndex].units == 0 { debtorIndex += 1 }
            if creditors[creditorIndex].units == 0 { creditorIndex += 1 }
        }

        return transfers
    }

    private static func minorUnits(for amount: Decimal, currencyCode: String) throws -> Int64 {
        guard let units = LedgerCurrency.minorUnits(amount, currencyCode: currencyCode) else {
            throw SettlementError.invalidCurrencyAmount(currencyCode)
        }
        return units
    }

    enum SettlementError: LocalizedError, Equatable {
        case invalidCurrencyAmount(String)
        case invalidTransactionAmount
        case transactionTotalsMismatch
        case invalidSettlement
        case unbalancedResult

        var errorDescription: String? {
            switch self {
            case .invalidCurrencyAmount(let code):
                return "結算金額不符合 \(code) 的最小貨幣單位。"
            case .invalidTransactionAmount:
                return "交易的付款或分攤金額無效，無法計算結算。"
            case .transactionTotalsMismatch:
                return "交易的付款與分攤總額不一致，無法計算結算。"
            case .invalidSettlement:
                return "結算付款人、收款人與金額必須有效。"
            case .unbalancedResult:
                return "成員淨額無法平衡，請先檢查交易資料。"
            }
        }
    }
}
