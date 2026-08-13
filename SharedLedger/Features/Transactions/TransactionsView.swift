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
                        title: .transactionEmptyNoGroupTitle,
                        message: .transactionEmptyNoGroupMessage
                    )
                    .padding(.horizontal, LedgerTheme.pagePadding)
                    .padding(.top, 24)
                }
            }
        }
        .navigationTitle(Text(.transactionTitle))
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
        case all
        case expense
        case income
        case transfer

        var id: Self { self }

        var titleKey: LedgerStringKey {
            switch self {
            case .all: return .transactionKindFilterAll
            case .expense: return .entryKindExpense
            case .income: return .entryKindIncome
            case .transfer: return .entryKindTransfer
            }
        }

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
                        title: .transactionEmptyPreparingBookTitle,
                        message: .transactionEmptyPreparingBookMessage
                    )
                    .padding(.horizontal, LedgerTheme.pagePadding)
                    .padding(.top, 24)
                }
            }
        }
        .searchable(
            text: $query.keyword,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text(.transactionSearchPrompt)
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
                .accessibilityLabel(Text(verbatim: filterAccessibilityLabel))
            }
            if selectedBook != nil, writeAccess.canWrite {
                ToolbarItem {
                    Button {
                        isPresentingNewEntry = true
                    } label: {
                        Image(systemName: "plus")
                            .fontWeight(.bold)
                    }
                    .accessibilityLabel(Text(.transactionActionAdd))
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
                    currentBookName: selectedBook?.name
                        ?? LedgerStringKey.transactionScopeNoBookSelected.string()
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

    /// 已套用的條件數量要唸出來，否則 VoiceOver 使用者只知道有一個「篩選」按鈕，
    /// 不知道目前的結果已經被收斂過。
    private var filterAccessibilityLabel: String {
        guard query.hasActiveFilters else {
            return LedgerStringKey.transactionActionFilter.string()
        }
        return LedgerStringKey.transactionActionFilterActive.string(
            arguments: [Int64(query.activeFilterCount)]
        )
    }

    private var groupName: String {
        group.name ?? LedgerStringKey.commonPlaceholderUnnamedGroup.string()
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
                                let name = candidate.name
                                    ?? LedgerStringKey.commonPlaceholderUnnamedGroup.string()
                                if candidate.objectID == group.objectID {
                                    Label {
                                        Text(verbatim: name)
                                    } icon: {
                                        Image(systemName: "checkmark")
                                    }
                                } else {
                                    Text(verbatim: name)
                                }
                            }
                        }
                    } label: {
                        selectorLabel(groupName, systemImage: "person.3.fill")
                    }
                    .accessibilityLabel(Text(.transactionGroupPickerAccessibilityLabel))
                    .accessibilityValue(Text(verbatim: groupName))
                } else {
                    Label {
                        Text(verbatim: groupName)
                    } icon: {
                        Image(systemName: "person.3.fill")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if let selectedBook {
                    let selectedBookName = selectedBook.name
                        ?? LedgerStringKey.commonPlaceholderUnnamedBook.string()
                    Menu {
                        ForEach(activeBooks, id: \.objectID) { book in
                            Button {
                                select(book)
                            } label: {
                                let name = book.name
                                    ?? LedgerStringKey.commonPlaceholderUnnamedBook.string()
                                if book == selectedBook {
                                    Label {
                                        Text(verbatim: name)
                                    } icon: {
                                        Image(systemName: "checkmark")
                                    }
                                } else {
                                    Text(verbatim: name)
                                }
                            }
                        }
                    } label: {
                        selectorLabel(selectedBookName, systemImage: "book.closed.fill")
                    }
                    .accessibilityLabel(Text(.transactionBookPickerAccessibilityLabel))
                    .accessibilityValue(Text(verbatim: selectedBookName))
                }
            }

            Picker(selection: kindFilter) {
                ForEach(Filter.allCases) { item in
                    Text(item.titleKey).tag(item)
                }
            } label: {
                Text(.transactionKindFilterTitle)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(Text(.transactionKindFilterTitle))

            scopeSummary
        }
        .padding(.horizontal, LedgerTheme.pagePadding)
        .padding(.top, 12)
    }

    /// 每個搜尋結果都必須說得出自己的範圍與筆數，使用者才知道現在看到的是全部
    /// 交易，還是被條件收斂過的一部分。
    private var scopeSummary: some View {
        HStack(spacing: 8) {
            Label {
                Text(verbatim: scopeLabel)
            } icon: {
                Image(systemName: "book.closed.fill")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)

            Spacer(minLength: 8)

            if query.isEmpty {
                Text(verbatim: LedgerStringKey.transactionResultCount.string(
                    arguments: [Int64(result.matchCount)]
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text(verbatim: LedgerStringKey.transactionResultMatchCount.string(
                    arguments: [Int64(result.matchCount), Int64(result.scopedCount)]
                ))
                .font(.caption.weight(.semibold))
                .foregroundStyle(LedgerTheme.primaryStrong)

                Button {
                    query = TransactionQuery()
                } label: {
                    Text(.transactionResultClear)
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
            }
        }
        // 範圍與筆數合起來才是一句話；「清除」保留成自己的按鈕，否則 VoiceOver
        // 使用者會讀得到這個狀態，卻沒有辦法動它。
        .accessibilityElement(children: .contain)
    }

    private var scopeLabel: String {
        switch scope {
        case .allActiveBooks:
            return LedgerStringKey.transactionScopeAllBooks.string(
                arguments: [Int64(result.includedBookIDs.count)]
            )
        case .currentBook:
            return selectedBook?.name ?? LedgerStringKey.transactionScopeNoBookSelected.string()
        case .selectedBookIDs:
            return LedgerStringKey.transactionScopeSelectedBooks.string(
                arguments: [Int64(result.includedBookIDs.count)]
            )
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

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// 三欄合計在最大字級改成直排，分隔線也要跟著換方向。
    @ScaledMetric(relativeTo: .subheadline) private var totalsDividerHeight: CGFloat = 30

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
            LedgerAdaptiveStack(horizontalSpacing: 16, verticalSpacing: 12) {
                totalColumn(title: .entryKindIncome, amount: result.income, tint: LedgerTheme.primary)
                // 直排時分隔線是橫線，撐一個固定高度只會多出一段空白。
                Divider().frame(height: isStacked ? nil : totalsDividerHeight)
                totalColumn(title: .entryKindExpense, amount: result.expense, tint: LedgerTheme.coral)
                Divider().frame(height: isStacked ? nil : totalsDividerHeight)
                totalColumn(title: .transactionTotalsNet, amount: result.net, tint: .primary)
            }
        }
    }

    private var isStacked: Bool { dynamicTypeSize.isAccessibilitySize }

    private func totalColumn(title: LedgerStringKey, amount: Decimal, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: LedgerCurrency.format(amount, currencyCode: currencyCode))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .lineLimit(isStacked ? 2 : 1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func monthHeader(_ section: TransactionSearchSection) -> some View {
        HStack {
            // 標題是搜尋服務用 `Date.FormatStyle` 依目前 locale 排出來的年月，不是文案。
            Text(verbatim: section.title)
                .font(.subheadline.weight(.bold))
            Spacer()
            Text(verbatim: LedgerCurrency.format(section.net, currencyCode: currencyCode))
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
                title: .transactionEmptyNoBookSelectedTitle,
                message: .transactionEmptyNoBookSelectedMessage
            )
        } else if isFiltered {
            LedgerEmptyState(
                systemImage: "magnifyingglass",
                title: .transactionEmptyNoMatchTitle,
                message: Text(verbatim: noMatchMessage)
            )
        } else {
            LedgerEmptyState(
                systemImage: "receipt",
                title: .transactionEmptyNoneTitle,
                message: writeAccess.canWrite
                    ? LedgerStringKey.transactionEmptyNoneMessageWritable
                    : LedgerStringKey.transactionEmptyNoneMessageReadOnly,
                actionTitle: addAction == nil ? nil : LedgerStringKey.transactionActionAdd,
                action: addAction
            )
        }
    }

    private var noMatchMessage: String {
        guard result.scopedCount > 0 else {
            return LedgerStringKey.transactionEmptyNoMatchMessageEmpty.string()
        }
        return LedgerStringKey.transactionEmptyNoMatchMessageScoped.string(
            arguments: [Int64(result.scopedCount)]
        )
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
            parts.append(LedgerFormatters.day(date))
        }
        if kind == .transfer, let from = entry.sourceAccount?.name, let to = entry.destinationAccount?.name {
            parts.append(
                LedgerStringKey.transactionRowTransferRoute.string(arguments: [from, to])
            )
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
                LedgerAdaptiveStack {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            // 標題是分類、備註或交易種類，三者都是資料而不是文案。
                            Text(verbatim: title)
                                .font(.subheadline.weight(.semibold))
                                .strikethrough(isVoided)
                            if isVoided {
                                Text(.transactionRowVoided)
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(.secondary.opacity(0.15), in: Capsule())
                            }
                        }
                        if !subtitle.isEmpty {
                            Text(verbatim: subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 6) {
                        Text(verbatim: amountText)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(isVoided ? .secondary : amountColor)
                            .strikethrough(isVoided)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .opacity(isVoided ? 0.75 : 1)
        // 一列就是一筆交易：分開唸成標題、日期、金額三個元素，使用者要滑三次才知道
        // 自己停在哪一筆。
        .accessibilityElement(children: .combine)
    }
}

/// 一筆交易的完整內容。
///
/// 不是 `private`：iCloud 同步頁列出的資料衝突要能直接點進這裡，讓使用者用平常的
/// 編輯與作廢流程處理，而不是另外做一套只在衝突時出現的修復畫面。
struct TransactionDetailView: View {
    @ObservedObject var entry: LedgerEntry

    @Environment(\.managedObjectContext) private var context

    @State private var isEditing = false
    @State private var showVoidConfirmation = false
    @State private var errorMessage: String?
    /// The write access reaches outside the entry to resolve — a synchronous
    /// `fetchShares` call — and `body` reads it several times per pass, so it is
    /// resolved once per change instead of once per read. `isVoided` is now a plain
    /// read of `entry.voidedAt`, but it stays cached alongside it so both halves of
    /// the screen's status refresh from the same notification.
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
        entry.livePayments
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                return (lhs.member?.displayName ?? "") < (rhs.member?.displayName ?? "")
            }
    }

    private var splits: [EntrySplit] {
        entry.liveSplits
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
                    Label {
                        Text(.transactionDetailVoidedNotice)
                    } icon: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                detailRow(.transactionDetailFieldKind, value: kind.displayName)
                detailRow(
                    .transactionDetailFieldAmount,
                    value: LedgerCurrency.formatSigned(
                        detailAmount,
                        kind: kind,
                        currencyCode: currencyCode
                    )
                )
                if let date = entry.date {
                    detailRow(.transactionDetailFieldDate, value: LedgerFormatters.longDay(date))
                }
                detailRow(
                    .transactionDetailFieldBook,
                    value: entry.book?.name ?? LedgerStringKey.commonPlaceholderUnnamedBook.string()
                )
                if let category = entry.category?.name, !category.isEmpty {
                    detailRow(.transactionDetailFieldCategory, value: category)
                }
                if kind == .transfer {
                    detailRow(.transactionDetailFieldSourceAccount, value: accountName(entry.sourceAccount))
                    detailRow(
                        .transactionDetailFieldDestinationAccount,
                        value: accountName(entry.destinationAccount)
                    )
                } else {
                    detailRow(.transactionDetailFieldAccount, value: accountName(entry.sourceAccount))
                }
                if let note = entry.note, !note.isEmpty {
                    detailRow(.transactionDetailFieldNote, value: note)
                }
            } header: {
                Text(.transactionDetailSectionTransaction)
            }

            if kind != .transfer {
                Section {
                    ForEach(payments, id: \.objectID) { payment in
                        detailRow(
                            memberName(payment.member),
                            value: LedgerCurrency.format(
                                (payment.amount as Decimal?) ?? 0,
                                currencyCode: currencyCode
                            )
                        )
                    }
                } header: {
                    Text(.transactionDetailSectionPayers)
                }

                Section {
                    ForEach(splits, id: \.objectID) { split in
                        VStack(alignment: .leading, spacing: 4) {
                            detailRow(
                                memberName(split.member),
                                value: LedgerCurrency.format(
                                    (split.amount as Decimal?) ?? 0,
                                    currencyCode: currencyCode
                                )
                            )
                            if let input = split.inputValue as Decimal?,
                               splitMode != .equal {
                                Text(verbatim: originalInputText(input))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text(verbatim: LedgerStringKey.transactionDetailSectionSplits.string(
                        arguments: [splitModeName]
                    ))
                }
            }

            if !isVoided {
                if let message = writeAccess.noticeMessage {
                    Section {
                        Label {
                            // 權限說明來自資料層的 `PermissionError`，那一層還沒遷移。
                            Text(verbatim: message)
                        } icon: {
                            Image(systemName: "lock")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                } else if writeAccess.canWrite {
                    Section {
                        Button(role: .destructive) {
                            showVoidConfirmation = true
                        } label: {
                            Text(.transactionDetailActionVoid)
                        }
                    } footer: {
                        Text(.transactionDetailVoidFooter)
                    }
                }
            }
        }
        .navigationTitle(Text(.transactionDetailTitle))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reloadStatus)
        .onReceive(
            NotificationCenter.default.publisher(
                for: .NSManagedObjectContextObjectsDidChange,
                object: context
            )
        ) { notification in
            // `.entryDetails` covers the entry itself: since V10 the voided flag lives
            // on `LedgerEntry.voidedAt`, so a void this screen did not perform arrives
            // as a change to the entry rather than to the audit log. `.auditLog` stays
            // because the pre-void snapshot shown above still comes from the audit
            // payload.
            guard ContextChangeObserver.touches(
                notification,
                .entryDetails,
                .auditLog,
                .groupPermissions
            ) else {
                return
            }
            reloadStatus()
        }
        .toolbar {
            if !isVoided, entry.book?.archivedAt == nil, writeAccess.canWrite {
                Button {
                    isEditing = true
                } label: {
                    Text(.commonActionEdit)
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
            Text(.transactionDetailVoidConfirmTitle),
            isPresented: $showVoidConfirmation,
            titleVisibility: .visible
        ) {
            Button(role: .destructive, action: voidEntry) {
                Text(.transactionDetailActionVoid)
            }
            Button(role: .cancel) {} label: {
                Text(.commonActionCancel)
            }
        } message: {
            Text(.transactionDetailVoidConfirmMessage)
        }
        .alert(Text(.transactionDetailErrorTitle), isPresented: errorBinding) {
            Button(role: .cancel) {} label: {
                Text(.commonActionOK)
            }
        } message: {
            // 錯誤內容來自資料層，那一層還沒遷移到 catalog。
            Text(verbatim: errorMessage ?? LedgerStringKey.commonErrorRetryLater.string())
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

    private func detailRow(_ title: LedgerStringKey, value: String) -> some View {
        detailRow(Text(title), value: value)
    }

    /// 標題是成員名稱這類資料時用這一個；欄位名稱一律走上面的鍵。
    private func detailRow(_ title: String, value: String) -> some View {
        detailRow(Text(verbatim: title), value: value)
    }

    private func detailRow(_ title: Text, value: String) -> some View {
        LedgerAdaptiveStack(horizontalSpacing: 16, verticalSpacing: 2, rowAlignment: .firstTextBaseline) {
            title
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: value)
                .multilineTextAlignment(.trailing)
        }
        // 欄位名稱與值分開唸，使用者要滑兩次才聽得懂一行；合成一個元素才是一句話。
        .accessibilityElement(children: .combine)
    }

    private func accountName(_ account: LedgerAccount?) -> String {
        guard let account else { return "—" }
        return account.name ?? LedgerStringKey.commonPlaceholderUnnamedAccount.string()
    }

    private func memberName(_ member: Member?) -> String {
        member?.displayName ?? LedgerStringKey.commonPlaceholderUnnamedMember.string()
    }

    private func originalInputText(_ input: Decimal) -> String {
        if splitMode == .percentage {
            return LedgerStringKey.transactionDetailSplitOriginalPercentage.string(
                arguments: [NSDecimalNumber(decimal: input).stringValue]
            )
        }
        return LedgerStringKey.transactionDetailSplitOriginalAmount.string(
            arguments: [LedgerCurrency.format(input, currencyCode: currencyCode)]
        )
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
