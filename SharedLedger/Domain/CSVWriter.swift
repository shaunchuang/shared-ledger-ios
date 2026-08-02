import Foundation

/// 一個 CSV 欄位。
///
/// 分成使用者輸入與 App 產生兩種，是因為兩者的跳脫規則不同：使用者輸入要防公式
/// 注入，而金額、日期這類 App 自己格式化的值不能被動到——負數金額開頭就是 `-`，
/// 一律加上防護前綴會把每一筆支出都變成文字。
enum CSVValue: Equatable, Sendable {
    /// 使用者或其他群組成員輸入的文字：群組、帳本、帳戶、分類、成員名稱與備註。
    case text(String)
    /// App 自己產生的值，例如已格式化的金額、日期與識別碼。
    case generated(String)

    var encoded: String {
        switch self {
        case .text(let value): return CSVWriter.escaped(CSVWriter.neutralizingFormula(value))
        case .generated(let value): return CSVWriter.escaped(value)
        }
    }
}

/// 依 RFC 4180 產生 CSV。
enum CSVWriter {
    /// RFC 4180 規定的換行。Numbers 與 Excel 都接受 LF，但 CRLF 是規格本文，
    /// 也是舊版 Excel 唯一不會把整份檔案讀成一列的寫法。
    static let lineTerminator = "\r\n"

    /// UTF-8 BOM。少了它，Excel 會以系統預設編碼開啟，正體中文的欄位會全部變成
    /// 亂碼——匯出檔要能直接給人用，不能要求對方先手動指定編碼。
    static let byteOrderMark = "\u{FEFF}"

    static func document(header: [String], rows: [[CSVValue]]) -> String {
        let headerLine = header.map { escaped($0) }.joined(separator: ",")
        let bodyLines = rows.map { row in
            row.map(\.encoded).joined(separator: ",")
        }
        return byteOrderMark
            + ([headerLine] + bodyLines).joined(separator: lineTerminator)
            + lineTerminator
    }

    /// 需要時加上雙引號，並把內含的雙引號改成兩個。
    ///
    /// 前後空白也一併加引號：試算表會把未加引號的空白吃掉，讓匯出的名稱和 App 裡
    /// 看到的不一致。
    static func escaped(_ field: String) -> String {
        let needsQuoting = field.contains(",")
            || field.contains("\"")
            // 換行必須看 unicode scalar，不能用 `contains("\r")`：Swift 把 CRLF 當成
            // 單一 grapheme cluster，以字串比對找不到藏在裡面的 CR，帶著 Windows
            // 換行的備註就會漏掉引號、把一列拆成兩列。
            || field.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }
            || field.hasPrefix(" ")
            || field.hasSuffix(" ")
        guard needsQuoting else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// 讓試算表把使用者輸入當成文字，而不是公式。
    ///
    /// 帳本資料會透過 CloudKit 從其他成員同步過來，所以備註或分類名稱不完全在本人
    /// 掌控之中。以 `=`、`+`、`-`、`@` 或 tab 開頭的欄位，Excel 與 Google Sheets 會
    /// 直接當成公式執行，匯出檔一旦轉寄出去就成了別人的攻擊面。前綴一個單引號是
    /// 這兩個軟體都認得的「強制文字」寫法，顯示出來仍是原本的字。
    static func neutralizingFormula(_ field: String) -> String {
        guard let first = field.first, "=+-@\t\r".contains(first) else { return field }
        return "'" + field
    }
}
