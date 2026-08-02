import CoreData
import Foundation

/// 依月份分組後的一段搜尋結果。
///
/// 與 `GroupReportSnapshot` 不同，這裡保留 `LedgerEntry` 本身而不是純值快照：
/// 每一列都要能推進交易詳情並跟著編輯即時更新，換成值型別等於在詳情頁再用 ID
/// 查一次同一筆資料，還會讓列表失去 `@ObservedObject` 的即時性。
struct TransactionSearchSection: Identifiable {
    /// 該月份的第一天 00:00，同時當作穩定的分組識別。
    let id: Date
    let title: String
    let entries: [LedgerEntry]
    let income: Decimal
    let expense: Decimal

    var net: Decimal { income - expense }
}

struct TransactionSearchResult {
    let sections: [TransactionSearchSection]
    let matchCount: Int
    /// 套用篩選前、範圍內的交易數。用來分辨「這個帳本還沒有交易」與「有交易但
    /// 沒有一筆符合條件」，兩者要給使用者的下一步完全不同。
    let scopedCount: Int
    let income: Decimal
    let expense: Decimal
    let includedBookIDs: [UUID]
    /// 結果中已作廢的交易。作廢狀態存在稽核事件裡，逐列重新判斷等於每一列都掃一次
    /// 整個群組的稽核紀錄，所以在這裡算好一次給畫面用。
    let voidedEntryIDs: Set<UUID>

    var net: Decimal { income - expense }
    var hasMatches: Bool { matchCount > 0 }

    static let empty = TransactionSearchResult(
        sections: [],
        matchCount: 0,
        scopedCount: 0,
        income: 0,
        expense: 0,
        includedBookIDs: [],
        voidedEntryIDs: []
    )
}

/// 把 `TransactionQuery` 套用到群組的交易上，並依月份分組。
///
/// 所有比對都在記憶體裡完成，而不是組 `NSPredicate`：作廢狀態存在稽核事件裡、
/// 付款人同時來自 `payments` 與舊版的 `payer`、選了父分類要一併涵蓋子分類，
/// 這些規則用 predicate 表達會既難讀又容易和資料層的真實定義走鐘。
@MainActor
struct TransactionSearchService {
    private let persistence: PersistenceController
    private let calendar: Calendar

    init(persistence: PersistenceController = .shared, calendar: Calendar = .current) {
        self.persistence = persistence
        self.calendar = calendar
    }

    func results(
        in group: LedgerGroup,
        query: TransactionQuery,
        scope: ReportBookScope,
        currentBook: LedgerBook?,
        selectedBookIDs: Set<UUID> = []
    ) -> TransactionSearchResult {
        results(
            candidates: Array(group.entries as? Set<LedgerEntry> ?? []),
            in: group,
            query: query,
            scope: scope,
            currentBook: currentBook,
            selectedBookIDs: selectedBookIDs
        )
    }

    /// - Parameter candidates: 呼叫端已經取得的交易，通常來自畫面上的
    ///   `@FetchRequest`。讓畫面沿用自己的 fetch 結果，SwiftUI 才會在新增或修改
    ///   交易後自動更新，不需要再多一層手動的變更通知。
    func results(
        candidates: [LedgerEntry],
        in group: LedgerGroup,
        query: TransactionQuery,
        scope: ReportBookScope,
        currentBook: LedgerBook?,
        selectedBookIDs: Set<UUID> = []
    ) -> TransactionSearchResult {
        let includedBooks = BookRepository(persistence: persistence).books(
            in: group,
            scope: scope,
            currentBook: currentBook,
            selectedBookIDs: selectedBookIDs
        )
        let includedObjectIDs = Set(includedBooks.map(\.objectID))
        let voidedEntryIDs = EntryRepository(persistence: persistence).voidedEntryIDs(in: group)

        let scopedEntries = candidates.filter { entry in
            guard let book = entry.book, includedObjectIDs.contains(book.objectID) else {
                return false
            }
            if !query.includesVoided, let entryID = entry.id, voidedEntryIDs.contains(entryID) {
                return false
            }
            return true
        }

        let categoryIDs = expandedCategoryIDs(query.categoryIDs, in: group)
        let bounds = query.dateBounds(calendar: calendar)
        let matchedEntries = scopedEntries
            .filter { matches($0, query: query, expandedCategoryIDs: categoryIDs, bounds: bounds) }
            .sorted { lhs, rhs in
                let lhsDate = lhs.date ?? .distantPast
                let rhsDate = rhs.date ?? .distantPast
                if lhsDate == rhsDate {
                    return (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast)
                }
                return lhsDate > rhsDate
            }

        var income = Decimal.zero
        var expense = Decimal.zero
        var grouped: [Date: [LedgerEntry]] = [:]
        var monthIncome: [Date: Decimal] = [:]
        var monthExpense: [Date: Decimal] = [:]

        for entry in matchedEntries {
            let month = monthStart(for: entry.date ?? .distantPast)
            grouped[month, default: []].append(entry)

            // 作廢交易只在使用者主動要求時出現，而且不列入任何小計。
            if let entryID = entry.id, voidedEntryIDs.contains(entryID) { continue }

            let amount = (entry.amount as Decimal?) ?? 0
            // 轉帳與餘額調整不是收入也不是支出，只出現在列表裡，不進小計。
            switch entry.kind.flatMap(EntryKind.init(rawValue:)) {
            case .some(.income):
                income += amount
                monthIncome[month, default: 0] += amount
            case .some(.expense):
                expense += amount
                monthExpense[month, default: 0] += amount
            case .some(.transfer), .some(.balanceAdjustment), .none:
                break
            }
        }

        let sections = grouped
            .map { month, entries in
                TransactionSearchSection(
                    id: month,
                    title: month.formatted(.dateTime.year().month(.wide)),
                    entries: entries,
                    income: monthIncome[month] ?? 0,
                    expense: monthExpense[month] ?? 0
                )
            }
            .sorted { $0.id > $1.id }

        return TransactionSearchResult(
            sections: sections,
            matchCount: matchedEntries.count,
            scopedCount: scopedEntries.count,
            income: income,
            expense: expense,
            includedBookIDs: includedBooks.compactMap(\.id),
            voidedEntryIDs: voidedEntryIDs
        )
    }

    private func matches(
        _ entry: LedgerEntry,
        query: TransactionQuery,
        expandedCategoryIDs: Set<UUID>,
        bounds: (start: Date?, end: Date?)
    ) -> Bool {
        if !query.kinds.isEmpty {
            guard let kind = entry.kind.flatMap(EntryKind.init(rawValue:)),
                  query.kinds.contains(kind)
            else { return false }
        }

        if bounds.start != nil || bounds.end != nil {
            guard let date = entry.date else { return false }
            if let start = bounds.start, date < start { return false }
            if let end = bounds.end, date >= end { return false }
        }

        if query.minAmount != nil || query.maxAmount != nil {
            let amount = (entry.amount as Decimal?) ?? 0
            if let minimum = query.minAmount, amount < minimum { return false }
            if let maximum = query.maxAmount, amount > maximum { return false }
        }

        if !query.accountIDs.isEmpty {
            let accountIDs = [entry.sourceAccount?.id, entry.destinationAccount?.id].compactMap { $0 }
            guard accountIDs.contains(where: query.accountIDs.contains) else { return false }
        }

        if !expandedCategoryIDs.isEmpty || query.includesUncategorized {
            if let categoryID = entry.category?.id {
                guard expandedCategoryIDs.contains(categoryID) else { return false }
            } else {
                guard query.includesUncategorized else { return false }
            }
        }

        if !query.payerMemberIDs.isEmpty {
            guard payerIDs(of: entry).contains(where: query.payerMemberIDs.contains) else {
                return false
            }
        }

        if !query.participantMemberIDs.isEmpty {
            guard participantIDs(of: entry).contains(where: query.participantMemberIDs.contains) else {
                return false
            }
        }

        let tokens = query.keywordTokens
        if !tokens.isEmpty {
            let haystack = searchableText(of: entry)
            guard tokens.allSatisfy({ haystack.contains($0) }) else { return false }
        }

        return true
    }

    /// 選了父分類就涵蓋其子分類。父分類在使用者眼中是一個範圍，只比對自身會讓
    /// 「餐飲」搜不到記在「餐飲 → 早餐」的交易。
    private func expandedCategoryIDs(_ selected: Set<UUID>, in group: LedgerGroup) -> Set<UUID> {
        guard !selected.isEmpty else { return [] }
        let categories = group.categories as? Set<LedgerCategory> ?? []
        let selectedCategories = categories.filter { $0.id.map(selected.contains) == true }

        var expanded = selected
        var pending = Array(selectedCategories)
        while let category = pending.popLast() {
            for child in category.children as? Set<LedgerCategory> ?? [] {
                guard let childID = child.id, expanded.insert(childID).inserted else { continue }
                pending.append(child)
            }
        }
        return expanded
    }

    /// 舊資料只有單一 `payer`，V7 之後才有 `payments`。兩邊都看，搜尋才不會因為
    /// 某台裝置還沒跑完遷移就漏掉交易。
    private func payerIDs(of entry: LedgerEntry) -> [UUID] {
        let payments = entry.payments as? Set<EntryPayment> ?? []
        let ids = payments.compactMap { $0.member?.id }
        return ids.isEmpty ? [entry.payer?.id].compactMap { $0 } : ids
    }

    private func participantIDs(of entry: LedgerEntry) -> [UUID] {
        let splits = entry.splits as? Set<EntrySplit> ?? []
        return splits.compactMap { $0.member?.id }
    }

    private func searchableText(of entry: LedgerEntry) -> String {
        var parts: [String] = []
        if let note = entry.note, !note.isEmpty { parts.append(note) }
        if let category = entry.category?.name { parts.append(category) }
        if let source = entry.sourceAccount?.name { parts.append(source) }
        if let destination = entry.destinationAccount?.name { parts.append(destination) }

        let payments = entry.payments as? Set<EntryPayment> ?? []
        parts.append(contentsOf: payments.compactMap { $0.member?.displayName })
        if payments.isEmpty, let payerName = entry.payer?.displayName {
            parts.append(payerName)
        }
        let splits = entry.splits as? Set<EntrySplit> ?? []
        parts.append(contentsOf: splits.compactMap { $0.member?.displayName })

        return TransactionQuery.normalizedForSearch(parts.joined(separator: "\n"))
    }

    private func monthStart(for date: Date) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
    }
}
