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
                        title: "先建立一個群組",
                        message: "建立群組並開始記帳後，這裡會顯示跨帳本的真實收支統計。"
                    )
                    .padding(.horizontal, LedgerTheme.pagePadding)
                    .padding(.top, 24)
                }
            }
        }
        .navigationTitle("總覽")
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
        month.formatted(.dateTime.year().month(.wide))
    }

    private var scopeDetail: String {
        switch scope {
        case .allActiveBooks:
            return "\(snapshot.includedBookIDs.count) 本使用中帳本"
        case .currentBook:
            return selectedBook?.name ?? "未選擇帳本"
        case .selectedBookIDs:
            return "已選 \(snapshot.includedBookIDs.count) 本帳本"
        }
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
                        title: "這個範圍還沒有收支",
                        message: "目前月份與帳本範圍沒有收入或支出；轉帳與餘額調整不會列入期間收支。"
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
                                if candidate.objectID == group.objectID {
                                    Label(candidate.name ?? "未命名群組", systemImage: "checkmark")
                                } else {
                                    Text(candidate.name ?? "未命名群組")
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(group.name ?? "未命名群組")
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2.weight(.bold))
                        }
                        .font(.headline)
                        .foregroundStyle(.primary)
                    }
                    .accessibilityLabel("切換群組")
                } else {
                    Text(group.name ?? "未命名群組")
                        .font(.headline)
                }
                Text("跨帳本共同收支")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(currencyCode)
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
                            .frame(width: 34, height: 34)
                    }
                    .accessibilityLabel("上一個月")

                    Spacer()
                    VStack(spacing: 2) {
                        Text(monthLabel)
                            .font(.headline)
                        Text(scopeDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()

                    Button {
                        shiftMonth(by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .frame(width: 34, height: 34)
                    }
                    .accessibilityLabel("下一個月")
                }

                Picker("統計範圍", selection: $scope) {
                    ForEach(ReportBookScope.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                if scope == .currentBook, let selectedBook {
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
                } else if scope == .selectedBookIDs {
                    Button {
                        isPresentingBookSelection = true
                    } label: {
                        selectorLabel("選擇帳本（\(selectedCustomBookIDs.count)）", systemImage: "checklist")
                    }
                }
            }
        }
    }

    private var expenseHero: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label("期間共同支出", systemImage: "calendar")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.80))
                Spacer()
                Text(scope.displayName)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.86))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.12), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(LedgerCurrency.format(snapshot.expense, currencyCode: currencyCode))
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text("收入 \(LedgerCurrency.format(snapshot.income, currencyCode: currencyCode)) · 淨額 \(formattedNet)")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.74))
            }

            HStack(spacing: 8) {
                statCapsule(title: "交易", value: "\(snapshot.entries.count) 筆")
                statCapsule(title: "帳本", value: "\(snapshot.includedBookIDs.count) 本")
                statCapsule(title: "分類", value: "\(snapshot.categories.count) 類")
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
        HStack(spacing: 12) {
            NavigationLink {
                ReportSourceListView(
                    title: "期間收入",
                    entries: snapshot.entries.filter { $0.kind == .income },
                    currencyCode: currencyCode
                )
            } label: {
                MetricTile(
                    title: "期間收入",
                    value: LedgerCurrency.format(snapshot.income, currencyCode: currencyCode),
                    detail: "點擊核對來源",
                    systemImage: "arrow.down.left",
                    tint: LedgerTheme.primary
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                ReportSourceListView(
                    title: "期間淨額",
                    entries: snapshot.entries,
                    currencyCode: currencyCode
                )
            } label: {
                MetricTile(
                    title: "收支淨額",
                    value: formattedNet,
                    detail: snapshot.net >= 0 ? "收入高於支出" : "支出高於收入",
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
                VStack(alignment: .leading, spacing: 4) {
                    Text("群組帳戶餘額")
                        .font(.subheadline.weight(.semibold))
                    Text("包含所有帳本交易與帳戶餘額調整，不受上方月份與帳本範圍影響")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Text(LedgerCurrency.format(snapshot.accountBalance, currencyCode: currencyCode))
                    .font(.headline.monospacedDigit())
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LedgerSectionHeader(title: "分類統計")
            LedgerCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(snapshot.categories.enumerated()), id: \.element.id) { index, category in
                        NavigationLink {
                            ReportSourceListView(
                                title: category.name,
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
            LedgerSectionHeader(title: "帳本貢獻")
            LedgerCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(snapshot.books.enumerated()), id: \.element.id) { index, book in
                        NavigationLink {
                            ReportSourceListView(
                                title: book.name,
                                entries: snapshot.entries.filter { $0.bookID == book.bookID },
                                currencyCode: currencyCode
                            )
                        } label: {
                            HStack(spacing: 12) {
                                LedgerIconBadge(systemImage: "book.closed.fill")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(book.name)
                                        .font(.subheadline.weight(.semibold))
                                    Text("收入 \(LedgerCurrency.format(book.income, currencyCode: currencyCode)) · 支出 \(LedgerCurrency.format(book.expense, currencyCode: currencyCode))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Text("佔總支出 \(ReportShare.formatted(book.expenseShare))")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Text(LedgerCurrency.format(book.net, currencyCode: currencyCode, showPositiveSign: true))
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(16)
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
                LedgerSectionHeader(title: "來源交易")
                Spacer()
                NavigationLink("查看全部") {
                    ReportSourceListView(
                        title: "來源交易",
                        entries: snapshot.entries,
                        currencyCode: currencyCode
                    )
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
                                Text(book.name ?? "未命名帳本")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: isCustomBookSelected(book) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isCustomBookSelected(book) ? LedgerTheme.primary : .tertiary)
                            }
                        }
                    }
                } footer: {
                    Text("自選範圍只會包含目前使用中的同群組帳本；封存帳本不會被默默納入。")
                }
            }
            .navigationTitle("選擇統計帳本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { isPresentingBookSelection = false }
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
            HStack {
                Text(category.name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(LedgerCurrency.format(category.expense, currencyCode: currencyCode))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            ProgressView(value: fraction)
                .tint(LedgerTheme.primary)
            HStack(spacing: 6) {
                Text("佔總支出 \(ReportShare.formatted(category.expenseShare))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if category.income > 0 {
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("收入 \(LedgerCurrency.format(category.income, currencyCode: currencyCode))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
    }

    private func statCapsule(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))
            Text(value)
                .font(.caption.weight(.bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private func selectorLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
            Text(title)
                .lineLimit(1)
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.bold))
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(LedgerTheme.primary)
        .padding(.horizontal, 12)
        .frame(minHeight: 42)
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
    let title: String
    let value: String
    let detail: String
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
                    Text(value)
                        .font(.title3.weight(.bold).monospacedDigit())
                        .minimumScaleFactor(0.75)
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
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
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.note.isEmpty ? entry.categoryName : entry.note)
                    .font(.subheadline.weight(.semibold))
                Text("\(entry.bookName) · \(entry.date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(reportAmount(entry.amount, kind: entry.kind, currencyCode: currencyCode))
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(entry.kind == .income ? LedgerTheme.primary : LedgerTheme.coral)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct ReportSourceListView: View {
    let title: String
    let entries: [GroupReportSourceEntry]
    let currencyCode: String

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView(
                    "沒有來源交易",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("目前範圍沒有符合條件的收入或支出。")
                )
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
            Section("來源交易") {
                detailRow("類型", value: entry.kind.displayName)
                detailRow("金額", value: reportAmount(entry.amount, kind: entry.kind, currencyCode: currencyCode))
                detailRow("日期", value: entry.date.formatted(date: .long, time: .omitted))
                detailRow("帳本", value: entry.bookName)
                detailRow("分類", value: entry.categoryName)
                detailRow("帳戶", value: entry.accountName)
                if !entry.note.isEmpty {
                    detailRow("備註", value: entry.note)
                }
            }
        }
        .navigationTitle("交易核對")
        .navigationBarTitleDisplayMode(.inline)
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
}

enum ReportBookScope: String, CaseIterable, Identifiable, Sendable {
    case allActiveBooks
    case currentBook
    case selectedBookIDs

    var id: Self { self }

    var displayName: String {
        switch self {
        case .allActiveBooks: return "全部帳本"
        case .currentBook: return "目前帳本"
        case .selectedBookIDs: return "自選帳本"
        }
    }
}

struct GroupReportCategorySummary: Identifiable, Equatable, Sendable {
    let id: String
    let categoryID: UUID?
    let name: String
    let income: Decimal
    let expense: Decimal
    /// 這個分類佔期間總支出的比例，範圍 0...1；總支出為 0 時為 0。
    let expenseShare: Decimal
}

struct GroupReportBookSummary: Identifiable, Equatable, Sendable {
    let id: String
    let bookID: UUID
    let name: String
    let income: Decimal
    let expense: Decimal
    /// 這個帳本佔期間總支出的比例，範圍 0...1；總支出為 0 時為 0。
    let expenseShare: Decimal

    var net: Decimal { income - expense }
}

enum ReportShare {
    /// 佔比一律以期間總支出為分母，讓分類與帳本的比例可以直接互相對照。
    /// 總支出為 0（例如只有收入）時回傳 0，而不是製造一個無意義的分母。
    static func share(of amount: Decimal, in total: Decimal) -> Decimal {
        guard total > 0, amount > 0 else { return 0 }
        return amount / total
    }

    static func formatted(_ share: Decimal) -> String {
        let percentage = NSDecimalNumber(decimal: share * 100).doubleValue
        return String(format: "%.1f%%", percentage)
    }
}

struct GroupReportSourceEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let bookID: UUID
    let bookName: String
    let categoryID: UUID?
    let categoryName: String
    let kind: EntryKind
    let amount: Decimal
    let date: Date
    let note: String
    let accountName: String
}

struct GroupReportSnapshot: Equatable, Sendable {
    let interval: DateInterval
    let includedBookIDs: [UUID]
    let income: Decimal
    let expense: Decimal
    let accountBalance: Decimal
    let categories: [GroupReportCategorySummary]
    let books: [GroupReportBookSummary]
    let entries: [GroupReportSourceEntry]

    var net: Decimal { income - expense }

    static let empty = GroupReportSnapshot(
        interval: DateInterval(start: .distantPast, duration: 0),
        includedBookIDs: [],
        income: 0,
        expense: 0,
        accountBalance: 0,
        categories: [],
        books: [],
        entries: []
    )
}

@MainActor
struct GroupReportService {
    private let persistence: PersistenceController

    init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    func snapshot(
        in group: LedgerGroup,
        interval: DateInterval,
        scope: ReportBookScope,
        currentBook: LedgerBook?,
        selectedBookIDs: Set<UUID> = []
    ) -> GroupReportSnapshot {
        let activeBooks = BookRepository(persistence: persistence).books(in: group)
        let includedBooks: [LedgerBook]

        switch scope {
        case .allActiveBooks:
            includedBooks = activeBooks
        case .currentBook:
            if let currentBook,
               currentBook.group == group,
               currentBook.archivedAt == nil {
                includedBooks = [currentBook]
            } else {
                includedBooks = []
            }
        case .selectedBookIDs:
            includedBooks = activeBooks.filter { book in
                guard let id = book.id else { return false }
                return selectedBookIDs.contains(id)
            }
        }

        let includedObjectIDs = Set(includedBooks.map(\.objectID))
        let voidedEntryIDs = EntryRepository(persistence: persistence).voidedEntryIDs(in: group)
        let entries = (group.entries as? Set<LedgerEntry> ?? [])
            .filter { entry in
                // DateInterval.contains 含右端點，會讓剛好落在下個月 1 日 00:00:00
                // 的交易同時被算進兩個月，所以這裡自行做左閉右開判斷。
                guard let book = entry.book,
                      includedObjectIDs.contains(book.objectID),
                      let date = entry.date,
                      date >= interval.start, date < interval.end,
                      let kind = entry.kind.flatMap(EntryKind.init(rawValue:)),
                      kind == .income || kind == .expense
                else { return false }

                if let entryID = entry.id, voidedEntryIDs.contains(entryID) {
                    return false
                }
                return true
            }
            .sorted { lhs, rhs in
                let lhsDate = lhs.date ?? .distantPast
                let rhsDate = rhs.date ?? .distantPast
                if lhsDate == rhsDate {
                    return (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast)
                }
                return lhsDate > rhsDate
            }

        var income = Decimal.zero
        var expense = Decimal.zero
        var categoryTotals: [String: MutableCategorySummary] = [:]
        var bookTotals: [UUID: MutableBookSummary] = [:]
        var sourceEntries: [GroupReportSourceEntry] = []

        for entry in entries {
            guard let kind = entry.kind.flatMap(EntryKind.init(rawValue:)),
                  let book = entry.book,
                  let bookID = book.id,
                  let entryID = entry.id,
                  let date = entry.date
            else { continue }

            let amount = (entry.amount as Decimal?) ?? 0
            guard amount >= 0 else { continue }

            if kind == .income {
                income += amount
            } else {
                expense += amount
            }

            let categoryID = entry.category?.id
            let categoryKey = categoryID?.uuidString ?? "uncategorized"
            var category = categoryTotals[categoryKey] ?? MutableCategorySummary(
                categoryID: categoryID,
                name: entry.category?.name ?? "未分類"
            )
            if kind == .income {
                category.income += amount
            } else {
                category.expense += amount
            }
            categoryTotals[categoryKey] = category

            var bookSummary = bookTotals[bookID] ?? MutableBookSummary(
                bookID: bookID,
                name: book.name ?? "未命名帳本"
            )
            if kind == .income {
                bookSummary.income += amount
            } else {
                bookSummary.expense += amount
            }
            bookTotals[bookID] = bookSummary

            sourceEntries.append(
                GroupReportSourceEntry(
                    id: entryID,
                    bookID: bookID,
                    bookName: book.name ?? "未命名帳本",
                    categoryID: categoryID,
                    categoryName: entry.category?.name ?? "未分類",
                    kind: kind,
                    amount: amount,
                    date: date,
                    note: entry.note ?? "",
                    accountName: entry.sourceAccount?.name ?? "-"
                )
            )
        }

        let categories = categoryTotals
            .map { key, summary in
                GroupReportCategorySummary(
                    id: key,
                    categoryID: summary.categoryID,
                    name: summary.name,
                    income: summary.income,
                    expense: summary.expense,
                    expenseShare: ReportShare.share(of: summary.expense, in: expense)
                )
            }
            .sorted { lhs, rhs in
                if lhs.expense != rhs.expense { return lhs.expense > rhs.expense }
                if lhs.income != rhs.income { return lhs.income > rhs.income }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }

        let bookOrder = Dictionary(uniqueKeysWithValues: includedBooks.enumerated().compactMap { index, book in
            book.id.map { ($0, index) }
        })
        let books = bookTotals.values
            .map { summary in
                GroupReportBookSummary(
                    id: summary.bookID.uuidString,
                    bookID: summary.bookID,
                    name: summary.name,
                    income: summary.income,
                    expense: summary.expense,
                    expenseShare: ReportShare.share(of: summary.expense, in: expense)
                )
            }
            .sorted { lhs, rhs in
                let lhsOrder = bookOrder[lhs.bookID] ?? Int.max
                let rhsOrder = bookOrder[rhs.bookID] ?? Int.max
                if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }

        let accounts = Array(group.accounts as? Set<LedgerAccount> ?? [])
        let accountBalance = AccountRepository(persistence: persistence).totalBalance(for: accounts)

        return GroupReportSnapshot(
            interval: interval,
            includedBookIDs: includedBooks.compactMap(\.id),
            income: income,
            expense: expense,
            accountBalance: accountBalance,
            categories: categories,
            books: books,
            entries: sourceEntries
        )
    }

    private struct MutableCategorySummary {
        let categoryID: UUID?
        let name: String
        var income: Decimal = 0
        var expense: Decimal = 0
    }

    private struct MutableBookSummary {
        let bookID: UUID
        let name: String
        var income: Decimal = 0
        var expense: Decimal = 0
    }
}

private func reportAmount(_ amount: Decimal, kind: EntryKind, currencyCode: String) -> String {
    switch kind {
    case .income:
        return LedgerCurrency.format(amount, currencyCode: currencyCode, showPositiveSign: true)
    case .expense:
        return LedgerCurrency.format(-amount, currencyCode: currencyCode)
    case .transfer, .balanceAdjustment:
        return LedgerCurrency.format(amount, currencyCode: currencyCode)
    }
}

#Preview {
    let persistence = PersistenceController(inMemory: true)
    NavigationStack { DashboardView() }
        .environment(\.managedObjectContext, persistence.container.viewContext)
}
