import CoreData
import SwiftUI

struct TransactionsView: View {
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \LedgerGroup.updatedAt, ascending: false)],
        animation: .default
    ) private var groups: FetchedResults<LedgerGroup>

    @State private var selectedGroupID: NSManagedObjectID?

    private var selectedGroup: LedgerGroup? {
        if let selectedGroupID, let match = groups.first(where: { $0.objectID == selectedGroupID }) {
            return match
        }
        return groups.first
    }

    var body: some View {
        ZStack {
            LedgerBackground()
            if let group = selectedGroup {
                BookTransactionsView(
                    group: group,
                    groups: Array(groups),
                    selectedGroupID: $selectedGroupID
                )
                .id(group.objectID)
            } else {
                ScrollView {
                    LedgerEmptyState(
                        systemImage: "person.3",
                        title: "先建立一個群組",
                        message: "交易記錄屬於群組，請先到「設定」的「群組管理」建立群組，再回來新增交易。"
                    )
                    .padding(.horizontal, LedgerTheme.pagePadding)
                    .padding(.top, 24)
                }
            }
        }
        .navigationTitle("交易")
    }
}

/// Whether this device may add or change transactions in a group, and how to explain
/// it when it may not.
///
/// Resolving it walks the current member identity and, for a shared group, makes a
/// synchronous `fetchShares` call into the CloudKit mirroring metadata. The screens
/// below therefore cache it in `@State` and refresh it when the data behind it
/// changes, instead of recomputing it on every `body` pass.
private struct TransactionWriteAccess {
    /// Writes are refused until the first resolution, and nothing is explained yet:
    /// a notice for a state nobody has checked would flash the wrong message on the
    /// frame before `onAppear` runs.
    static let unresolved = TransactionWriteAccess(restriction: .missingCurrentMember, isResolved: false)

    let restriction: PermissionError?
    let isResolved: Bool

    init(restriction: PermissionError?, isResolved: Bool = true) {
        self.restriction = restriction
        self.isResolved = isResolved
    }

    var canWrite: Bool { isResolved && restriction == nil }
    var noticeMessage: String? { isResolved ? restriction?.errorDescription : nil }
}

private struct BookTransactionsView: View {
    /// 交易類型的快速切換。搜尋面板不再重複提供類型選擇，讓 `query.kinds` 只有
    /// 這一個入口，畫面上就不會出現兩個彼此矛盾的類型狀態。
    private enum Filter: String, CaseIterable, Identifiable {
        case all = "全部"
        case expense = "支出"
        case income = "收入"
        case transfer = "轉帳"

        var id: Self { self }

        var kinds: Set<EntryKind> {
            switch self {
            case .all: return []
            case .expense: return [.expense]
            case .income: return [.income]
            case .transfer: return [.transfer]
            }
        }

        static func matching(_ kinds: Set<EntryKind>) -> Filter {
            allCases.first { $0.kinds == kinds } ?? .all
        }
    }

    @ObservedObject var group: LedgerGroup
    let groups: [LedgerGroup]
    @Binding var selectedGroupID: NSManagedObjectID?

    @Environment(\.managedObjectContext) private var context

    /// 候選交易以群組為範圍取一次，帳本範圍與其他條件都交給搜尋服務收斂。範圍可以
    /// 在單一帳本與跨帳本之間切換，逐帳本的 fetch 會在每次切換時重建整個請求。
    @FetchRequest private var entries: FetchedResults<LedgerEntry>

    @AppStorage private var selectedBookID: String
    @State private var query = TransactionQuery()
    @State private var scope: ReportBookScope = .currentBook
    @State private var selectedCustomBookIDs: Set<UUID> = []
    @State private var result = TransactionSearchResult.empty
    @State private var isPresentingNewEntry = false
    @State private var isPresentingFilters = false
    @State private var writeAccess = TransactionWriteAccess.unresolved

    init(
        group: LedgerGroup,
        groups: [LedgerGroup],
        selectedGroupID: Binding<NSManagedObjectID?>
    ) {
        self.group = group
        self.groups = groups
        _selectedGroupID = selectedGroupID
        _selectedBookID = AppStorage(
            wrappedValue: "",
            BookSelectionStorage.key(for: group)
        )
        _entries = FetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \LedgerEntry.date, ascending: false)],
            predicate: NSPredicate(format: "group == %@", group),
            animation: .default
        )
    }

    private var activeBooks: [LedgerBook] {
        BookRepository().books(in: group)
    }

    private var selectedBook: LedgerBook? {
        activeBooks.first { $0.id?.uuidString == selectedBookID }
            ?? activeBooks.first(where: \.isDefault)
            ?? activeBooks.first
    }

    /// The repositories refuse the write with the same `PermissionError` this
    /// resolves, so the entry point and the save path can never disagree.
    private func reloadWriteAccess() {
        writeAccess = TransactionWriteAccess(
            restriction: EffectivePermissionRepository().transactionWriteRestriction(in: group)
        )
    }

    private var currencyCode: String {
        LedgerCurrency.normalizedCode(group.currencyCode)
    }

    private var kindFilter: Binding<Filter> {
        Binding(
            get: { Filter.matching(query.kinds) },
            set: { query.kinds = $0.kinds }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if selectedBook != nil || scope != .currentBook {
                TransactionResultListView(
                    result: result,
                    currencyCode: currencyCode,
                    isFiltered: !query.isEmpty,
                    showsBookName: scope != .currentBook,
                    hasSearchableBooks: !result.includedBookIDs.isEmpty,
                    writeAccess: writeAccess
                ) {
                    isPresentingNewEntry = true
                }
            } else {
                ScrollView {
                    LedgerEmptyState(
                        systemImage: "book.closed",
                        title: "正在準備主要帳本",
                        message: "完成資料準備後，就能在這裡新增交易。"
                    )
                    .padding(.horizontal, LedgerTheme.pagePadding)
                    .padding(.top, 24)
                }
            }
        }
        .searchable(
            text: $query.keyword,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "搜尋備註、分類、帳戶或成員"
        )
        .toolbar {
            ToolbarItem {
                Button {
                    isPresentingFilters = true
                } label: {
                    Image(
                        systemName: query.hasActiveFilters
                            ? "line.3.horizontal.decrease.circle.fill"
                            : "line.3.horizontal.decrease.circle"
                    )
                }
                .accessibilityLabel(
                    query.hasActiveFilters
                        ? "篩選交易，已套用 \(query.activeFilterCount) 個條件"
                        : "篩選交易"
                )
            }
            if selectedBook != nil, writeAccess.canWrite {
                ToolbarItem {
                    Button {
                        isPresentingNewEntry = true
                    } label: {
                        Image(systemName: "plus")
                            .fontWeight(.bold)
                    }
                    .accessibilityLabel("新增交易")
                }
            }
        }
        .sheet(isPresented: $isPresentingNewEntry) {
            if let selectedBook {
                NavigationStack {
                    NewTransactionView(book: selectedBook) {
                        isPresentingNewEntry = false
                    }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $isPresentingFilters) {
            NavigationStack {
                TransactionFilterView(
                    group: group,
                    query: $query,
                    scope: $scope,
                    selectedBookIDs: $selectedCustomBookIDs,
                    currentBookName: selectedBook?.name ?? "未選擇帳本"
                )
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .onAppear {
            normalizeSelectedBook()
            reloadWriteAccess()
            reloadResult()
        }
        .onChange(of: activeBooks.count) {
            normalizeSelectedBook()
            reloadResult()
        }
        .onChange(of: query) { _, _ in reloadResult() }
        .onChange(of: scope) { _, _ in reloadResult() }
        .onChange(of: selectedCustomBookIDs) { _, _ in reloadResult() }
        .onChange(of: selectedBookID) { _, _ in reloadResult() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .NSManagedObjectContextObjectsDidChange,
                object: context
            )
        ) { notification in
            if ContextChangeObserver.touches(notification, .groupPermissions) {
                reloadWriteAccess()
            }
            // 作廢狀態來自稽核事件，而編輯既不改變交易筆數也不改變 fetch 結果的
            // 成員，兩者都不會讓 `entries` 自己重新發佈，所以要跟著變更重算。
            if ContextChangeObserver.touches(notification, .auditLog, .transactionSearch) {
                reloadResult()
            }
        }
    }

    /// 結果是快取的，不是 computed property：每次計算都要再查一次群組的作廢稽核
    /// 事件，做成 computed property 等於每次 render 都重跑一次完整搜尋。
    private func reloadResult() {
        result = TransactionSearchService().results(
            candidates: Array(entries),
            in: group,
            query: query,
            scope: scope,
            currentBook: selectedBook,
            selectedBookIDs: selectedCustomBookIDs
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if groups.count > 1 {
                    Menu {
                        ForEach(groups, id: \.objectID) { candidate in
                            Button {
                                selectedGroupID = candidate.objectID
                            } label: {
                                if candidate.objectID == group.objectID {
                                    Label(candidate.name ?? "未命名群組", systemImage: "checkmark")
                                } else {
                                    Text(candidate.name ?? "未命名群組")
                                }
                            }
                        }
                    } label: {
                        selectorLabel(group.name ?? "未命名群組", systemImage: "person.3.fill")
                    }
                    .accessibilityLabel("切換群組")
                } else {
                    Label(group.name ?? "未命名群組", systemImage: "person.3.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if let selectedBook {
                    Menu {
                        ForEach(activeBooks, id: \.objectID) { book in
                            Button {
                                select(book)
                            } label: {
                                if book == selectedBook {
                                    Label(book.name ?? "未命名帳本", systemImage: "checkmark")
                                } else {
                                    Text(book.name ?? "未命名帳本")
                                }
                            }
                        }
                    } label: {
                        selectorLabel(selectedBook.name ?? "未命名帳本", systemImage: "book.closed.fill")
                    }
                    .accessibilityLabel("切換目前帳本")
                }
            }

            Picker("交易類型", selection: kindFilter) {
                ForEach(Filter.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)

            scopeSummary
        }
        .padding(.horizontal, LedgerTheme.pagePadding)
        .padding(.top, 12)
    }

    /// 每個搜尋結果都必須說得出自己的範圍與筆數，使用者才知道現在看到的是全部
    /// 交易，還是被條件收斂過的一部分。
    private var scopeSummary: some View {
        HStack(spacing: 8) {
            Label(scopeLabel, systemImage: "book.closed.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            if query.isEmpty {
                Text("\(result.matchCount) 筆")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("符合 \(result.matchCount) / \(result.scopedCount) 筆")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LedgerTheme.primaryStrong)

                Button("清除") {
                    query = TransactionQuery()
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var scopeLabel: String {
        switch scope {
        case .allActiveBooks:
            return "全部帳本（\(result.includedBookIDs.count) 本）"
        case .currentBook:
            return selectedBook?.name ?? "未選擇帳本"
        case .selectedBookIDs:
            return "自選帳本（\(result.includedBookIDs.count) 本）"
        }
    }

    private func selectorLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.bold))
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(LedgerTheme.primary)
    }

    private func select(_ book: LedgerBook) {
        guard book.archivedAt == nil, let id = book.id else { return }
        selectedBookID = id.uuidString
    }

    private func normalizeSelectedBook() {
        if let selectedBook, selectedBook.id?.uuidString == selectedBookID {
            return
        }
        if let fallback = activeBooks.first(where: \.isDefault) ?? activeBooks.first {
            select(fallback)
        }
    }
}

/// 依月份分組的搜尋結果。純呈現：結果由呼叫端快取並在資料變更時重算，這裡不再
/// 自行查詢，才不會讓每次 render 都重跑一次搜尋。
private struct TransactionResultListView: View {
    let result: TransactionSearchResult
    let currencyCode: String
    /// 有沒有套用關鍵字或篩選。空結果的說法完全不同：一個是「還沒有交易」，
    /// 另一個是「有交易，但沒有一筆符合條件」。
    let isFiltered: Bool
    let showsBookName: Bool
    let hasSearchableBooks: Bool
    let writeAccess: TransactionWriteAccess
    let onAddFirst: () -> Void

    private var addAction: (() -> Void)? {
        guard writeAccess.canWrite, !isFiltered else { return nil }
        return onAddFirst
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
                if let message = writeAccess.noticeMessage {
                    LedgerNotice(message: message)
                }

                if result.hasMatches {
                    if isFiltered {
                        matchTotals
                    }
                    ForEach(result.sections) { section in
                        Section {
                            ForEach(section.entries, id: \.objectID) { entry in
                                NavigationLink {
                                    TransactionDetailView(entry: entry)
                                } label: {
                                    EntryRow(
                                        entry: entry,
                                        showsBookName: showsBookName,
                                        isVoided: entry.id.map(result.voidedEntryIDs.contains) == true
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            monthHeader(section)
                        }
                    }
                } else {
                    emptyState
                }
            }
            .padding(.horizontal, LedgerTheme.pagePadding)
            .padding(.top, 16)
            .padding(.bottom, 28)
        }
    }

    private var matchTotals: some View {
        LedgerCard {
            HStack(spacing: 16) {
                totalColumn(title: "收入", amount: result.income, tint: LedgerTheme.primary)
                Divider().frame(height: 30)
                totalColumn(title: "支出", amount: result.expense, tint: LedgerTheme.coral)
                Divider().frame(height: 30)
                totalColumn(title: "淨額", amount: result.net, tint: .primary)
            }
        }
    }

    private func totalColumn(title: String, amount: Decimal, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(LedgerCurrency.format(amount, currencyCode: currencyCode))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func monthHeader(_ section: TransactionSearchSection) -> some View {
        HStack {
            Text(section.title)
                .font(.subheadline.weight(.bold))
            Spacer()
            Text(LedgerCurrency.format(section.net, currencyCode: currencyCode))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .background(LedgerTheme.surface.opacity(0.94))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var emptyState: some View {
        if !hasSearchableBooks {
            LedgerEmptyState(
                systemImage: "book.closed",
                title: "沒有選擇任何帳本",
                message: "請在篩選面板選擇至少一本帳本，才能搜尋交易。"
            )
        } else if isFiltered {
            LedgerEmptyState(
                systemImage: "magnifyingglass",
                title: "沒有符合的交易",
                message: result.scopedCount > 0
                    ? "這個範圍內有 \(result.scopedCount) 筆交易，但都不符合目前的關鍵字與篩選條件。"
                    : "這個範圍內還沒有任何交易。"
            )
        } else {
            LedgerEmptyState(
                systemImage: "receipt",
                title: "沒有有效交易",
                message: writeAccess.canWrite
                    ? "新增共同收支後，就能在這裡查看、編輯與核對交易。"
                    : "目前還沒有可檢視的交易。",
                actionTitle: addAction == nil ? nil : "新增交易",
                action: addAction
            )
        }
    }
}

private struct EntryRow: View {
    @ObservedObject var entry: LedgerEntry
    /// 跨帳本搜尋時每一筆都要標示來源帳本；單一帳本範圍下重複顯示只是雜訊。
    var showsBookName = false
    var isVoided = false

    private var kind: EntryKind {
        EntryKind(rawValue: entry.kind ?? "") ?? .expense
    }

    private var title: String {
        if let categoryName = entry.category?.name, !categoryName.isEmpty {
            return categoryName
        }
        if let note = entry.note, !note.isEmpty {
            return note
        }
        return kind.displayName
    }

    private var subtitle: String {
        var parts: [String] = []
        if let date = entry.date {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        if kind == .transfer, let from = entry.sourceAccount?.name, let to = entry.destinationAccount?.name {
            parts.append("\(from) → \(to)")
        } else if let account = entry.sourceAccount?.name {
            parts.append(account)
        }
        if showsBookName, let book = entry.book?.name, !book.isEmpty {
            parts.append(book)
        }
        return parts.joined(separator: " · ")
    }

    private var amountText: String {
        LedgerCurrency.formatSigned(
            (entry.amount as Decimal?) ?? 0,
            kind: kind,
            currencyCode: LedgerCurrency.normalizedCode(entry.group?.currencyCode)
        )
    }

    private var amountColor: Color {
        switch kind {
        case .income: return LedgerTheme.primary
        case .expense: return LedgerTheme.coral
        case .transfer: return .secondary
        case .balanceAdjustment: return .blue
        }
    }

    var body: some View {
        LedgerCard {
            HStack(spacing: 14) {
                LedgerIconBadge(systemImage: kind.systemImage, tint: kind.tint)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .strikethrough(isVoided)
                        if isVoided {
                            Text("已作廢")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.secondary.opacity(0.15), in: Capsule())
                        }
                    }
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(amountText)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(isVoided ? .secondary : amountColor)
                    .strikethrough(isVoided)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .opacity(isVoided ? 0.75 : 1)
    }
}

private struct TransactionDetailView: View {
    @ObservedObject var entry: LedgerEntry

    @Environment(\.managedObjectContext) private var context

    @State private var isEditing = false
    @State private var showVoidConfirmation = false
    @State private var errorMessage: String?
    /// Both of these reach outside the entry to resolve — `isVoided` fetches the
    /// group's void audits, and the write access makes a synchronous `fetchShares`
    /// call — and `body` reads each of them several times per pass. They are resolved
    /// once per change instead of once per read.
    @State private var isVoided = false
    @State private var writeAccess = TransactionWriteAccess.unresolved

    private var repository: EntryRepository { EntryRepository() }

    private var kind: EntryKind {
        EntryKind(rawValue: entry.kind ?? "") ?? .expense
    }

    private var currencyCode: String {
        LedgerCurrency.normalizedCode(entry.group?.currencyCode)
    }

    private var payments: [EntryPayment] {
        (entry.payments as? Set<EntryPayment> ?? [])
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                return (lhs.member?.displayName ?? "") < (rhs.member?.displayName ?? "")
            }
    }

    private var splits: [EntrySplit] {
        (entry.splits as? Set<EntrySplit> ?? [])
            .sorted { ($0.member?.displayName ?? "") < ($1.member?.displayName ?? "") }
    }

    private func reloadStatus() {
        guard let group = entry.group else {
            isVoided = false
            writeAccess = .unresolved
            return
        }
        isVoided = repository.isVoided(entry)
        writeAccess = TransactionWriteAccess(
            restriction: EffectivePermissionRepository().transactionWriteRestriction(in: group)
        )
    }

    private var originalSnapshot: TransactionAuditPayload.Snapshot? {
        repository.auditPayloads(for: entry).last(where: { $0.after?.isVoided == true })?.before
    }

    private var detailAmount: Decimal {
        if isVoided,
           let amountText = originalSnapshot?.amount,
           let original = Decimal(string: amountText) {
            return original
        }
        return (entry.amount as Decimal?) ?? 0
    }

    var body: some View {
        List {
            if isVoided {
                Section {
                    Label("此交易已作廢，保留於稽核歷史中。", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }

            Section("交易") {
                detailRow("類型", value: kind.displayName)
                detailRow(
                    "金額",
                    value: LedgerCurrency.formatSigned(
                        detailAmount,
                        kind: kind,
                        currencyCode: currencyCode
                    )
                )
                if let date = entry.date {
                    detailRow("日期", value: date.formatted(date: .long, time: .omitted))
                }
                detailRow("帳本", value: entry.book?.name ?? "未命名帳本")
                if let category = entry.category?.name, !category.isEmpty {
                    detailRow("分類", value: category)
                }
                if kind == .transfer {
                    detailRow("轉出帳戶", value: entry.sourceAccount?.name ?? "-")
                    detailRow("轉入帳戶", value: entry.destinationAccount?.name ?? "-")
                } else {
                    detailRow("帳戶", value: entry.sourceAccount?.name ?? "-")
                }
                if let note = entry.note, !note.isEmpty {
                    detailRow("備註", value: note)
                }
            }

            if kind != .transfer {
                Section("付款人") {
                    ForEach(payments, id: \.objectID) { payment in
                        detailRow(
                            payment.member?.displayName ?? "未命名成員",
                            value: LedgerCurrency.format(
                                (payment.amount as Decimal?) ?? 0,
                                currencyCode: currencyCode
                            )
                        )
                    }
                }

                Section("分攤 · \(splitModeName)") {
                    ForEach(splits, id: \.objectID) { split in
                        VStack(alignment: .leading, spacing: 4) {
                            detailRow(
                                split.member?.displayName ?? "未命名成員",
                                value: LedgerCurrency.format(
                                    (split.amount as Decimal?) ?? 0,
                                    currencyCode: currencyCode
                                )
                            )
                            if let input = split.inputValue as Decimal?,
                               splitMode != .equal {
                                Text(splitMode == .percentage
                                     ? "原始輸入：\(NSDecimalNumber(decimal: input).stringValue)%"
                                     : "原始輸入：\(LedgerCurrency.format(input, currencyCode: currencyCode))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if !isVoided {
                if let message = writeAccess.noticeMessage {
                    Section {
                        Label(message, systemImage: "lock")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else if writeAccess.canWrite {
                    Section {
                        Button("作廢交易", role: .destructive) {
                            showVoidConfirmation = true
                        }
                    } footer: {
                        Text("作廢不會刪除歷史紀錄；系統會保存交易當下的付款與分攤快照。")
                    }
                }
            }
        }
        .navigationTitle("交易詳情")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reloadStatus)
        .onReceive(
            NotificationCenter.default.publisher(
                for: .NSManagedObjectContextObjectsDidChange,
                object: context
            )
        ) { notification in
            guard ContextChangeObserver.touches(notification, .auditLog, .groupPermissions) else {
                return
            }
            reloadStatus()
        }
        .toolbar {
            if !isVoided, entry.book?.archivedAt == nil, writeAccess.canWrite {
                Button("編輯") {
                    isEditing = true
                }
            }
        }
        .sheet(isPresented: $isEditing) {
            if let book = entry.book {
                NavigationStack {
                    NewTransactionView(book: book, entry: entry) {
                        isEditing = false
                    }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        .confirmationDialog(
            "確定要作廢這筆交易？",
            isPresented: $showVoidConfirmation,
            titleVisibility: .visible
        ) {
            Button("作廢交易", role: .destructive, action: voidEntry)
            Button("取消", role: .cancel) {}
        } message: {
            Text("作廢後不能再編輯，但完整交易快照仍會保留在稽核紀錄。")
        }
        .alert("無法處理交易", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "請稍後再試。")
        }
    }

    private var splitMode: SplitMode {
        SplitMode(rawValue: entry.splitMode ?? "") ?? .equal
    }

    private var splitModeName: String { splitMode.displayName }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }

    private func voidEntry() {
        do {
            try repository.voidEntry(entry)
            reloadStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack { TransactionsView() }
        .environment(
            \.managedObjectContext,
            PersistenceController(inMemory: true).container.viewContext
        )
}
