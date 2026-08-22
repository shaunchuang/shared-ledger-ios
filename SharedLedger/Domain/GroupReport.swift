import Foundation

/// 報表的帳本範圍。屬於個人檢視狀態，不寫入 Core Data，也不透過 CloudKit 同步。
enum ReportBookScope: String, CaseIterable, Identifiable, Sendable {
    case allActiveBooks
    case currentBook
    case selectedBookIDs

    var id: Self { self }

    var displayNameKey: LedgerStringKey {
        switch self {
        case .allActiveBooks: return .reportScopeAllActiveBooks
        case .currentBook: return .reportScopeCurrentBook
        case .selectedBookIDs: return .reportScopeSelectedBookIDs
        }
    }

    var displayName: String { displayNameKey.string() }
}

struct GroupReportCategorySummary: Identifiable, Equatable, Sendable {
    let id: String
    let categoryID: UUID?
    let name: String
    let income: Decimal
    let expense: Decimal
    /// 這個分類佔期間總支出的比例，範圍 0...1；總支出為 0 時為 0。
    let expenseShare: Decimal
}

struct GroupReportBookSummary: Identifiable, Equatable, Sendable {
    let id: String
    let bookID: UUID
    let name: String
    let income: Decimal
    let expense: Decimal
    /// 這個帳本佔期間總支出的比例，範圍 0...1；總支出為 0 時為 0。
    let expenseShare: Decimal

    var net: Decimal { income - expense }
}

enum ReportShare {
    /// 佔比一律以期間總支出為分母，讓分類與帳本的比例可以直接互相對照。
    /// 總支出為 0（例如只有收入）時回傳 0，而不是製造一個無意義的分母。
    static func share(of amount: Decimal, in total: Decimal) -> Decimal {
        guard total > 0, amount > 0 else { return 0 }
        return amount / total
    }

    static func formatted(_ share: Decimal, locale: Locale? = nil) -> String {
        LedgerFormatters.percent(share, locale: locale)
    }
}

struct GroupReportSourceEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let bookID: UUID
    let bookName: String
    let categoryID: UUID?
    let categoryName: String
    let kind: EntryKind
    let amount: Decimal
    let date: Date
    let note: String
    let accountName: String
}

struct GroupReportSnapshot: Equatable, Sendable {
    let interval: DateInterval
    let includedBookIDs: [UUID]
    let income: Decimal
    let expense: Decimal
    let accountBalance: Decimal
    let categories: [GroupReportCategorySummary]
    let books: [GroupReportBookSummary]
    let entries: [GroupReportSourceEntry]

    var net: Decimal { income - expense }

    static let empty = GroupReportSnapshot(
        interval: DateInterval(start: .distantPast, duration: 0),
        includedBookIDs: [],
        income: 0,
        expense: 0,
        accountBalance: 0,
        categories: [],
        books: [],
        entries: []
    )
}
