import Foundation

/// 交易搜尋與篩選的條件集合。
///
/// 這是純值型別，不接觸 Core Data：使用者「選了什麼」可以獨立於資料層被保存、
/// 重設與測試，實際的比對規則由 `TransactionSearchService` 負責。
///
/// 所有維度之間是 AND，同一個維度內的多選是 OR。例如選了兩個帳戶又選了一個
/// 分類，代表「（帳戶 A 或帳戶 B）而且分類是 C」。
struct TransactionQuery: Equatable, Sendable {
    /// 關鍵字比對備註、分類名稱、帳戶名稱與付款／分攤成員名稱。
    var keyword = ""
    /// 空集合代表不限交易類型。用集合而不是單一 optional，是因為使用者可能同時
    /// 想看支出與收入，但不想看轉帳。
    var kinds: Set<EntryKind> = []
    /// 起訖日以「整天」為單位：`startDate` 與 `endDate` 當天都包含在內，實際的
    /// 左閉右開換算在 `dateBounds(calendar:)`。
    var startDate: Date?
    var endDate: Date?
    var minAmountText = ""
    var maxAmountText = ""
    /// 轉帳會同時比對來源與目的帳戶，任何一邊符合就算命中。
    var accountIDs: Set<UUID> = []
    var categoryIDs: Set<UUID> = []
    /// 「未分類」沒有分類識別碼，只能用獨立開關表示，不能塞進 `categoryIDs`。
    var includesUncategorized = false
    var payerMemberIDs: Set<UUID> = []
    var participantMemberIDs: Set<UUID> = []
    /// 作廢交易預設不出現在結果裡；需要核對歷史時才打開。
    var includesVoided = false

    var trimmedKeyword: String {
        keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 關鍵字以空白切成多個詞，必須全部命中。這樣「餐飲 小明」才能一次收斂到
    /// 「小明付的餐飲」，而不是把整串當成一個不存在的字串去比對。
    var keywordTokens: [String] {
        trimmedKeyword
            .split(whereSeparator: \.isWhitespace)
            .map { Self.normalizedForSearch(String($0)) }
            .filter { !$0.isEmpty }
    }

    var minAmount: Decimal? {
        TransactionDraft.decimalValue(from: minAmountText)
    }

    var maxAmount: Decimal? {
        TransactionDraft.decimalValue(from: maxAmountText)
    }

    /// 使用者打了字但解析不出金額。這種條件會被忽略，所以畫面必須提示，不能讓
    /// 使用者以為自己篩過金額。
    var hasUnparsableAmountInput: Bool {
        let inputs = [minAmountText, maxAmountText]
        return inputs.contains { text in
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && TransactionDraft.decimalValue(from: text) == nil
        }
    }

    /// 下限大於上限。條件仍然照字面套用（結果會是空的），畫面負責解釋為什麼沒有
    /// 資料；靜靜地把兩個值對調反而會顯示使用者沒有要求的交易。
    var hasInvertedAmountRange: Bool {
        guard let minAmount, let maxAmount else { return false }
        return minAmount > maxAmount
    }

    var hasInvertedDateRange: Bool {
        guard let startDate, let endDate else { return false }
        return startDate > endDate
    }

    /// 關鍵字以外還套用了幾個篩選維度，用來在工具列顯示未讀式的數字標記。
    var activeFilterCount: Int {
        var count = 0
        if !kinds.isEmpty { count += 1 }
        if startDate != nil || endDate != nil { count += 1 }
        if minAmount != nil || maxAmount != nil { count += 1 }
        if !accountIDs.isEmpty { count += 1 }
        if !categoryIDs.isEmpty || includesUncategorized { count += 1 }
        if !payerMemberIDs.isEmpty { count += 1 }
        if !participantMemberIDs.isEmpty { count += 1 }
        if includesVoided { count += 1 }
        return count
    }

    var hasActiveFilters: Bool {
        activeFilterCount > 0
    }

    /// 完全沒有任何條件，畫面就是單純的交易列表，而不是一次搜尋。
    var isEmpty: Bool {
        keywordTokens.isEmpty && !hasActiveFilters
    }

    /// 起訖日換算成左閉右開區間。
    ///
    /// 使用者說的「到 8 月 31 日」包含當天整天，所以上界取隔天的 00:00 並用
    /// `<` 比對，剛好落在午夜的交易才不會同時屬於兩個區間。
    func dateBounds(calendar: Calendar = .current) -> (start: Date?, end: Date?) {
        let start = startDate.map { calendar.startOfDay(for: $0) }
        let end = endDate.flatMap { date in
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
        }
        return (start, end)
    }

    /// 比對用的正規化：忽略大小寫、變音符號與全形／半形差異，讓「Ａ」也能搜到
    /// 「A」。
    static func normalizedForSearch(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
    }
}
