import Foundation

/// 只用來定位 App bundle 的錨點。
///
/// `Bundle.main` 在單元測試裡指向的是 test host，看起來剛好也是這個 App，但那是
/// 目前的 `TEST_HOST` 設定帶來的巧合。用 App target 裡的型別去問 bundle，不論之後
/// 測試怎麼掛都會拿到真正放著 catalog 的那一個。
private final class LedgerLocalizationAnchor {}

/// String Catalog 的查詢入口。
///
/// 所有使用者可見文字都經過這裡，理由是 `locale` 必須可以被指定：文案的正確性只有
/// 在「同一段程式在兩種語言下各跑一次」時才驗得出來，而 `NSLocalizedString` 只能拿
/// 到執行當下的系統語言。
enum LedgerLocalization {
    static let table = "Localizable"

    /// catalog 所在的 bundle。
    static var bundle: Bundle { Bundle(for: LedgerLocalizationAnchor.self) }

    /// App 實際附帶的語言，`Base` 不算在內。
    static var availableLanguages: [String] {
        bundle.localizations.filter { $0 != "Base" }.sorted()
    }

    static func string(_ key: LedgerStringKey, locale: Locale? = nil) -> String {
        string(key, arguments: [], locale: locale)
    }

    /// 帶參數的文案。
    ///
    /// 參數一律走 `String(format:)` 而不是字串串接：語序在不同語言會變，
    /// catalog 裡的 `%1$@`、`%2$@` 讓譯者能自由調換位置。複數規則也在這一層生效，
    /// 因為 `.stringsdict` 是在同一次查表裡被解析的。
    ///
    /// 驅動複數的數字在 catalog 裡寫成 `%lld`，對應的參數要傳 `Int64`。目前支援的
    /// 裝置上 `Int` 就是 64 位元，但 `String(format:)` 是 varargs，型別對不上不會有
    /// 編譯錯誤可以擋，所以在呼叫端就轉好，不留這個假設。
    static func string(
        _ key: LedgerStringKey,
        arguments: [CVarArg],
        locale: Locale? = nil
    ) -> String {
        let format = resolvedBundle(for: locale).localizedString(
            forKey: key.rawValue,
            value: key.rawValue,
            table: table
        )
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: locale ?? .current, arguments: arguments)
    }

    // MARK: - Bundle resolution

    private static let cacheLock = NSLock()
    private static var localizedBundles: [String: Bundle] = [:]

    /// 指定語言時改查該語言的 `.lproj`；查不到就退回主 bundle，讓文案至少以開發語言
    /// 顯示，而不是掉成鍵名。
    private static func resolvedBundle(for locale: Locale?) -> Bundle {
        guard let locale else { return bundle }

        let identifier = locale.identifier
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if let cached = localizedBundles[identifier] {
            return cached
        }

        let base = bundle
        let preferred = Bundle.preferredLocalizations(
            from: base.localizations,
            forPreferences: [identifier]
        )
        let resolved = preferred.first
            .flatMap { base.path(forResource: $0, ofType: "lproj") }
            .flatMap { Bundle(path: $0) }
            ?? base
        localizedBundles[identifier] = resolved
        return resolved
    }
}

extension LedgerStringKey {
    /// SwiftUI 用的資源。`Text`、`Label` 會自己跟著環境語言重新解析。
    var resource: LocalizedStringResource {
        LocalizedStringResource(
            String.LocalizationValue(stringLiteral: rawValue),
            table: LedgerLocalization.table,
            bundle: .atURL(LedgerLocalization.bundle.bundleURL)
        )
    }

    /// 非 UI 情境（通知內容、匯出欄位、錯誤訊息）用的純字串。
    func string(locale: Locale? = nil) -> String {
        LedgerLocalization.string(self, locale: locale)
    }

    func string(arguments: [CVarArg], locale: Locale? = nil) -> String {
        LedgerLocalization.string(self, arguments: arguments, locale: locale)
    }
}
