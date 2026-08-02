import CoreData
import Foundation

/// 跨帳本報表的唯讀查詢服務。
///
/// 依 `ARCHITECTURE.md`「群組跨帳本統計」的規範：View 不自行執行跨帳本加總，而是
/// 由這裡接收群組、日期區間與帳本範圍，回傳純值型別的 `GroupReportSnapshot`。
/// 報表不改變資料所有權，也不寫入任何資料。
@MainActor
struct GroupReportService {
    private let persistence: PersistenceController

    init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    func snapshot(
        in group: LedgerGroup,
        interval: DateInterval,
        scope: ReportBookScope,
        currentBook: LedgerBook?,
        selectedBookIDs: Set<UUID> = []
    ) -> GroupReportSnapshot {
        let includedBooks = BookRepository(persistence: persistence).books(
            in: group,
            scope: scope,
            currentBook: currentBook,
            selectedBookIDs: selectedBookIDs
        )

        let includedObjectIDs = Set(includedBooks.map(\.objectID))
        let voidedEntryIDs = EntryRepository(persistence: persistence).voidedEntryIDs(in: group)
        let entries = (group.entries as? Set<LedgerEntry> ?? [])
            .filter { entry in
                // DateInterval.contains 含右端點，會讓剛好落在下個月 1 日 00:00:00
                // 的交易同時被算進兩個月，所以這裡自行做左閉右開判斷。
                guard let book = entry.book,
                      includedObjectIDs.contains(book.objectID),
                      let date = entry.date,
                      date >= interval.start, date < interval.end,
                      let kind = entry.kind.flatMap(EntryKind.init(rawValue:)),
                      kind == .income || kind == .expense
                else { return false }

                if let entryID = entry.id, voidedEntryIDs.contains(entryID) {
                    return false
                }
                return true
            }
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
        var categoryTotals: [String: MutableCategorySummary] = [:]
        var bookTotals: [UUID: MutableBookSummary] = [:]
        var sourceEntries: [GroupReportSourceEntry] = []

        for entry in entries {
            guard let kind = entry.kind.flatMap(EntryKind.init(rawValue:)),
                  let book = entry.book,
                  let bookID = book.id,
                  let entryID = entry.id,
                  let date = entry.date
            else { continue }

            let amount = (entry.amount as Decimal?) ?? 0
            guard amount >= 0 else { continue }

            if kind == .income {
                income += amount
            } else {
                expense += amount
            }

            let categoryID = entry.category?.id
            let categoryKey = categoryID?.uuidString ?? "uncategorized"
            var category = categoryTotals[categoryKey] ?? MutableCategorySummary(
                categoryID: categoryID,
                name: entry.category?.name
                    ?? LedgerStringKey.transactionFormCategoryNone.string()
            )
            if kind == .income {
                category.income += amount
            } else {
                category.expense += amount
            }
            categoryTotals[categoryKey] = category

            var bookSummary = bookTotals[bookID] ?? MutableBookSummary(
                bookID: bookID,
                name: book.name ?? LedgerStringKey.commonPlaceholderUnnamedBook.string()
            )
            if kind == .income {
                bookSummary.income += amount
            } else {
                bookSummary.expense += amount
            }
            bookTotals[bookID] = bookSummary

            sourceEntries.append(
                GroupReportSourceEntry(
                    id: entryID,
                    bookID: bookID,
                    bookName: book.name
                        ?? LedgerStringKey.commonPlaceholderUnnamedBook.string(),
                    categoryID: categoryID,
                    categoryName: entry.category?.name
                        ?? LedgerStringKey.transactionFormCategoryNone.string(),
                    kind: kind,
                    amount: amount,
                    date: date,
                    note: entry.note ?? "",
                    accountName: entry.sourceAccount?.name ?? "-"
                )
            )
        }

        let categories = categoryTotals
            .map { key, summary in
                GroupReportCategorySummary(
                    id: key,
                    categoryID: summary.categoryID,
                    name: summary.name,
                    income: summary.income,
                    expense: summary.expense,
                    expenseShare: ReportShare.share(of: summary.expense, in: expense)
                )
            }
            .sorted { lhs, rhs in
                if lhs.expense != rhs.expense { return lhs.expense > rhs.expense }
                if lhs.income != rhs.income { return lhs.income > rhs.income }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }

        let bookOrder = Dictionary(uniqueKeysWithValues: includedBooks.enumerated().compactMap { index, book in
            book.id.map { ($0, index) }
        })
        let books = bookTotals.values
            .map { summary in
                GroupReportBookSummary(
                    id: summary.bookID.uuidString,
                    bookID: summary.bookID,
                    name: summary.name,
                    income: summary.income,
                    expense: summary.expense,
                    expenseShare: ReportShare.share(of: summary.expense, in: expense)
                )
            }
            .sorted { lhs, rhs in
                let lhsOrder = bookOrder[lhs.bookID] ?? Int.max
                let rhsOrder = bookOrder[rhs.bookID] ?? Int.max
                if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }

        let accounts = Array(group.accounts as? Set<LedgerAccount> ?? [])
        let accountBalance = AccountRepository(persistence: persistence).totalBalance(for: accounts)

        return GroupReportSnapshot(
            interval: interval,
            includedBookIDs: includedBooks.compactMap(\.id),
            income: income,
            expense: expense,
            accountBalance: accountBalance,
            categories: categories,
            books: books,
            entries: sourceEntries
        )
    }

    private struct MutableCategorySummary {
        let categoryID: UUID?
        let name: String
        var income: Decimal = 0
        var expense: Decimal = 0
    }

    private struct MutableBookSummary {
        let bookID: UUID
        let name: String
        var income: Decimal = 0
        var expense: Decimal = 0
    }
}
