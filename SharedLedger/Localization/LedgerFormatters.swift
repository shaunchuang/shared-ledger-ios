import Foundation

/// 日期、時間與百分比的顯示格式。
///
/// 金額不在這裡：金額的精度由帳本保存的幣別決定，不是由裝置地區決定，那一整套規則
/// 屬於 `LedgerCurrency`。這裡處理的是另一半——同一個時間點或同一個比例，在不同語言
/// 與地區要用當地的寫法呈現。
///
/// 集中的理由和 `LedgerLocalization` 一樣：`locale` 必須能被指定，否則「日期在英文
/// 介面下長什麼樣」只能靠改系統語言用眼睛看。
enum LedgerFormatters {
    /// 日期加時間，例如最後同步時間。
    static func timestamp(_ date: Date, locale: Locale? = nil) -> String {
        format(date, style: Date.FormatStyle(date: .abbreviated, time: .shortened), locale: locale)
    }

    /// 只有日期，列表與明細用。
    static func day(_ date: Date, locale: Locale? = nil) -> String {
        format(date, style: Date.FormatStyle(date: .abbreviated, time: .omitted), locale: locale)
    }

    /// 完整日期，交易詳情這類單筆畫面用。
    static func longDay(_ date: Date, locale: Locale? = nil) -> String {
        format(date, style: Date.FormatStyle(date: .long, time: .omitted), locale: locale)
    }

    /// 年月，報表與月份分組的標題。
    static func month(_ date: Date, locale: Locale? = nil) -> String {
        let style = Date.FormatStyle().year().month(.wide)
        return format(date, style: style, locale: locale)
    }

    /// 百分比。
    ///
    /// 傳入的是比例本身（0.123），不是已經乘過 100 的數字——小數點符號與百分號的
    /// 位置在不同語言並不一致，交給 `FormatStyle` 才會對。
    static func percent(_ share: Decimal, locale: Locale? = nil) -> String {
        let style = Decimal.FormatStyle.Percent.percent.precision(.fractionLength(1))
        return share.formatted(locale.map { style.locale($0) } ?? style)
    }

    private static func format(
        _ date: Date,
        style: Date.FormatStyle,
        locale: Locale?
    ) -> String {
        date.formatted(locale.map { style.locale($0) } ?? style)
    }
}
