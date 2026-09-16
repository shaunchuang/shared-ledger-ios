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

    /// Book creation, renaming, reordering and archiving are all ledger settings
    /// changes, so they follow the same effective permission the repository enforces.
    private var settingsRestriction: PermissionError? {
        EffectivePermissionRepository().ledgerSettingsRestriction(in: group)
    }

    /// `nil` disables drag reordering, which is a persisted settings change.
    private var moveBooksHandler: ((IndexSet, Int) -> Void)? {
        guard settingsRestriction == nil else { return nil }
        return moveBooks
    }

    var body: some View {
        ZStack {
            LedgerBackground()
            List {
                if let message = settingsRestriction?.errorDescription {
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
                }

                Section {
                    ForEach(activeBooks, id: \.objectID) { book in
                        activeBookRow(book)
                    }
                    .onMove(perform: moveBooksHandler)
                } header: {
                    Text(.bookSectionActive)
                } footer: {
                    Text(.bookSectionActiveFooter)
                }

                if !archivedBooks.isEmpty {
                    Section {
                        ForEach(archivedBooks, id: \.objectID) { book in
                            NavigationLink {
                                ArchivedBookHistoryView(book: book)
                            } label: {
                                HStack(spacing: 12) {
                                    LedgerIconBadge(systemImage: "archivebox.fill", tint: .secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(verbatim: bookName(book))
                                            .font(.subheadline.weight(.semibold))
                                        Text(.bookArchivedDetail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    } header: {
                        Text(.bookSectionArchived)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(Text(.bookManageTitle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if activeBooks.count > 1, settingsRestriction == nil {
                    EditButton()
                }
                if settingsRestriction == nil {
                    Button {
                        isPresentingNewBook = true
                    } label: {
                        Image(systemName: "plus")
                            .fontWeight(.bold)
                    }
                    .accessibilityLabel(Text(.bookActionAdd))
                }
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
            Text(.bookArchiveConfirmTitle),
            isPresented: archiveConfirmationBinding,
            titleVisibility: .visible,
            presenting: bookPendingArchive
        ) { book in
            Button(role: .destructive) {
                archive(book)
            } label: {
                Text(verbatim: LedgerStringKey.bookArchiveConfirmAction.string(
                    arguments: [bookName(book)]
                ))
            }
            Button(role: .cancel) {} label: {
                Text(.commonActionCancel)
            }
        } message: { _ in
            Text(.bookArchiveConfirmMessage)
        }
        .alert(Text(.bookErrorUpdateTitle), isPresented: errorBinding) {
            Button(role: .cancel) {} label: {
                Text(.commonActionOK)
            }
        } message: {
            Text(verbatim: errorMessage ?? LedgerStringKey.commonErrorRetryLater.string())
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
                        Text(verbatim: bookName(book))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        HStack(spacing: 6) {
                            if isSelected(book) {
                                Text(.bookLabelCurrent)
                                    .foregroundStyle(LedgerTheme.primary)
                            }
                            if book.isDefault {
                                Text(.bookBadgeDefault)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                    }
                    Spacer()
                    if isSelected(book) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(LedgerTheme.primary)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: LedgerStringKey.bookRowAccessibilityLabel.string(
                arguments: [bookName(book)]
            )))
            // 選中與否交給 `.isSelected`，VoiceOver 會自己唸出「已選取」，
            // 不必再塞一個只有選中時才有內容的 value。
            .accessibilityAddTraits(isSelected(book) ? [.isButton, .isSelected] : .isButton)

            if settingsRestriction == nil {
                Menu {
                    if !book.isDefault {
                        Button {
                            setDefault(book)
                        } label: {
                            Label(.bookActionSetDefault, systemImage: "star")
                        }
                    }
                    Button {
                        bookPendingRename = book
                    } label: {
                        Label(.bookActionRename, systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        bookPendingArchive = book
                    } label: {
                        Label(.bookActionArchive, systemImage: "archivebox")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .ledgerTapTarget()
                }
                .accessibilityLabel(Text(.bookMenuAccessibilityLabel))
            }
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

    private func bookName(_ book: LedgerBook) -> String {
        book.name ?? LedgerStringKey.commonPlaceholderUnnamedBook.string()
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
                Section {
                    LabeledContent {
                        Text(.bookSectionArchived)
                    } label: {
                        Text(.bookArchivedSummaryStatus)
                    }
                    LabeledContent {
                        Text(verbatim: categoryCount.formatted())
                    } label: {
                        Text(.bookArchivedSummaryCategories)
                    }
                    LabeledContent {
                        Text(verbatim: entries.count.formatted())
                    } label: {
                        Text(.bookArchivedSummaryEntries)
                    }
                } header: {
                    Text(.bookArchivedSectionSummary)
                }

                Section {
                    if entries.isEmpty {
                        Text(.bookArchivedHistoryEmpty)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(entries, id: \.objectID) { entry in
                            ArchivedBookEntryRow(entry: entry)
                        }
                    }
                } header: {
                    Text(.bookArchivedSectionHistory)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(Text(verbatim: book.name
            ?? LedgerStringKey.bookArchivedTitleFallback.string()))
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

    private var dateText: String {
        entry.date.map { LedgerFormatters.day($0) }
            ?? LedgerStringKey.bookArchivedEntryNoDate.string()
    }

    /// 金額走群組保存的貨幣，不再硬編碼 `$`：這個畫面原本假設所有群組都是美金符號，
    /// 而群組貨幣是建立時就決定的。
    private var amountText: String {
        LedgerCurrency.formatSigned(
            (entry.amount as Decimal?) ?? 0,
            kind: kind,
            currencyCode: LedgerCurrency.normalizedCode(entry.group?.currencyCode)
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            LedgerIconBadge(systemImage: kind.systemImage, tint: kind.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title)
                    .font(.subheadline.weight(.semibold))
                Text(verbatim: dateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(verbatim: amountText)
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
            Section {
                TextField("", text: $draft.name, prompt: Text(.bookNewNamePlaceholder))
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel(Text(.bookFieldName))
            } header: {
                Text(.bookFieldName)
            }

            Section {
                Picker(selection: $categorySetup) {
                    ForEach(NewBookCategorySetup.allCases, id: \.self) { option in
                        Text(option.titleKey).tag(option)
                    }
                } label: {
                    Text(.bookNewFieldCategorySetup)
                }

                if categorySetup == .copyBook {
                    Picker(selection: $sourceBookID) {
                        ForEach(activeBooks, id: \.objectID) { book in
                            Text(verbatim: book.name
                                ?? LedgerStringKey.commonPlaceholderUnnamedBook.string())
                                .tag(book.id)
                        }
                    } label: {
                        Text(.bookNewFieldSourceBook)
                    }
                }
            } header: {
                Text(.bookNewSectionCategories)
            } footer: {
                Text(categorySetup.detailKey)
            }
        }
        .navigationTitle(Text(.bookActionAdd))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: {
                    Text(.commonActionCancel)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: create) {
                    Text(.commonActionAdd)
                }
                .disabled(!draft.canCreate)
            }
        }
        .alert(Text(.bookNewErrorTitle), isPresented: errorBinding) {
            Button(role: .cancel) {} label: {
                Text(.commonActionOK)
            }
        } message: {
            Text(verbatim: errorMessage ?? LedgerStringKey.commonErrorRetryLater.string())
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
                    errorMessage = LedgerStringKey.bookNewErrorMissingSourceBook.string()
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

    var titleKey: LedgerStringKey {
        switch self {
        case .groupCategories: return .bookNewCategorySetupGroupCategories
        case .copyBook: return .bookNewCategorySetupCopyBook
        case .empty: return .bookNewCategorySetupEmpty
        }
    }

    var detailKey: LedgerStringKey {
        switch self {
        case .groupCategories: return .bookNewCategorySetupGroupCategoriesDetail
        case .copyBook: return .bookNewCategorySetupCopyBookDetail
        case .empty: return .bookNewCategorySetupEmptyDetail
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
            Section {
                TextField("", text: $draft.name, prompt: Text(.bookRenameNamePlaceholder))
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel(Text(.bookRenameNamePlaceholder))
            } header: {
                Text(.bookFieldName)
            }
        }
        .navigationTitle(Text(.bookRenameTitle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: {
                    Text(.commonActionCancel)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: save) {
                    Text(.commonActionSave)
                }
                .disabled(!draft.canCreate)
            }
        }
        .alert(Text(.commonErrorRenameFailed), isPresented: errorBinding) {
            Button(role: .cancel) {} label: {
                Text(.commonActionOK)
            }
        } message: {
            Text(verbatim: errorMessage ?? LedgerStringKey.commonErrorRetryLater.string())
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
