import XCTest
@testable import SharedLedger

final class CSVWriterTests: XCTestCase {
    func testPlainFieldsAreNotQuoted() {
        XCTAssertEqual(CSVWriter.escaped("餐飲"), "餐飲")
        XCTAssertEqual(CSVWriter.escaped("120"), "120")
    }

    func testFieldsWithSeparatorsOrQuotesAreQuoted() {
        XCTAssertEqual(CSVWriter.escaped("早餐, 午餐"), "\"早餐, 午餐\"")
        XCTAssertEqual(CSVWriter.escaped("他說「\"好\"」"), "\"他說「\"\"好\"\"」\"")
        XCTAssertEqual(CSVWriter.escaped("第一行\n第二行"), "\"第一行\n第二行\"")
        XCTAssertEqual(CSVWriter.escaped("回車\r"), "\"回車\r\"")
    }

    func testWindowsLineEndingsInsideAFieldAreQuoted() {
        // Swift 把 CRLF 當成單一 grapheme cluster，用字串比對找不到裡面的 CR 或 LF。
        // 漏掉引號會讓這個欄位把一列拆成兩列，整份檔案的欄位就全部錯位。
        let field = "第一行\r\n第二行"
        XCTAssertEqual(CSVWriter.escaped(field), "\"第一行\r\n第二行\"")

        let document = CSVWriter.document(header: ["備註"], rows: [[.text(field)]])
        let body = String(document.dropFirst(CSVWriter.byteOrderMark.count))
        XCTAssertEqual(body, "備註\r\n\"第一行\r\n第二行\"\r\n")
    }

    func testLeadingAndTrailingSpacesAreQuoted() {
        // 未加引號的前後空白會被試算表吃掉，匯出的名稱就和 App 裡不一致。
        XCTAssertEqual(CSVWriter.escaped(" 現金"), "\" 現金\"")
        XCTAssertEqual(CSVWriter.escaped("現金 "), "\"現金 \"")
    }

    func testUserTextThatLooksLikeAFormulaIsNeutralized() {
        // 分類名稱與備註會從其他成員同步過來，不能讓匯出檔在對方的試算表裡執行。
        XCTAssertEqual(CSVValue.text("=1+1").encoded, "'=1+1")
        XCTAssertEqual(CSVValue.text("+886").encoded, "'+886")
        XCTAssertEqual(CSVValue.text("@SUM(A1)").encoded, "'@SUM(A1)")
        XCTAssertEqual(
            CSVValue.text("=HYPERLINK(\"http://x\",\"y\")").encoded,
            "\"'=HYPERLINK(\"\"http://x\"\",\"\"y\"\")\""
        )
    }

    func testGeneratedValuesKeepTheirLeadingSign() {
        // 金額由 App 自己格式化，負號不能被當成公式前綴處理，否則每一筆負數
        // 在試算表裡都會變成不能計算的文字。
        XCTAssertEqual(CSVValue.generated("-1200").encoded, "-1200")
        XCTAssertEqual(CSVValue.generated("+50").encoded, "+50")
    }

    func testTextThatMerelyContainsAnOperatorIsUntouched() {
        XCTAssertEqual(CSVValue.text("A+B 早餐").encoded, "A+B 早餐")
        XCTAssertEqual(CSVValue.text("").encoded, "")
    }

    func testDocumentStartsWithByteOrderMarkAndUsesCRLF() {
        let document = CSVWriter.document(
            header: ["分類", "金額"],
            rows: [
                [.text("餐飲"), .generated("120")],
                [.text("交通"), .generated("30")]
            ]
        )

        XCTAssertTrue(document.hasPrefix(CSVWriter.byteOrderMark))
        let body = String(document.dropFirst(CSVWriter.byteOrderMark.count))
        XCTAssertEqual(body, "分類,金額\r\n餐飲,120\r\n交通,30\r\n")
    }

    func testDocumentWithNoRowsStillCarriesItsHeader() {
        let document = CSVWriter.document(header: ["分類", "金額"], rows: [])
        let body = String(document.dropFirst(CSVWriter.byteOrderMark.count))

        // 空匯出檔仍要看得出欄位，開檔的人才知道自己拿到的是什麼。
        XCTAssertEqual(body, "分類,金額\r\n")
    }
}
