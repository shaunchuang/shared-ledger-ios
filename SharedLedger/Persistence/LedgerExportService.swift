import CoreData
import Foundation

/// 一份可以直接寫成檔案或分享出去的匯出文件。
struct LedgerExportDocument: Identifiable, Equatable, Sendable {
    var id: String { fileName }
    let fileName: String
    let contents: String
}

/// 匯出要涵蓋的內容。
struct LedgerExportRequest: Equatable, Sendable {
    var scope: ReportBookScope = .currentBook
    var selectedBookIDs: Set<UUID> = []
    var startDate: Date?
    var endDate: Date?
    /// 作廢交易預設不匯出。要拿匯出檔對帳時才打開，且會另外標示狀態。
    var includesVoided = false
    var includesAccounts = true
    var includesSettlements = true
}

struct LedgerExportSummary: Sendable {
    let documents: [LedgerExportDocument]
    let transactionCount: Int
    let includedBookNames: [String]

    var isEmpty: Bool { documents.isEmpty }

    static let empty = LedgerExportSummary(
        documents: [],
        transactionCount: 0,
        includedBookNames: []
    )
}

/// 把群組帳務輸出成 CSV。
///
/// 交易的篩選完全交給 `TransactionSearchService`：帳本範圍、日期界線與作廢判定
/// 只能有一份定義，否則匯出檔會和使用者在交易畫面看到的內容對不起來——而匯出檔
/// 的用途正是拿去對帳。
@MainActor
struct LedgerExportService {
    private let persistence: PersistenceController
    private let calendar: Calendar
    /// 建立一次就重複使用。日期欄位是逐列產生的，每一列都新建一個 `DateFormatter`
    /// 會把它的初始化成本乘上交易筆數，而匯出正是一次要跑完整份帳本的操作。
    private let dayFormatter: DateFormatter
    private let timestampFormatter: DateFormatter

    init(persistence: PersistenceController = .shared, calendar: Calendar = .current) {
        self.persistence = persistence
        self.calendar = calendar
        // 固定 POSIX locale 與 ISO 格式，匯出檔的意義才不會隨開檔者的地區設定改變。
        dayFormatter = Self.formatter(format: "yyyy-MM-dd", timeZone: calendar.timeZone)
        timestampFormatter = Self.formatter(format: "yyyy-MM-dd HH:mm", timeZone: calendar.timeZone)
    }

    private static func formatter(format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    func export(
        in group: LedgerGroup,
        request: LedgerExportRequest,
        currentBook: LedgerBook?
    ) -> LedgerExportSummary {
        var query = TransactionQuery()
        query.startDate = request.startDate
        query.endDate = request.endDate
        query.includesVoided = request.includesVoided

        let result = TransactionSearchService(persistence: persistence, calendar: calendar).results(
            in: group,
            query: query,
            scope: request.scope,
            currentBook: currentBook,
            selectedBookIDs: request.selectedBookIDs
        )
        let entries = result.sections.flatMap(\.entries)
        let includedBooks = BookRepository(persistence: persistence).books(
            in: group,
            scope: request.scope,
            currentBook: currentBook,
            selectedBookIDs: request.selectedBookIDs
        )
        let currencyCode = LedgerCurrency.normalizedCode(group.currencyCode)
        let prefix = fileNamePrefix(for: group)

        var documents = [
            LedgerExportDocument(
                fileName: fileName(prefix: prefix, kind: .exportFileTransactions),
                contents: transactionsDocument(
                    entries: entries,
                    voidedEntryIDs: result.voidedEntryIDs,
                    currencyCode: currencyCode
                )
            )
        ]

        if request.includesAccounts {
            documents.append(
                LedgerExportDocument(
                    fileName: fileName(prefix: prefix, kind: .exportFileAccounts),
                    contents: accountsDocument(in: group, currencyCode: currencyCode)
                )
            )
        }

        if request.includesSettlements {
            documents.append(
                LedgerExportDocument(
                    fileName: fileName(prefix: prefix, kind: .exportFileSettlements),
                    contents: settlementsDocument(books: includedBooks, currencyCode: currencyCode)
                )
            )
        }

        return LedgerExportSummary(
            documents: documents,
            transactionCount: entries.count,
            includedBookNames: includedBooks.map {
                $0.name ?? LedgerStringKey.commonPlaceholderUnnamedBook.string()
            }
        )
    }

    // MARK: - 交易

    private func transactionsDocument(
        entries: [LedgerEntry],
        voidedEntryIDs: Set<UUID>,
        currencyCode: String
    ) -> String {
        let header = [
            LedgerStringKey.exportColumnBook,
            .exportColumnDate,
            .exportColumnKind,
            .exportColumnCategory,
            .exportColumnAmount,
            .exportColumnCurrency,
            .exportColumnSourceAccount,
            .exportColumnDestinationAccount,
            .exportColumnPayments,
            .exportColumnSplitMode,
            .exportColumnSplits,
            .exportColumnNote,
            .exportColumnStatus,
            .exportColumnEntryID
        ].map { $0.string() }
        let rows = entries.map { entry -> [CSVValue] in
            let kind = entry.kind.flatMap(EntryKind.init(rawValue:)) ?? .expense
            let amount = (entry.amount as Decimal?) ?? 0
            let isVoided = entry.id.map(voidedEntryIDs.contains) == true
            return [
                .text(entry.book?.name ?? LedgerStringKey.commonPlaceholderUnnamedBook.string()),
                .generated(entry.date.map(isoDay) ?? ""),
                .generated(kind.displayName),
                .text(entry.category?.name
                    ?? LedgerStringKey.transactionFormCategoryNone.string()),
                // 匯出的是可再計算的原始數值，不是畫面上的貨幣字串：帶著貨幣符號與
                // 千分位的欄位在試算表裡是文字，沒辦法直接加總。
                .generated(decimalString(amount)),
                .generated(currencyCode),
                .text(entry.sourceAccount?.name ?? ""),
                .text(entry.destinationAccount?.name ?? ""),
                .text(paymentDetail(of: entry)),
                .generated(splitMode(of: entry).displayName),
                .text(splitDetail(of: entry)),
                .text(entry.note ?? ""),
                .generated(statusText(isVoided ? .exportStatusVoided : .exportStatusActive)),
                .generated(entry.id?.uuidString ?? "")
            ]
        }
        return CSVWriter.document(header: header, rows: rows)
    }

    /// 付款人與分攤成員都是一對多，攤平成 `姓名:金額` 並以分號相接。
    /// 同一欄裡不用逗號，是為了讓這一欄在任何試算表裡都維持單一欄位。
    private func paymentDetail(of entry: LedgerEntry) -> String {
        let payments = (entry.payments as? Set<EntryPayment> ?? [])
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                return (lhs.member?.displayName ?? "") < (rhs.member?.displayName ?? "")
            }
        if payments.isEmpty {
            // V7 之前只有單一 payer，尚未跑完遷移的裝置仍要匯得出付款人。
            guard let payer = entry.payer?.displayName else { return "" }
            return "\(payer):\(decimalString((entry.amount as Decimal?) ?? 0))"
        }
        return payments
            .map { detailPair(for: $0.member, amount: ($0.amount as Decimal?) ?? 0) }
            .joined(separator: ";")
    }

    private func splitDetail(of entry: LedgerEntry) -> String {
        (entry.splits as? Set<EntrySplit> ?? [])
            .sorted { ($0.member?.displayName ?? "") < ($1.member?.displayName ?? "") }
            .map { detailPair(for: $0.member, amount: ($0.amount as Decimal?) ?? 0) }
            .joined(separator: ";")
    }

    private func splitMode(of entry: LedgerEntry) -> SplitMode {
        SplitMode(rawValue: entry.splitMode ?? "") ?? .equal
    }

    // MARK: - 帳戶

    private func accountsDocument(in group: LedgerGroup, currencyCode: String) -> String {
        let header = [
            LedgerStringKey.exportColumnAccount,
            .exportColumnKind,
            .exportColumnOpeningBalance,
            .exportColumnCurrentBalance,
            .exportColumnCurrency,
            .exportColumnLastReconciledAt,
            .exportColumnStatus
        ].map { $0.string() }
        let repository = AccountRepository(persistence: persistence)
        let accounts = (group.accounts as? Set<LedgerAccount> ?? [])
            .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        let rows = accounts.map { account -> [CSVValue] in
            let type = account.accountType.flatMap(AccountType.init(rawValue:)) ?? .other
            return [
                .text(account.name ?? LedgerStringKey.commonPlaceholderUnnamedAccount.string()),
                .generated(type.displayName),
                .generated(decimalString((account.openingBalance as Decimal?) ?? 0)),
                // 帳戶餘額是整個群組範圍，不隨匯出的帳本範圍或日期區間改變，
                // 所以這份檔案不套用交易的篩選條件。
                .generated(decimalString(repository.currentBalance(for: account))),
                .generated(currencyCode),
                .generated(account.lastReconciledAt.map(isoDay) ?? ""),
                .generated(statusText(
                    account.archivedAt == nil ? .exportStatusInUse : .exportStatusArchived
                ))
            ]
        }
        return CSVWriter.document(header: header, rows: rows)
    }

    // MARK: - 結算

    private func settlementsDocument(books: [LedgerBook], currencyCode: String) -> String {
        let header = [
            LedgerStringKey.exportColumnBook,
            .exportColumnRecordedAt,
            .exportColumnPayer,
            .exportColumnRecipient,
            .exportColumnAmount,
            .exportColumnCurrency,
            .exportColumnNote,
            .exportColumnStatus
        ].map { $0.string() }
        let repository = SettlementRepository(persistence: persistence)
        let rows = books.flatMap { book -> [[CSVValue]] in
            let names = memberNames(in: book.group)
            return repository.history(in: book).map { item in
                [
                    .text(book.name ?? LedgerStringKey.commonPlaceholderUnnamedBook.string()),
                    .generated(isoTimestamp(item.recordedAt)),
                    .text(names[item.fromMemberID]
                        ?? LedgerStringKey.commonPlaceholderUnnamedMember.string()),
                    .text(names[item.toMemberID]
                        ?? LedgerStringKey.commonPlaceholderUnnamedMember.string()),
                    .generated(decimalString(item.amount)),
                    .generated(currencyCode),
                    .text(item.note),
                    .generated(statusText(
                        item.isReversed ? .exportStatusReversed : .exportStatusActive
                    ))
                ]
            }
        }
        return CSVWriter.document(header: header, rows: rows)
    }

    private func memberNames(in group: LedgerGroup?) -> [UUID: String] {
        let members = group?.members as? Set<Member> ?? []
        return Dictionary(uniqueKeysWithValues: members.compactMap { member in
            member.id.map {
                ($0, member.displayName
                    ?? LedgerStringKey.commonPlaceholderUnnamedMember.string())
            }
        })
    }

    // MARK: - 格式

    /// 金額一律輸出成不帶符號、不帶千分位的小數字串，讓試算表能直接當數字讀。
    private func decimalString(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    private func isoDay(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private func isoTimestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    /// 欄位標題、狀態值與檔名都跟著使用者的語言：整份檔案要嘛全中文、要嘛全英文，
    /// 不能是中文標題配英文內容。
    ///
    /// 代價是同一個群組在不同語言的裝置上匯出的欄位標題不同，未來要做 CSV 匯入時，
    /// 不能靠標題文字認欄位，得改用欄位順序或另外寫一行版本標記。
    private func statusText(_ key: LedgerStringKey) -> String {
        key.string()
    }

    private func fileName(prefix: String, kind: LedgerStringKey) -> String {
        "\(prefix)-\(kind.string()).csv"
    }

    private func detailPair(for member: Member?, amount: Decimal) -> String {
        let name = member?.displayName
            ?? LedgerStringKey.commonPlaceholderUnnamedMember.string()
        return "\(name):\(decimalString(amount))"
    }

    /// 檔名要能在檔案 App 裡一眼分辨來源與時間，同時避開路徑分隔字元。
    private func fileNamePrefix(for group: LedgerGroup) -> String {
        let name = (group.name ?? LedgerStringKey.exportFileGroupFallback.string())
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = name.isEmpty
            ? LedgerStringKey.exportFileGroupFallback.string()
            : name
        return "\(safeName)-\(isoDay(Date()))"
    }
}
