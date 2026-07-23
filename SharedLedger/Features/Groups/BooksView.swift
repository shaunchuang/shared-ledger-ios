import CoreData
import SwiftUI

struct BooksView: View {
    @ObservedObject var group: LedgerGroup
    @Binding var selectedBookID: String

    @FetchRequest private var books: FetchedResults<LedgerBook>

    private let repository = BookRepository()
    @State private var isPresentingNewBook = false
    @State private var bookPendingRename: LedgerBook?
    @State private var bookPendingArchive: LedgerBook?
    @State private var errorMessage: String?

    init(group: LedgerGroup, selectedBookID: Binding<String>) {
        self.group = group
        _selectedBookID = selectedBookID
        _books = FetchRequest(
            sortDescriptors: [
                NSSortDescriptor(keyPath: \LedgerBook.sortOrder, ascending: true),
                NSSortDescriptor(keyPath: \LedgerBook.createdAt, ascending: true)
            ],
            predicate: NSPredicate(format: "group == %@", group),
            animation: .default
        )
    }

    private var activeBooks: [LedgerBook] {
        books.filter { $0.archivedAt == nil }
    }

    private var archivedBooks: [LedgerBook] {
        books.filter { $0.archivedAt != nil }
    }

    var body: some View {
        ZStack {
            LedgerBackground()
            List {
                Section {
                    ForEach(activeBooks, id: \.objectID) { book in
                        activeBookRow(book)
                    }
                    .onMove(perform: moveBooks)
                } header: {
                    Text("使用中的帳本")
                } footer: {
                    Text("目前帳本決定交易與報表範圍；群組帳戶與分類目錄可供所有帳本共用。")
                }

                if !archivedBooks.isEmpty {
                    Section("已封存") {
                        ForEach(archivedBooks, id: \.objectID) { book in
                            NavigationLink {
                                ArchivedBookHistoryView(book: book)
                            } label: {
                                HStack(spacing: 12) {
                                    LedgerIconBadge(systemImage: "archivebox.fill", tint: .secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(book.name ?? "未命名帳本")
                                            .font(.subheadline.weight(.semibold))
                                        Text("查看保留的分類與交易歷史")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("管理帳本")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if activeBooks.count > 1 {
                    EditButton()
                }
                Button {
                    isPresentingNewBook = true
                } label: {
                    Image(systemName: "plus")
                        .fontWeight(.bold)
                }
                .accessibilityLabel("新增帳本")
            }
        }
        .sheet(isPresented: $isPresentingNewBook) {
            NavigationStack {
                NewBookView(group: group) { book in
                    select(book)
                    isPresentingNewBook = false
                }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $bookPendingRename) { book in
            NavigationStack {
                RenameBookView(book: book) {
                    bookPendingRename = nil
                }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "封存帳本？",
            isPresented: archiveConfirmationBinding,
            titleVisibility: .visible,
            presenting: bookPendingArchive
        ) { book in
            Button("封存「\(book.name ?? "未命名帳本")」", role: .destructive) {
                archive(book)
            }
            Button("取消", role: .cancel) {}
        } message: { book in
            Text("帳本的分類啟用設定與交易都會保留，但不能再新增交易；群組帳戶與分類目錄不受影響。")
        }
        .alert("無法更新帳本", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "請稍後再試。")
        }
        .onAppear(perform: normalizeSelection)
        .onChange(of: activeBooks.count) {
            normalizeSelection()
        }
    }

    private func activeBookRow(_ book: LedgerBook) -> some View {
        HStack(spacing: 10) {
            Button {
                select(book)
            } label: {
                HStack(spacing: 12) {
                    LedgerIconBadge(
                        systemImage: isSelected(book) ? "book.closed.fill" : "book.closed",
                        tint: isSelected(book) ? LedgerTheme.primary : .secondary
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(book.name ?? "未命名帳本")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        HStack(spacing: 6) {
                            if isSelected(book) {
                                Text("目前帳本")
                                    .foregroundStyle(LedgerTheme.primary)
                            }
                            if book.isDefault {
                                Text("預設")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                    }
                    Spacer()
                    if isSelected(book) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(LedgerTheme.primary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("選擇帳本「\(book.name ?? "未命名帳本")」")
            .accessibilityValue(isSelected(book) ? "目前帳本" : "")

            Menu {
                if !book.isDefault {
                    Button {
                        setDefault(book)
                    } label: {
                        Label("設為預設帳本", systemImage: "star")
                    }
                }
                Button {
                    bookPendingRename = book
                } label: {
                    Label("重新命名", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    bookPendingArchive = book
                } label: {
                    Label("封存帳本", systemImage: "archivebox")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 36, height: 44)
            }
            .accessibilityLabel("帳本選項")
        }
    }

    private var archiveConfirmationBinding: Binding<Bool> {
        Binding(
            get: { bookPendingArchive != nil },
            set: { if !$0 { bookPendingArchive = nil } }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func isSelected(_ book: LedgerBook) -> Bool {
        book.id?.uuidString == selectedBookID
    }

    private func select(_ book: LedgerBook) {
        guard book.archivedAt == nil, let id = book.id else { return }
        selectedBookID = id.uuidString
    }

    private func normalizeSelection() {
        guard !activeBooks.isEmpty else { return }
        if activeBooks.contains(where: isSelected) {
            return
        }
        if let defaultBook = activeBooks.first(where: \.isDefault) ?? activeBooks.first {
            select(defaultBook)
        }
    }

    private func setDefault(_ book: LedgerBook) {
        do {
            try repository.setDefaultBook(book)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func moveBooks(from source: IndexSet, to destination: Int) {
        var reordered = activeBooks
        reordered.move(fromOffsets: source, toOffset: destination)
        do {
            try repository.reorderBooks(reordered, in: group)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func archive(_ book: LedgerBook) {
        do {
            let wasSelected = isSelected(book)
            try repository.archiveBook(book)
            bookPendingArchive = nil
            if wasSelected {
                normalizeSelection()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ArchivedBookHistoryView: View {
    @ObservedObject var book: LedgerBook
    @FetchRequest private var entries: FetchedResults<LedgerEntry>

    init(book: LedgerBook) {
        self.book = book
        _entries = FetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \LedgerEntry.date, ascending: false)],
            predicate: NSPredicate(format: "book == %@", book),
            animation: .default
        )
    }

    private var categoryCount: Int {
        Set(entries.compactMap { $0.category?.objectID }).count
    }

    var body: some View {
        ZStack {
            LedgerBackground()
            List {
                Section("摘要") {
                    LabeledContent("狀態", value: "已封存")
                    LabeledContent("分類", value: "\(categoryCount)")
                    LabeledContent("交易", value: "\(entries.count)")
                }

                Section("交易歷史") {
                    if entries.isEmpty {
                        Text("這個帳本沒有交易紀錄。")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(entries, id: \.objectID) { entry in
                            ArchivedBookEntryRow(entry: entry)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(book.name ?? "已封存帳本")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ArchivedBookEntryRow: View {
    @ObservedObject var entry: LedgerEntry

    private var kind: EntryKind {
        EntryKind(rawValue: entry.kind ?? "") ?? .expense
    }

    private var title: String {
        entry.category?.name ?? entry.note ?? kind.displayName
    }

    private var amountText: String {
        let amount = (entry.amount as Decimal?) ?? 0
        let absoluteAmount = amount < 0 ? -amount : amount
        let formatted = (absoluteAmount as NSDecimalNumber).stringValue
        switch kind {
        case .income:
            return "+$\(formatted)"
        case .expense:
            return "-$\(formatted)"
        case .transfer:
            return "$\(formatted)"
        case .balanceAdjustment:
            return amount >= 0 ? "+$\(formatted)" : "-$\(formatted)"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            LedgerIconBadge(systemImage: kind.systemImage, tint: kind.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(entry.date?.formatted(date: .abbreviated, time: .omitted) ?? "日期未設定")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(amountText)
                .font(.subheadline.weight(.bold))
        }
        .accessibilityElement(children: .combine)
    }
}

private struct NewBookView: View {
    @Environment(\.dismiss) private var dismiss

    let group: LedgerGroup
    let onCreated: (LedgerBook) -> Void

    @State private var draft = BookDraft()
    @State private var categorySetup: NewBookCategorySetup = .groupCategories
    @State private var sourceBookID: UUID?
    @State private var errorMessage: String?

    private var activeBooks: [LedgerBook] {
        BookRepository().books(in: group)
    }

    var body: some View {
        Form {
            Section("名稱") {
                TextField("例如：日本旅行", text: $draft.name)
                    .textInputAutocapitalization(.never)
            }

            Section {
                Picker("分類設定", selection: $categorySetup) {
                    ForEach(NewBookCategorySetup.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }

                if categorySetup == .copyBook {
                    Picker("沿用帳本", selection: $sourceBookID) {
                        ForEach(activeBooks, id: \.objectID) { book in
                            Text(book.name ?? "未命名帳本").tag(book.id)
                        }
                    }
                }
            } header: {
                Text("可用分類")
            } footer: {
                Text(categorySetup.detail)
            }
        }
        .navigationTitle("新增帳本")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("新增", action: create)
                    .disabled(!draft.canCreate)
            }
        }
        .alert("無法新增帳本", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "請稍後再試。")
        }
        .onAppear {
            if sourceBookID == nil {
                sourceBookID = activeBooks.first(where: \.isDefault)?.id ?? activeBooks.first?.id
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func create() {
        do {
            let categorySource: BookCategorySource
            switch categorySetup {
            case .groupCategories:
                categorySource = .allGroupCategories
            case .copyBook:
                guard let sourceBook = activeBooks.first(where: { $0.id == sourceBookID }) else {
                    errorMessage = "請選擇要沿用分類設定的帳本。"
                    return
                }
                categorySource = .copy(sourceBook)
            case .empty:
                categorySource = .empty
            }
            let book = try BookRepository().createBook(
                from: draft,
                in: group,
                categorySource: categorySource
            )
            onCreated(book)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum NewBookCategorySetup: String, CaseIterable {
    case groupCategories
    case copyBook
    case empty

    var title: String {
        switch self {
        case .groupCategories:
            return "使用所有群組分類"
        case .copyBook:
            return "沿用其他帳本"
        case .empty:
            return "空白開始"
        }
    }

    var detail: String {
        switch self {
        case .groupCategories:
            return "預設啟用群組目前所有未封存分類。"
        case .copyBook:
            return "沿用另一個帳本的啟用設定，不會複製分類資料。"
        case .empty:
            return "建立後再到帳本設定選擇要使用的分類。"
        }
    }
}

private struct RenameBookView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var book: LedgerBook
    let onSaved: () -> Void

    @State private var draft: BookDraft
    @State private var errorMessage: String?

    init(book: LedgerBook, onSaved: @escaping () -> Void) {
        self.book = book
        self.onSaved = onSaved
        _draft = State(initialValue: BookDraft(name: book.name ?? ""))
    }

    var body: some View {
        Form {
            Section("名稱") {
                TextField("帳本名稱", text: $draft.name)
                    .textInputAutocapitalization(.never)
            }
        }
        .navigationTitle("重新命名帳本")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("儲存", action: save)
                    .disabled(!draft.canCreate)
            }
        }
        .alert("無法重新命名", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "請稍後再試。")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func save() {
        do {
            try BookRepository().renameBook(book, using: draft)
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
