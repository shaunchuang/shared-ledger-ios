import Foundation

/// 一次交易寫入的識別碼，以及「哪些付款與分攤明細屬於這次寫入」的判斷規則。
///
/// 需要這個東西的理由是 CloudKit 的合併粒度。`LedgerEntry`、`EntryPayment` 與
/// `EntrySplit` 是三種各自獨立的 record：兩台裝置同時編輯同一筆交易時，金額欄位由
/// 最後寫入的那台勝出，但兩邊各自新增的付款與分攤列都是全新的 record，誰也不會蓋掉
/// 誰，最後兩組明細會同時留在同一筆交易底下。那不只是畫面上多出幾列——
/// `SettlementCalculator` 只檢查付款合計等於分攤合計，兩組明細加起來剛好還是相等的，
/// 所以這筆交易會以雙倍金額進入結算，而且沒有任何一層會察覺。
///
/// 解法是讓明細帶上自己所屬的那次寫入：交易上的 `revisionID` 由最後勝出的那次寫入
/// 決定，明細只有在 `entryRevisionID` 與它相等時才算數。CloudKit 選了哪一台裝置的
/// 交易 record，就等於同時選定了那台裝置的整組付款與分攤，永遠不會出現兩次編輯混在
/// 一起的中間狀態。
///
/// 兩個刻意的邊界條件：
/// - V9 之前寫入的資料兩邊都是 `nil`，`nil == nil` 成立，因此舊資料不需要回填，
///   也不會因為升級就突然被判定成落選。
/// - 一台還沒更新到 V9 的裝置若覆寫了交易 record，`revisionID` 可能被清成 `nil`，
///   這時只有同樣沒有 revision 的舊明細算數，行為退回 V9 之前的樣子；不會因此把
///   兩組明細混著算。
enum EntryRevision {
    /// 屬於這次寫入的明細。
    static func live<Row>(
        _ rows: [Row],
        of revisionID: UUID?,
        revision: (Row) -> UUID?
    ) -> [Row] {
        rows.filter { revision($0) == revisionID }
    }

    /// 已經被別的寫入取代、所有計算都不該再看到的明細。
    static func superseded<Row>(
        _ rows: [Row],
        of revisionID: UUID?,
        revision: (Row) -> UUID?
    ) -> [Row] {
        rows.filter { revision($0) != revisionID }
    }
}

/// 一筆交易的付款與分攤明細是否自洽。
///
/// 這是純值判斷，不碰 Core Data：同一組數字在任何裝置上都必須得到相同結論，
/// 而「同步到一半」與「真的對不起來」是兩種完全不同的處置，不能混為一談。
enum EntryConsistency: Equatable, Sendable {
    /// 這種交易本來就沒有付款與分攤明細（轉帳、餘額調整），或交易已作廢。
    case notApplicable
    /// 付款合計與分攤合計都等於交易金額。
    case balanced
    /// 明細還沒到齊。共享 store 會分別匯入交易與它的明細，剛同步過來的交易短暫處於
    /// 這個狀態是正常的；一直停在這裡才是問題。
    case awaitingDetails
    /// 明細在，但金額對不起來。這種交易不能拿去算結算，只能由使用者重新編輯。
    case mismatched(paymentTotal: Decimal, splitTotal: Decimal)

    var isBalanced: Bool { self == .balanced }
}

extension EntryConsistency {
    /// - Parameters:
    ///   - paymentAmounts: 已經過 `EntryRevision.live` 篩選的付款金額。
    ///   - splitAmounts: 同上，分攤金額。
    ///   - isVoided: 作廢交易的 `amount` 被歸零、明細卻保留原值，用它比對必然對不上；
    ///     原始金額留在稽核快照裡，這裡不重算。
    static func evaluate(
        kind: EntryKind,
        amount: Decimal,
        paymentAmounts: [Decimal],
        splitAmounts: [Decimal],
        currencyCode: String,
        isVoided: Bool = false
    ) -> EntryConsistency {
        guard !isVoided, kind == .expense || kind == .income else { return .notApplicable }
        guard !paymentAmounts.isEmpty, !splitAmounts.isEmpty else { return .awaitingDetails }

        let paymentTotal = paymentAmounts.reduce(Decimal.zero, +)
        let splitTotal = splitAmounts.reduce(Decimal.zero, +)

        // 比較一律在最小單位上做，理由與分攤、結算相同：`Decimal` 的等值比較會被
        // 不同裝置寫入的尾數影響。任何一個數字的精度不合法時就退回直接比較，
        // 那種資料本來就會在別處被擋下來，這裡只要不誤判成 balanced。
        guard let expected = LedgerCurrency.minorUnits(amount, currencyCode: currencyCode),
              let paid = LedgerCurrency.minorUnits(paymentTotal, currencyCode: currencyCode),
              let split = LedgerCurrency.minorUnits(splitTotal, currencyCode: currencyCode)
        else {
            return paymentTotal == amount && splitTotal == amount
                ? .balanced
                : .mismatched(paymentTotal: paymentTotal, splitTotal: splitTotal)
        }

        return paid == expected && split == expected
            ? .balanced
            : .mismatched(paymentTotal: paymentTotal, splitTotal: splitTotal)
    }
}
