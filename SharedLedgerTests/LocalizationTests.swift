import XCTest
@testable import SharedLedger

/// String Catalog 的完整性測試。
///
/// 這些測試看的是「編出來的 bundle」而不是原始的 `.xcstrings`：漏翻、鍵名寫錯、
/// catalog 沒被編進 target、複數規則沒生效，這幾種問題在原始檔上都看不出來，
/// 但全部會在查表時原形畢露。
final class LocalizationTests: XCTestCase {
    private static let requiredLanguages = ["zh-Hant", "en"]

    private var appBundle: Bundle { LedgerLocalization.bundle }

    // MARK: - Catalog 有沒有被編進來

    func testBothSupportedLanguagesAreShipped() {
        let available = Set(LedgerLocalization.availableLanguages)
        for language in Self.requiredLanguages {
            XCTAssertTrue(
                available.contains(language),
                "App bundle 少了 \(language)，catalog 可能沒加進 target 或 knownRegions"
            )
        }
    }

    // MARK: - 每個鍵都翻完了

    func testEveryKeyIsTranslatedInEveryLanguage() throws {
        for language in Self.requiredLanguages {
            let locale = Locale(identifier: language)
            for key in LedgerStringKey.allCases {
                let value = key.string(locale: locale)
                let context = "\(key.rawValue) / \(language)"

                XCTAssertFalse(value.isEmpty, context)
                // 查不到的鍵會原封不動掉出鍵名，那是漏翻最常見的長相。
                XCTAssertNotEqual(value, key.rawValue, context)
            }
        }
    }

    func testCatalogAndKeyRegistryDescribeTheSameStrings() throws {
        let registry = Set(LedgerStringKey.allCases.map(\.rawValue))
        for language in Self.requiredLanguages {
            let catalog = try catalogKeys(for: language)

            XCTAssertTrue(
                catalog.subtracting(registry).isEmpty,
                "\(language) catalog 有沒登記在 LedgerStringKey 的鍵："
                    + "\(catalog.subtracting(registry).sorted())"
            )
            XCTAssertTrue(
                registry.subtracting(catalog).isEmpty,
                "\(language) catalog 少了這些鍵：\(registry.subtracting(catalog).sorted())"
            )
        }
    }

    // MARK: - 兩種語言的參數必須對得起來

    func testFormatSpecifiersMatchAcrossLanguages() throws {
        // 參數數量或位置在兩種語言對不上時，`String(format:)` 會讀到不存在的參數
        // 而當掉。這是在地化最容易造成 crash 的一種錯，而且只會在切到該語言時發生。
        let zhFormats = try formats(for: "zh-Hant")
        let enFormats = try formats(for: "en")

        for (key, zhFormat) in zhFormats {
            guard let enFormat = enFormats[key] else { continue }
            XCTAssertEqual(
                specifiers(in: zhFormat),
                specifiers(in: enFormat),
                "\(key) 兩種語言的參數對不上：\(zhFormat) / \(enFormat)"
            )
        }
    }

    func testTranslationsAreNotCopiedFromTheSourceLanguage() throws {
        // 產品名稱與格式縮寫在兩種語言本來就一樣，其餘一律視為漏翻。
        let sharedByDesign: Set<String> = [
            LedgerStringKey.settingsRowExportDetail.rawValue,
            // 「來源 → 目的」只有一個箭頭與兩個參數，兩種語言沒有不同的寫法。
            LedgerStringKey.transactionRowTransferRoute.rawValue
        ]
        for key in LedgerStringKey.allCases where !sharedByDesign.contains(key.rawValue) {
            let zh = key.string(locale: Locale(identifier: "zh-Hant"))
            let en = key.string(locale: Locale(identifier: "en"))

            // 複數字串不帶參數查回來的是 `.stringsdict` 的替換符（`%#@value@`），
            // 兩種語言本來就一模一樣，比它等於什麼都沒比。這些鍵的實際文案由
            // testPluralRulesApplyInEnglish 與通知內文的測試逐句比對。
            guard !zh.contains("#@") else { continue }

            XCTAssertNotEqual(zh, en, "\(key.rawValue) 兩種語言相同，可能只是把原文複製過去")
        }
    }

    // MARK: - 複數與參數

    func testPluralRulesApplyInEnglish() {
        // 中文沒有單複數變化，所以 catalog 的 plural variation 有沒有真的編成
        // `.stringsdict`，只有英文驗得出來。
        let english = Locale(identifier: "en")
        let one = LedgerStringKey.notificationRowSummaryPartial
            .string(arguments: [Int64(1)], locale: english)
        let many = LedgerStringKey.notificationRowSummaryPartial
            .string(arguments: [Int64(3)], locale: english)

        XCTAssertEqual(one, "1 type on")
        XCTAssertEqual(many, "3 types on")

        // 正體中文只有 `other` 一種形式，但仍要確認它真的被代換、而不是掉出替換符。
        let zhHant = Locale(identifier: "zh-Hant")
        XCTAssertEqual(
            LedgerStringKey.notificationRowSummaryPartial
                .string(arguments: [Int64(1)], locale: zhHant),
            "已開啟 1 項"
        )
        XCTAssertEqual(
            LedgerStringKey.notificationRowSummaryPartial
                .string(arguments: [Int64(3)], locale: zhHant),
            "已開啟 3 項"
        )
    }

    func testTransactionCountsUseEachLanguagesPluralRules() {
        let english = Locale(identifier: "en")
        XCTAssertEqual(
            LedgerStringKey.transactionResultCount.string(arguments: [Int64(1)], locale: english),
            "1 transaction"
        )
        XCTAssertEqual(
            LedgerStringKey.transactionResultCount.string(arguments: [Int64(4)], locale: english),
            "4 transactions"
        )

        let zhHant = Locale(identifier: "zh-Hant")
        XCTAssertEqual(
            LedgerStringKey.transactionResultCount.string(arguments: [Int64(4)], locale: zhHant),
            "4 筆"
        )
    }

    func testTwoArgumentFormatsSubstituteBothPositions() {
        // 兩個參數的字串在中文是「符合 A／B 筆」、在英文是「A of B match」，位置不同。
        // 位置代換一旦壞掉，這種字串不是顯示錯誤而是直接讀到不存在的參數。
        for language in Self.requiredLanguages {
            let text = LedgerStringKey.transactionResultMatchCount.string(
                arguments: [Int64(3), Int64(12)],
                locale: Locale(identifier: language)
            )
            XCTAssertTrue(text.contains("3"), "\(language)：\(text)")
            XCTAssertTrue(text.contains("12"), "\(language)：\(text)")
            XCTAssertFalse(text.contains("%"), "\(language) 還有沒代換掉的參數：\(text)")
        }
    }

    func testSplitModeNamesComeFromTheCatalog() {
        // 分攤方式同時出現在交易表單與 CSV 匯出；匯出固定用正體中文，畫面跟著使用者
        // 語言，兩邊都必須查得到。
        XCTAssertEqual(
            SplitMode.fixedAmount.displayNameKey.string(locale: Locale(identifier: "zh-Hant")),
            "指定金額"
        )
        XCTAssertEqual(
            SplitMode.fixedAmount.displayNameKey.string(locale: Locale(identifier: "en")),
            "Fixed amount"
        )
    }

    func testArgumentsAreSubstitutedInBothLanguages() {
        for language in Self.requiredLanguages {
            let locale = Locale(identifier: language)
            let text = LedgerStringKey.notificationBodyTransactionCreated.string(
                arguments: ["小美", "家庭"],
                locale: locale
            )
            XCTAssertTrue(text.contains("小美"), language)
            XCTAssertTrue(text.contains("家庭"), language)
            XCTAssertFalse(text.contains("%"), "\(language) 還有沒代換掉的參數：\(text)")
        }
    }

    // MARK: - 由 locale 決定寫法的欄位

    func testCurrencyDisplayNameUsesEachLanguagesPunctuation() {
        // 全形括號在英文介面裡是錯的，這種細節不會有人回報，只會看起來很業餘。
        let zh = LedgerCurrency.displayName(for: "TWD", locale: Locale(identifier: "zh-Hant"))
        let en = LedgerCurrency.displayName(for: "TWD", locale: Locale(identifier: "en"))

        XCTAssertTrue(zh.contains("（TWD）"), zh)
        XCTAssertTrue(en.contains("(TWD)"), en)
    }

    func testPercentagesFollowTheLocale() {
        // 小數點符號不是每個地區都是句點。
        let share = Decimal(string: "0.1234") ?? 0
        XCTAssertEqual(LedgerFormatters.percent(share, locale: Locale(identifier: "en_US")), "12.3%")
        XCTAssertTrue(
            LedgerFormatters.percent(share, locale: Locale(identifier: "de_DE")).contains(","),
            "德文地區應該用逗號當小數點"
        )
    }

    func testInfoPlistStringsAreLocalized() throws {
        for language in Self.requiredLanguages {
            let bundle = try languageBundle(for: language)
            let value = bundle.localizedString(
                forKey: "NSContactsUsageDescription",
                value: "",
                table: "InfoPlist"
            )
            XCTAssertFalse(
                value.isEmpty,
                "\(language) 少了聯絡人權限說明，系統對話框會顯示開發語言的文案"
            )
        }
    }

    // MARK: - Helpers

    private func languageBundle(for language: String) throws -> Bundle {
        let path = try XCTUnwrap(
            appBundle.path(forResource: language, ofType: "lproj"),
            "找不到 \(language).lproj"
        )
        return try XCTUnwrap(Bundle(path: path))
    }

    /// 編出來的鍵集合。複數字串會被編到 `.stringsdict`，兩邊都要看。
    private func catalogKeys(for language: String) throws -> Set<String> {
        let bundle = try languageBundle(for: language)
        var keys = Set<String>()
        for ext in ["strings", "stringsdict"] {
            guard let url = bundle.url(forResource: "Localizable", withExtension: ext),
                  let contents = NSDictionary(contentsOf: url) as? [String: Any] else {
                continue
            }
            keys.formUnion(contents.keys)
        }
        return keys
    }

    /// 只取 `.strings` 裡的格式字串：複數的格式散在 `.stringsdict` 的巢狀規則裡，
    /// 參數比對交給 `testPluralRulesApplyInEnglish` 這類實際代換的測試。
    private func formats(for language: String) throws -> [String: String] {
        let bundle = try languageBundle(for: language)
        guard let url = bundle.url(forResource: "Localizable", withExtension: "strings"),
              let contents = NSDictionary(contentsOf: url) as? [String: String] else {
            return [:]
        }
        return contents
    }

    private func specifiers(in format: String) -> [String] {
        let pattern = "%(?:(\\d+)\\$)?[-+ #0]*[0-9]*(?:\\.[0-9]+)?(?:ll|l|h|hh|z|q)?([@dioufFeEgGxXscpaA])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(format.startIndex..<format.endIndex, in: format)
        return regex.matches(in: format, range: range)
            .compactMap { match -> String? in
                guard let conversion = Range(match.range(at: 2), in: format) else { return nil }
                let position = Range(match.range(at: 1), in: format).map { String(format[$0]) } ?? ""
                return position + String(format[conversion])
            }
            .sorted()
    }
}
