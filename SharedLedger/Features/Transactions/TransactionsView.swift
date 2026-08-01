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

/// Whether a Core Data change notification touched any object the caller cares about.
///
/// A `TabView` keeps every tab's views alive while another tab is on screen, so an
/// unfiltered subscription re-derives cached state for writes the screen does not
/// depend on — editing an account or a category, for example.
///
/// Only the object's type is inspected, never its properties, so invalidated objects
/// are safe to test here.
private func contextChange(
    _ notification: Notification,
    touches isRelevant: (NSManagedObject) -> Bool
) -> Bool {
    // A context reset reports `NSInvalidatedAllObjectsKey` instead of listing the
    // objects, so there is nothing to match against and it has to count as a hit.
    if notification.userInfo?[NSInvalidatedAllObjectsKey] != nil { return true }

    let changeKeys = [
        NSInsertedObjectsKey,
        NSUpdatedObjectsKey,
        NSDeletedObjectsKey,
        NSRefreshedObjectsKey,
        NSInvalidatedObjectsKey
    ]
    return changeKeys.contains { key in
        guard let objects = notification.userInfo?[key] as? Set<NSManagedObject> else {
            return false
        }
        return objects.contains(where: isRelevant)
    }
}

/// The group, its members, and the private `LocalMemberIdentity` that maps this
/// device's Apple Account onto one of them: everything `TransactionWriteAccess` is
/// resolved from.
private func affectsWriteAccess(_ object: NSManagedObject) -> Bool {
    object is LedgerGroup || object is Member || object is LocalMemberIdentity
}

/// Voided transactions are derived from the group's audit events.
private func affectsVoidedEntries(_ object: NSManagedObject) -> Bool {
    object is AuditEvent
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
    private enum Filter: String, CaseIterable, Identifiable {
        case all = "全部"
        case expense = "支出"
        case income = "收入"
        case transfer = "轉帳"

        var id: Self { self }

        var kind: EntryKind? {
            switch self {
            case .all: return nil
            case .expense: return .expense
            case .income: return .income
            case .transfer: return .transfer
            }
        }
    }

    @ObservedObject var group: LedgerGroup
    let groups: [LedgerGroup]
    @Binding var selectedGroupID: NSManagedObjectID?

    @Environment(\.managedObjectContext) private var context

    @AppStorage private var selectedBookID: String
    @State private var filter: Filter = .all
    @State private var isPresentingNewEntry = false
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

    var body: some View {
        VStack(spacing: 0) {
            header
            if let selectedBook {
                TransactionListView(
                    book: selectedBook,
                    group: group,
                    kind: filter.kind,
                    writeAccess: writeAccess
                ) {
                    isPresentingNewEntry = true
                }
                .id(selectedBook.objectID)
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
        .toolbar {
            if selectedBook != nil, writeAccess.canWrite {
                Button {
                    isPresentingNewEntry = true
                } label: {
                    Image(systemName: "plus")
                        .fontWeight(.bold)
                }
                .accessibilityLabel("新增交易")
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
        .onAppear {
            normalizeSelectedBook()
            reloadWriteAccess()
        }
        .onChange(of: activeBooks.count) {
            normalizeSelectedBook()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .NSManagedObjectContextObjectsDidChange,
                object: context
            )
        ) { notification in
            guard contextChange(notification, touches: affectsWriteAccess) else { return }
            reloadWriteAccess()
        }
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

            Picker("交易類型", selection: $filter) {
                ForEach(Filter.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, LedgerTheme.pagePadding)
        .padding(.top, 12)
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

private struct TransactionListView: View {
    @FetchRequest private var entries: FetchedResults<LedgerEntry>
    /// The book's group, passed in rather than derived from the fetched entries: it
    /// is the same for every row, and reading it back off each entry faults the whole
    /// result set just to rebuild one set of voided ids.
    let group: LedgerGroup
    let writeAccess: TransactionWriteAccess
    let onAddFirst: () -> Void

    @Environment(\.managedObjectContext) private var context

    @State private var voidedEntryIDs: Set<UUID> = []

    init(
        book: LedgerBook,
        group: LedgerGroup,
        kind: EntryKind?,
        writeAccess: TransactionWriteAccess,
        onAddFirst: @escaping () -> Void
    ) {
        self.group = group
        self.writeAccess = writeAccess
        self.onAddFirst = onAddFirst
        let predicate: NSPredicate
        if let kind {
            predicate = NSPredicate(format: "book == %@ AND kind == %@", book, kind.rawValue)
        } else {
            predicate = NSPredicate(format: "book == %@", book)
        }
        _entries = FetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \LedgerEntry.date, ascending: false)],
            predicate: predicate,
            animation: .default
        )
    }

    private var visibleEntries: [LedgerEntry] {
        entries.filter { entry in
            guard let entryID = entry.id else { return true }
            return !voidedEntryIDs.contains(entryID)
        }
    }

    /// Cached rather than computed: `voidedEntryIDs(in:)` hits the store and decodes
    /// a payload per voided transaction. `body` re-runs on every merged CloudKit
    /// change, so recomputing it inline puts that on the render path several times a
    /// second during a sync. The set is the same for every row here, so it is rebuilt
    /// only when an audit event actually changes.
    private func reloadVoidedEntryIDs() {
        voidedEntryIDs = EntryRepository().voidedEntryIDs(in: group)
    }

    private var addAction: (() -> Void)? {
        guard writeAccess.canWrite else { return nil }
        return onAddFirst
    }

    var body: some View {
        // Read once per render: both branches below need it.
        let visible = visibleEntries

        ScrollView {
            LazyVStack(spacing: 12) {
                if let message = writeAccess.noticeMessage {
                    LedgerNotice(message: message)
                }

                if visible.isEmpty {
                    LedgerEmptyState(
                        systemImage: "receipt",
                        title: "沒有有效交易",
                        message: writeAccess.canWrite
                            ? "新增共同收支後，就能在這裡查看、編輯與核對交易。"
                            : "目前還沒有可檢視的交易。",
                        actionTitle: writeAccess.canWrite ? "新增交易" : nil,
                        action: addAction
                    )
                } else {
                    ForEach(visible, id: \.objectID) { entry in
                        NavigationLink {
                            TransactionDetailView(entry: entry)
                        } label: {
                            EntryRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, LedgerTheme.pagePadding)
            .padding(.top, 16)
            .padding(.bottom, 28)
        }
        .onAppear(perform: reloadVoidedEntryIDs)
        .onReceive(
            NotificationCenter.default.publisher(
                for: .NSManagedObjectContextObjectsDidChange,
                object: context
            )
        ) { notification in
            guard contextChange(notification, touches: affectsVoidedEntries) else { return }
            reloadVoidedEntryIDs()
        }
    }
}

private struct EntryRow: View {
    @ObservedObject var entry: LedgerEntry

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
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(amountText)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(amountColor)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
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
            let isRelevant = contextChange(notification) {
                affectsVoidedEntries($0) || affectsWriteAccess($0)
            }
            guard isRelevant else { return }
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

    private var splitModeName: String {
        switch splitMode {
        case .equal: return "平均"
        case .percentage: return "比例"
        case .fixedAmount: return "指定金額"
        }
    }

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
