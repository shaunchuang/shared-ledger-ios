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

    @AppStorage private var selectedBookID: String
    @State private var filter: Filter = .all
    @State private var isPresentingNewEntry = false

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

    var body: some View {
        VStack(spacing: 0) {
            header
            if let selectedBook {
                TransactionListView(book: selectedBook, kind: filter.kind) {
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
            if selectedBook != nil {
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
        .onAppear(perform: normalizeSelectedBook)
        .onChange(of: activeBooks.count) { _ in
            normalizeSelectedBook()
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
    let onAddFirst: () -> Void

    init(book: LedgerBook, kind: EntryKind?, onAddFirst: @escaping () -> Void) {
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

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if entries.isEmpty {
                    LedgerEmptyState(
                        systemImage: "receipt",
                        title: "帳本還是空的",
                        message: "新增第一筆共同收支，之後就能在這裡快速搜尋、篩選與核對。",
                        actionTitle: "新增第一筆交易",
                        action: onAddFirst
                    )
                } else {
                    ForEach(entries, id: \.objectID) { entry in
                        EntryRow(entry: entry)
                    }
                }
            }
            .padding(.horizontal, LedgerTheme.pagePadding)
            .padding(.top, 16)
            .padding(.bottom, 28)
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
        let amount = (entry.amount as Decimal?) ?? 0
        let absoluteAmount = amount < 0 ? -amount : amount
        let formatted = (absoluteAmount as NSDecimalNumber).stringValue
        switch kind {
        case .income: return "+$\(formatted)"
        case .expense: return "-$\(formatted)"
        case .transfer: return "$\(formatted)"
        case .balanceAdjustment:
            return amount >= 0 ? "+$\(formatted)" : "-$\(formatted)"
        }
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
            }
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
