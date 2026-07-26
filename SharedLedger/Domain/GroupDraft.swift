import Foundation

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

    static func format(
        _ amount: Decimal,
        currencyCode: String,
        locale: Locale = .current,
        showPositiveSign: Bool = false
    ) -> String {
        let code = normalizedCode(currencyCode)
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.minimumFractionDigits = fractionDigits(for: code)
        formatter.maximumFractionDigits = fractionDigits(for: code)
        let formatted = formatter.string(from: amount as NSDecimalNumber)
            ?? "\(code) \((amount as NSDecimalNumber).stringValue)"
        return showPositiveSign && amount > 0 ? "+" + formatted : formatted
    }
}

struct InviteeContact: Identifiable, Equatable, Sendable {
    let contactIdentifier: String
    let displayName: String

    var id: String { contactIdentifier }
}

struct GroupDraft: Equatable, Sendable {
    var name = ""
    var ownerDisplayName = "我"
    var currencyCode = LedgerCurrency.defaultCode
    var invitees: [InviteeContact] = []

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedOwnerDisplayName: String {
        ownerDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedCurrencyCode: String {
        LedgerCurrency.normalizedCode(currencyCode)
    }

    var canCreate: Bool {
        !trimmedName.isEmpty && !trimmedOwnerDisplayName.isEmpty
    }

    mutating func addInvitees(_ contacts: [InviteeContact]) {
        var identifiers = Set(invitees.map(\.contactIdentifier))
        for contact in contacts where identifiers.insert(contact.contactIdentifier).inserted {
            invitees.append(contact)
        }
    }
}

