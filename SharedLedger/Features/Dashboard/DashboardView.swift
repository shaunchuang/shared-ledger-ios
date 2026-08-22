import CoreData
import SwiftUI

struct DashboardView: View {
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \LedgerGroup.updatedAt, ascending: false)],
        animation: .default
    ) private var groups: FetchedResults<LedgerGroup>

    @State private var selectedGroupID: NSManagedObjectID?

    private var selectedGroup: LedgerGroup? {
        if let selectedGroupID,
           let group = groups.first(where: { $0.objectID == selectedGroupID }) {
            return group
        }
        return groups.first
    }

    var body: some View {
        ZStack {
            LedgerBackground()
            if let group = selectedGroup {
                GroupDashboardView(
                    group: group,
                    groups: Array(groups),
                    selectedGroupID: $selectedGroupID
                )
                .id(group.objectID)
            } else {
                ScrollView {
                    LedgerEmptyState(
                        systemImage: "chart.pie",
                        title: .reportEmptyNoGroupTitle,
                        message: .reportEmptyNoGroupMessage
                    )
                    .padding(.horizontal, LedgerTheme.pagePadding)
                    .padding(.top, 24)
                }
            }
        }
        .navigationTitle(Text(.reportTitle))
        .navigationBarTitleDisplayMode(.large)
    }
}

private struct GroupDashboardView: View {
    @ObservedObject var group: LedgerGroup
    let groups: [LedgerGroup]
    @Binding var selectedGroupID: NSManagedObjectID?

    @Environment(\.managedObjectContext) private var context

    @AppStorage private var selectedBookID: String
    @State private var scope: ReportBookScope = .allActiveBooks
    @State private var month = Date()
    @State private var selectedCustomBookIDs: Set<UUID> = []
    @State private var isPresentingBookSelection = false
    @State private var snapshot = GroupReportSnapshot.empty

    /// SwiftUI 的 `.system(size:)` 是固定字級，完全不理會 Dynamic Type：這張卡片
    /// 最重要的那個數字，原本在最大字級下和旁邊的說明一樣大。`@ScaledMetric` 讓它
    /// 以 42 為基準跟著使用者的字級走。
    @ScaledMetric(relativeTo: .largeTitle) private var heroAmountSize: CGFloat = 42
    /// 選擇器是一個包住文字的按鈕，高度要跟著裡面的字一起長。
    @ScaledMetric(relativeTo: .subheadline) private var selectorMinHeight: CGFloat = 42

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
    }

    private var activeBooks: [LedgerBook] {
        BookRepository().books(in: group)
    }

    private var selectedBook: LedgerBook? {
        activeBooks.first { $0.id?.uuidString == selectedBookID }
            ?? activeBooks.first(where: \.isDefault)
            ?? activeBooks.first
    }

    private var currencyCode: String {
        LedgerCurrency.normalizedCode(group.currencyCode)
    }

    private var monthInterval: DateInterval {
        Calendar.current.dateInterval(of: .month, for: month)
            ?? DateInterval(start: month, duration: 31 * 24 * 60 * 60)
    }

    /// 快照是快取的，不是 computed property。body 會讀取它數十次（每個分類列還會
    /// 再讀一次），而每次計算都要重新掃描整個群組的交易與稽核事件，做成 computed
    /// property 等於每次 render 都重跑數十次完整聚合。
    private func reloadSnapshot() {
        snapshot = GroupReportService().snapshot(
            in: group,
            interval: monthInterval,
            scope: scope,
            currentBook: selectedBook,
            selectedBookIDs: selectedCustomBookIDs
        )
    }

    private var monthLabel: String {
        LedgerFormatters.month(month)
    }

    private var scopeDetail: String {
        switch scope {
        case .allActiveBooks:
            return LedgerStringKey.reportScopeAllBooks.string(
                arguments: [Int64(snapshot.includedBookIDs.count)]
            )
        case .currentBook:
            return selectedBook?.name ?? LedgerStringKey.transactionScopeNoBookSelected.string()
        case .selectedBookIDs:
            return LedgerStringKey.reportScopeCustomBooks.string(
                arguments: [Int64(snapshot.includedBookIDs.count)]
            )
        }
    }

    private var groupName: String {
        group.name ?? LedgerStringKey.commonPlaceholderUnnamedGroup.string()
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                welcomeHeader
                periodAndScopeCard
                expenseHero
                metricGrid
                accountBalanceCard

                if snapshot.entries.isEmpty {
                    LedgerEmptyState(
                        systemImage: "chart.bar.doc.horizontal",
                        title: .reportEmptyNoEntriesTitle,
                        message: .reportEmptyNoEntriesMessage
                    )
                } else {
                    categorySection
                    bookContributionSection
                    sourceEntriesSection
                }
            }
            .padding(.horizontal, LedgerTheme.pagePadding)
            .padding(.bottom, 28)
        }
        .onAppear {
            normalizeSelections()
            reloadSnapshot()
        }
        .onChange(of: activeBooks.count) { _, _ in
            normalizeSelections()
            reloadSnapshot()
        }
        .onChange(of: month) { _, _ in reloadSnapshot() }
        .onChange(of: scope) { _, _ in reloadSnapshot() }
        .onChange(of: selectedBookID) { _, _ in reloadSnapshot() }
        .onChange(of: selectedCustomBookIDs) { _, _ in reloadSnapshot() }
        .onChange(of: group.objectID) { _, _ in
            normalizeSelections()
            reloadSnapshot()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .NSManagedObjectContextObjectsDidChange,
                object: context
            )
        ) { _ in
            reloadSnapshot()
        }
        .sheet(isPresented: $isPresentingBookSelection) {
            customBookSelectionSheet
        }
    }

    private var welcomeHeader: some View {
        HStack(spacing: 13) {
            LedgerMark(size: 48)
            VStack(alignment: .leading, spacing: 3) {
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
                        HStack(spacing: 5) {
                            Text(verbatim: groupName)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2.weight(.bold))
                                .accessibilityHidden(true)
                        }
                        .font(.headline)
                        .foregroundStyle(.primary)
                    }
                    .accessibilityLabel(Text(.transactionGroupPickerAccessibilityLabel))
                    .accessibilityValue(Text(verbatim: groupName))
                } else {
                    Text(verbatim: groupName)
                        .font(.headline)
                }
                Text(.reportSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(verbatim: currencyCode)
                .font(.caption.weight(.bold))
                .foregroundStyle(LedgerTheme.primaryStrong)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(LedgerTheme.mint.opacity(0.18), in: Capsule())
        }
    }

    private var periodAndScopeCard: some View {
        LedgerCard(padding: 16) {
            VStack(spacing: 14) {
                HStack {
                    Button {
                        shiftMonth(by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .ledgerTapTarget()
                    }
                    .accessibilityLabel(Text(.reportMonthPreviousAccessibilityLabel))

                    Spacer()
                    VStack(spacing: 2) {
                        Text(verbatim: monthLabel)
                            .font(.headline)
                        Text(verbatim: scopeDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer()

                    Button {
                        shiftMonth(by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .ledgerTapTarget()
                    }
                    .accessibilityLabel(Text(.reportMonthNextAccessibilityLabel))
                }

                Picker(selection: $scope) {
                    ForEach(ReportBookScope.allCases) { item in
                        Text(item.displayNameKey).tag(item)
                    }
                } label: {
                    Text(.reportScopeField)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(Text(.reportScopeField))

                if scope == .currentBook, let selectedBook {
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
                        selectorLabel(
                            selectedBook.name
                                ?? LedgerStringKey.commonPlaceholderUnnamedBook.string(),
                            systemImage: "book.closed.fill"
                        )
                    }
                    .accessibilityLabel(Text(.transactionBookPickerAccessibilityLabel))
                    .accessibilityValue(Text(verbatim: selectedBook.name
                        ?? LedgerStringKey.commonPlaceholderUnnamedBook.string()))
                } else if scope == .selectedBookIDs {
                    Button {
                        isPresentingBookSelection = true
                    } label: {
                        selectorLabel(
                            LedgerStringKey.reportScopeSelectBooks.string(
                                arguments: [Int64(selectedCustomBookIDs.count)]
                            ),
                            systemImage: "checklist"
                        )
                    }
                }
            }
        }
    }

    private var expenseHero: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label(.reportHeroExpense, systemImage: "calendar")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.80))
                Spacer()
                Text(scope.displayNameKey)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.86))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.12), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(verbatim: LedgerCurrency.format(snapshot.expense, currencyCode: currencyCode))
                    .font(.system(size: heroAmountSize, weight: .bold, design: .rounded))
                    // 卡片本來就是為這個數字存在的，寬度不夠時讓它換行，不要縮小或截斷。
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.numericText())
                    .accessibilityLabel(Text(.reportHeroExpense))
                    .accessibilityValue(Text(verbatim: LedgerCurrency.format(
                        snapshot.expense,
                        currencyCode: currencyCode
                    )))
                Text(verbatim: LedgerStringKey.reportHeroSummary.string(arguments: [
                    LedgerCurrency.format(snapshot.income, currencyCode: currencyCode),
                    formattedNet
                ]))
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.74))
            }

            LedgerAdaptiveStack(horizontalSpacing: 8, verticalSpacing: 8) {
                statCapsule(
                    title: .reportStatEntries,
                    value: LedgerStringKey.reportStatEntriesValue.string(
                        arguments: [Int64(snapshot.entries.count)]
                    )
                )
                statCapsule(
                    title: .reportStatBooks,
                    value: LedgerStringKey.reportStatBooksValue.string(
                        arguments: [Int64(snapshot.includedBookIDs.count)]
                    )
                )
                statCapsule(
                    title: .reportStatCategories,
                    value: LedgerStringKey.reportStatCategoriesValue.string(
                        arguments: [Int64(snapshot.categories.count)]
                    )
                )
            }
        }
        .foregroundStyle(.white)
        .padding(22)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.25, blue: 0.23),
                    Color(red: 0.08, green: 0.43, blue: 0.35)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 28)
        )
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(.white.opacity(0.07))
                .frame(width: 150, height: 150)
                .offset(x: 45, y: -55)
                .allowsHitTesting(false)
        }
        .shadow(color: LedgerTheme.primary.opacity(0.20), radius: 24, y: 12)
    }

    private var metricGrid: some View {
        // 三張並排的卡片在最大字級只剩下每張三個字的寬度，改成一張一列。
        LedgerAdaptiveStack(horizontalSpacing: 12, verticalSpacing: 12, rowAlignment: .top) {
            NavigationLink {
                ReportSourceListView(
                    title: .reportMetricIncome,
                    entries: snapshot.entries.filter { $0.kind == .income },
                    currencyCode: currencyCode
                )
            } label: {
                MetricTile(
                    title: .reportMetricIncome,
                    value: LedgerCurrency.format(snapshot.income, currencyCode: currencyCode),
                    detail: .reportMetricIncomeDetail,
                    systemImage: "arrow.down.left",
                    tint: LedgerTheme.primary
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                ReportSourceListView(
                    title: .reportMetricNetTitle,
                    entries: snapshot.entries,
                    currencyCode: currencyCode
                )
            } label: {
                MetricTile(
                    title: .reportMetricNet,
                    value: formattedNet,
                    detail: snapshot.net >= 0
                        ? LedgerStringKey.reportMetricNetDetailPositive
                        : LedgerStringKey.reportMetricNetDetailNegative,
                    systemImage: "equal.circle",
                    tint: LedgerTheme.amber
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var accountBalanceCard: some View {
        LedgerCard(padding: 18) {
            HStack(spacing: 14) {
                LedgerIconBadge(systemImage: "building.columns.fill", tint: LedgerTheme.primary)
                LedgerAdaptiveStack(horizontalSpacing: 12, verticalSpacing: 4) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(.reportAccountBalanceTitle)
                            .font(.subheadline.weight(.semibold))
                        Text(.reportAccountBalanceDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: LedgerCurrency.format(
                        snapshot.accountBalance,
                        currencyCode: currencyCode
                    ))
                    .font(.headline.monospacedDigit())
                    .multilineTextAlignment(.trailing)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LedgerSectionHeader(title: .reportSectionCategories)
            LedgerCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(snapshot.categories.enumerated()), id: \.element.id) { index, category in
                        NavigationLink {
                            ReportSourceListView(
                                title: Text(verbatim: category.name),
                                entries: snapshot.entries.filter { entry in
                                    entry.categoryID == category.categoryID
                                },
                                currencyCode: currencyCode
                            )
                        } label: {
                            categoryRow(category)
                        }
                        .buttonStyle(.plain)

                        if index < snapshot.categories.count - 1 {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
        }
    }

    private var bookContributionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LedgerSectionHeader(title: .reportSectionBookContribution)
            LedgerCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(snapshot.books.enumerated()), id: \.element.id) { index, book in
                        NavigationLink {
                            ReportSourceListView(
                                title: Text(verbatim: book.name),
                                entries: snapshot.entries.filter { $0.bookID == book.bookID },
                                currencyCode: currencyCode
                            )
                        } label: {
                            HStack(spacing: 12) {
                                LedgerIconBadge(systemImage: "book.closed.fill")
                                LedgerAdaptiveStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(verbatim: book.name)
                                            .font(.subheadline.weight(.semibold))
                                        Text(verbatim: LedgerStringKey.reportBookAmounts.string(
                                            arguments: [
                                                LedgerCurrency.format(
                                                    book.income,
                                                    currencyCode: currencyCode
                                                ),
                                                LedgerCurrency.format(
                                                    book.expense,
                                                    currencyCode: currencyCode
                                                )
                                            ]
                                        ))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        Text(verbatim: LedgerStringKey.reportCategoryShare.string(
                                            arguments: [ReportShare.formatted(book.expenseShare)]
                                        ))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                    HStack(spacing: 6) {
                                        Text(verbatim: LedgerCurrency.format(
                                            book.net,
                                            currencyCode: currencyCode,
                                            showPositiveSign: true
                                        ))
                                        .font(.subheadline.weight(.semibold).monospacedDigit())
                                        Image(systemName: "chevron.right")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.tertiary)
                                            .accessibilityHidden(true)
                                    }
                                }
                            }
                            .padding(16)
                            .accessibilityElement(children: .combine)
                        }
                        .buttonStyle(.plain)

                        if index < snapshot.books.count - 1 {
                            Divider().padding(.leading, 68)
                        }
                    }
                }
            }
        }
    }

    private var sourceEntriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                LedgerSectionHeader(title: .reportSectionSourceEntries)
                Spacer()
                NavigationLink {
                    ReportSourceListView(
                        title: .reportSectionSourceEntries,
                        entries: snapshot.entries,
                        currencyCode: currencyCode
                    )
                } label: {
                    Text(.reportSourceViewAll)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LedgerTheme.primary)
            }

            LedgerCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(snapshot.entries.prefix(5).enumerated()), id: \.element.id) { index, entry in
                        NavigationLink {
                            ReportSourceEntryView(entry: entry, currencyCode: currencyCode)
                        } label: {
                            ReportSourceRow(entry: entry, currencyCode: currencyCode)
                                .padding(16)
                        }
                        .buttonStyle(.plain)

                        if index < min(snapshot.entries.count, 5) - 1 {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
        }
    }

    private var customBookSelectionSheet: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(activeBooks, id: \.objectID) { book in
                        Button {
                            toggleCustomBook(book)
                        } label: {
                            HStack {
                                Text(verbatim: book.name
                                    ?? LedgerStringKey.commonPlaceholderUnnamedBook.string())
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: isCustomBookSelected(book)
                                      ? "checkmark.circle.fill"
                                      : "circle")
                                .foregroundStyle(isCustomBookSelected(book)
                                                 ? LedgerTheme.primary
                                                 : .tertiary)
                                .accessibilityHidden(true)
                            }
                        }
                        .accessibilityAddTraits(
                            isCustomBookSelected(book) ? [.isButton, .isSelected] : .isButton
                        )
                    }
                } footer: {
                    Text(.reportBookSelectionFooter)
                }
            }
            .navigationTitle(Text(.reportBookSelectionTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { isPresentingBookSelection = false } label: {
                        Text(.commonActionDone)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var formattedNet: String {
        LedgerCurrency.format(snapshot.net, currencyCode: currencyCode, showPositiveSign: true)
    }

    private func categoryRow(_ category: GroupReportCategorySummary) -> some View {
        // 進度條與百分比都以「佔期間總支出」為準，兩者一致；先前的長條是相對於
        // 最大分類，會讓最大的分類永遠看起來像 100%。
        let fraction = min(1, max(0, NSDecimalNumber(decimal: category.expenseShare).doubleValue))

        return VStack(alignment: .leading, spacing: 9) {
            LedgerAdaptiveStack(verticalSpacing: 4) {
                Text(verbatim: category.name)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Text(verbatim: LedgerCurrency.format(
                        category.expense,
                        currencyCode: currencyCode
                    ))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            ProgressView(value: fraction)
                .tint(LedgerTheme.primary)
                // 進度條說的和下面那行百分比是同一件事，重複唸一次只是噪音。
                .accessibilityHidden(true)
            HStack(spacing: 6) {
                Text(verbatim: LedgerStringKey.reportCategoryShare.string(
                    arguments: [ReportShare.formatted(category.expenseShare)]
                ))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                if category.income > 0 {
                    // 分隔點是版面符號，不是文案。
                    Text(verbatim: "·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text(verbatim: LedgerStringKey.reportCategoryIncome.string(
                        arguments: [LedgerCurrency.format(
                            category.income,
                            currencyCode: currencyCode
                        )]
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .accessibilityElement(children: .combine)
    }

    private func statCapsule(title: LedgerStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))
            Text(verbatim: value)
                .font(.caption.weight(.bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private func selectorLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .lineLimit(1)
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.bold))
                .accessibilityHidden(true)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(LedgerTheme.primary)
        .padding(.horizontal, 12)
        .frame(minHeight: selectorMinHeight)
        .background(LedgerTheme.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private func shiftMonth(by value: Int) {
        month = Calendar.current.date(byAdding: .month, value: value, to: month) ?? month
    }

    private func select(_ book: LedgerBook) {
        guard book.archivedAt == nil, let id = book.id else { return }
        selectedBookID = id.uuidString
    }

    private func toggleCustomBook(_ book: LedgerBook) {
        guard let id = book.id else { return }
        if selectedCustomBookIDs.contains(id) {
            selectedCustomBookIDs.remove(id)
        } else {
            selectedCustomBookIDs.insert(id)
        }
    }

    private func isCustomBookSelected(_ book: LedgerBook) -> Bool {
        book.id.map(selectedCustomBookIDs.contains) == true
    }

    private func normalizeSelections() {
        if selectedBook == nil,
           let fallback = activeBooks.first(where: \.isDefault) ?? activeBooks.first {
            select(fallback)
        } else if selectedBook?.id?.uuidString != selectedBookID,
                  let selectedBook {
            select(selectedBook)
        }

        let activeIDs = Set(activeBooks.compactMap(\.id))
        selectedCustomBookIDs.formIntersection(activeIDs)
        if selectedCustomBookIDs.isEmpty, let currentID = selectedBook?.id {
            selectedCustomBookIDs = [currentID]
        }
    }
}

private struct MetricTile: View {
    let title: LedgerStringKey
    let value: String
    let detail: LedgerStringKey
    let systemImage: String
    let tint: Color

    var body: some View {
        LedgerCard(padding: 16) {
            VStack(alignment: .leading, spacing: 13) {
                LedgerIconBadge(systemImage: systemImage, tint: tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: value)
                        .font(.title3.weight(.bold).monospacedDigit())
                        .minimumScaleFactor(0.75)
                        .lineLimit(2)
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ReportSourceRow: View {
    let entry: GroupReportSourceEntry
    let currencyCode: String

    var body: some View {
        HStack(spacing: 12) {
            LedgerIconBadge(
                systemImage: entry.kind == .income ? "arrow.down.left" : "arrow.up.right",
                tint: entry.kind == .income ? LedgerTheme.primary : LedgerTheme.coral
            )
            LedgerAdaptiveStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: entry.note.isEmpty ? entry.categoryName : entry.note)
                        .font(.subheadline.weight(.semibold))
                    Text(verbatim: LedgerStringKey.reportSourceRowSubtitle.string(
                        arguments: [entry.bookName, LedgerFormatters.day(entry.date)]
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Text(verbatim: LedgerCurrency.formatSigned(
                        entry.amount,
                        kind: entry.kind,
                        currencyCode: currencyCode
                    ))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(entry.kind == .income ? LedgerTheme.primary : LedgerTheme.coral)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ReportSourceListView: View {
    private let title: Text
    private let entries: [GroupReportSourceEntry]
    private let currencyCode: String

    init(title: LedgerStringKey, entries: [GroupReportSourceEntry], currencyCode: String) {
        self.init(title: Text(title), entries: entries, currencyCode: currencyCode)
    }

    /// 標題是分類或帳本名稱時走這一個：名稱是資料，不進 catalog。
    init(title: Text, entries: [GroupReportSourceEntry], currencyCode: String) {
        self.title = title
        self.entries = entries
        self.currencyCode = currencyCode
    }

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView {
                    Label(.reportSourceEmptyTitle, systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text(.reportSourceEmptyMessage)
                }
            } else {
                ForEach(entries) { entry in
                    NavigationLink {
                        ReportSourceEntryView(entry: entry, currencyCode: currencyCode)
                    } label: {
                        ReportSourceRow(entry: entry, currencyCode: currencyCode)
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ReportSourceEntryView: View {
    let entry: GroupReportSourceEntry
    let currencyCode: String

    var body: some View {
        List {
            Section {
                detailRow(.reportSourceDetailKind, value: entry.kind.displayName)
                detailRow(.reportSourceDetailAmount, value: LedgerCurrency.formatSigned(
                    entry.amount,
                    kind: entry.kind,
                    currencyCode: currencyCode
                ))
                detailRow(.reportSourceDetailDate, value: LedgerFormatters.longDay(entry.date))
                detailRow(.reportSourceDetailBook, value: entry.bookName)
                detailRow(.reportSourceDetailCategory, value: entry.categoryName)
                detailRow(.reportSourceDetailAccount, value: entry.accountName)
                if !entry.note.isEmpty {
                    detailRow(.reportSourceDetailNote, value: entry.note)
                }
            } header: {
                Text(.reportSectionSourceEntries)
            }
        }
        .navigationTitle(Text(.reportSourceDetailTitle))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detailRow(_ title: LedgerStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(verbatim: value)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    let persistence = PersistenceController(inMemory: true)
    NavigationStack { DashboardView() }
        .environment(\.managedObjectContext, persistence.container.viewContext)
}
