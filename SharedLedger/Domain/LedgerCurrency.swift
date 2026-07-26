import Foundation

/// 群組貨幣的唯一權威：精度、四捨五入、最小單位換算與顯示格式都由這裡決定。
///
/// 帳本會跨裝置同步，任何「這個金額合不合法」「尾差怎麼分」的判斷都必須在所有裝置
/// 上得到相同結果，因此分攤、結算與 repository 一律共用這裡的實作，不各自複製一份
/// 換算邏輯。
enum LedgerCurrency {
    static let fallbackCode = "TWD"

    static var defaultCode: String {
        normalizedCode(Locale.current.currency?.identifier)
    }

    static var supportedCodes: [String] {
        Locale.commonISOCurrencyCodes.sorted {
            displayName(for: $0) < displayName(for: $1)
        }
    }

    static func normalizedCode(_ code: String?) -> String {
        guard let code else { return fallbackCode }
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return Locale.commonISOCurrencyCodes.contains(normalized) ? normalized : fallbackCode
    }

    static func displayName(for code: String, locale: Locale = .current) -> String {
        let normalized = normalizedCode(code)
        guard let name = locale.localizedString(forCurrencyCode: normalized) else {
            return normalized
        }
        return "\(name)（\(normalized)）"
    }

    /// App 自行釘住的幣別最小單位。
    ///
    /// `NumberFormatter` 的精度來自作業系統的 ICU/CLDR 資料，會隨系統版本改變。
    /// 帳本會跨裝置同步，同一筆金額不能因為兩台裝置的 iOS 版本不同就有不同的
    /// 合法性判定、四捨五入結果與分攤餘數，所以實際慣例與 ISO 不同的幣別在這裡
    /// 明確指定。未列出的幣別仍沿用系統的 ISO 精度。
    ///
    /// TWD：ISO 4217 記為 2 位，但台幣實務以整數元計價，App 也照此處理。
    private static let fractionDigitOverrides: [String: Int] = [
        "TWD": 0
    ]

    static func fractionDigits(for code: String) -> Int {
        let normalized = normalizedCode(code)
        if let override = fractionDigitOverrides[normalized] {
            return override
        }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencyCode = normalized
        return formatter.maximumFractionDigits
    }

    static func rounded(
        _ amount: Decimal,
        currencyCode: String,
        mode: NSDecimalNumber.RoundingMode = .plain
    ) -> Decimal {
        var result = Decimal()
        var mutableAmount = amount
        NSDecimalRound(
            &result,
            &mutableAmount,
            fractionDigits(for: currencyCode),
            mode
        )
        return result
    }

    static func isValidAmount(_ amount: Decimal, currencyCode: String) -> Bool {
        rounded(amount, currencyCode: currencyCode) == amount
    }

    /// 把金額換算成該幣別最小單位的整數，金額精度不合法時回傳 `nil`。
    ///
    /// 分攤與結算都以整數最小單位運算，避免 `Decimal` 除法在不同裝置上產生不同的
    /// 尾差。呼叫端負責把 `nil` 轉成自己的錯誤型別。
    static func minorUnits(_ amount: Decimal, currencyCode: String) -> Int64? {
        guard isValidAmount(amount, currencyCode: currencyCode) else { return nil }
        let digits = fractionDigits(for: currencyCode)
        return NSDecimalNumber(decimal: amount)
            .multiplying(byPowerOf10: Int16(digits))
            .int64Value
    }

    static func amount(fromMinorUnits units: Int64, currencyCode: String) -> Decimal {
        let digits = fractionDigits(for: currencyCode)
        return NSDecimalNumber(value: units)
            .multiplying(byPowerOf10: -Int16(digits))
            .decimalValue
    }

    static func format(
        _ amount: Decimal,
        currencyCode: String,
        locale: Locale = .current,
        showPositiveSign: Bool = false
    ) -> String {
        let code = normalizedCode(currencyCode)
        // fractionDigits(for:) builds a NumberFormatter for any currency without an
        // override, and this runs for every amount in a list, so resolve it once.
        let digits = fractionDigits(for: code)
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        let formatted = formatter.string(from: amount as NSDecimalNumber)
            ?? "\(code) \((amount as NSDecimalNumber).stringValue)"
        return showPositiveSign && amount > 0 ? "+" + formatted : formatted
    }

    /// 依交易種類決定金額在畫面上的正負號，讓交易列表、交易明細與總覽報表對同一筆
    /// 交易顯示完全一致的字串。
    ///
    /// 收入固定顯示 `+`、支出固定顯示 `-`，因此傳入值本身的正負號不影響結果；轉帳
    /// 只顯示金額大小，方向由畫面上的來源／目的帳戶表達；餘額調整可能是調高或調低，
    /// 所以保留原始正負號並標示符號。
    static func formatSigned(
        _ amount: Decimal,
        kind: EntryKind,
        currencyCode: String
    ) -> String {
        let magnitude = amount < 0 ? -amount : amount
        switch kind {
        case .income:
            return format(magnitude, currencyCode: currencyCode, showPositiveSign: true)
        case .expense:
            return format(-magnitude, currencyCode: currencyCode)
        case .transfer:
            return format(magnitude, currencyCode: currencyCode)
        case .balanceAdjustment:
            return format(amount, currencyCode: currencyCode, showPositiveSign: true)
        }
    }
}
