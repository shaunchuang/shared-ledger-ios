import CoreData
import SwiftUI

struct CategoriesRootView: View {
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \LedgerGroup.updatedAt, ascending: false)],
        animation: .default
    ) private var groups: FetchedResults<LedgerGroup>

    @State private var selectedGroupID: NSManagedObjectID?

    private var selectedGroup: LedgerGroup? {
        if let selectedGroupID,
           let match = groups.first(where: { $0.objectID == selectedGroupID }) {
            return match
        }
        return groups.first
    }

    var body: some View {
        Group {
            if let group = selectedGroup {
                CategoriesView(group: group)
                    .id(group.objectID)
                    .toolbar {
                        if groups.count > 1 {
                            ToolbarItem(placement: .topBarLeading) {
                                groupSelector(selectedGroup: group)
                            }
                        }
                    }
            } else {
                ZStack {
                    LedgerBackground()
                    ScrollView {
                        LedgerEmptyState(
                            systemImage: "square.grid.2x2",
                            title: .categoryGroupEmptyTitle,
                            message: .categoryGroupEmptyMessage
                        )
                        .padding(.horizontal, LedgerTheme.pagePadding)
                        .padding(.top, 24)
                    }
                }
                .navigationTitle(Text(.categoryTitle))
            }
        }
    }

    private func groupSelector(selectedGroup: LedgerGroup) -> some View {
        Menu {
            ForEach(Array(groups), id: \.objectID) { candidate in
                Button {
                    selectedGroupID = candidate.objectID
                } label: {
                    let name = candidate.name
                        ?? LedgerStringKey.commonPlaceholderUnnamedGroup.string()
                    if candidate == selectedGroup {
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
            Label {
                Text(verbatim: selectedGroup.name
                    ?? LedgerStringKey.commonPlaceholderUnnamedGroup.string())
            } icon: {
                Image(systemName: "person.3.fill")
            }
            .labelStyle(.titleAndIcon)
        }
        .accessibilityLabel(Text(.categoryGroupPickerAccessibilityLabel))
        .accessibilityValue(Text(verbatim: selectedGroup.name
            ?? LedgerStringKey.commonPlaceholderUnnamedGroup.string()))
    }
}

/// 群組分類管理畫面上那三張表單。
///
/// 它們必須共用一個狀態：SwiftUI 只保證同一個畫面掛一個 `.sheet`，三個 `.sheet` 疊在
/// 同一層時後面的會蓋掉前面的，先掛上去的「新增分類」因此按了沒反應。用單一路由狀態
/// 驅動唯一的 `.sheet`，順便讓每次開啟都帶著當下選到的父分類，而不是另一個 `@State`
/// 裡上一次留下來的值。
enum CategorySheetRoute: Identifiable {
    /// `parent` 為 `nil` 代表新增最上層分類。
    case newCategory(parent: LedgerCategory?)
    case rename(LedgerCategory)
    case merge(LedgerCategory)

    /// 同一個分類在不同表單、以及不同父分類底下的新增，都要是不同的 identity，
    /// 否則 `.sheet(item:)` 會沿用上一張表單而不是換一張。
    var id: String {
        switch self {
        case let .newCategory(parent):
            guard let parent else { return "new:root" }
            return "new:\(Self.identifier(parent))"
        case let .rename(category):
            return "rename:\(Self.identifier(category))"
        case let .merge(category):
            return "merge:\(Self.identifier(category))"
        }
    }

    private static func identifier(_ category: LedgerCategory) -> String {
        category.objectID.uriRepresentation().absoluteString
    }
}

enum CategoryRowAction: Hashable {
    case rename
    case addChild
    case move(Int)
    case merge
    case archive
}

/// iOS 26 的原生 `Menu` 在這個 ScrollView 裡會顯示項目，卻可能完全不送出按鈕動作。
/// 改用 popover 後，先記住使用者選到的動作並關閉 popover；等內容真的消失才取出動作，
/// 避免在兩個 presentation 還重疊時開 sheet 或 confirmation dialog。
final class CategoryRowActionCoordinator: ObservableObject {
    @Published var isPresented = false
    private(set) var pendingAction: CategoryRowAction?

    func present() {
        pendingAction = nil
        isPresented = true
    }

    func select(_ action: CategoryRowAction) {
        pendingAction = action
        isPresented = false
    }

    func takePendingAction() -> CategoryRowAction? {
        defer { pendingAction = nil }
        return pendingAction
    }
}

struct CategoriesView: View {
    @ObservedObject var group: LedgerGroup

    @FetchRequest private var rootCategories: FetchedResults<LedgerCategory>

    /// 三張表單共用同一個狀態，因為畫面只掛得住一個 `.sheet`。
    @State private var sheetRoute: CategorySheetRoute?
    @State private var categoryPendingArchive: LedgerCategory?
    @State private var errorMessage: String?
    /// 排序寫在子分類上，父層的 FetchRequest 不會因此重新計算，所以用它強制重畫。
    @State private var revision = 0

    init(group: LedgerGroup) {
        self.group = group
        _rootCategories = FetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \LedgerCategory.sortOrder, ascending: true)],
            predicate: NSPredicate(format: "group == %@ AND archivedAt == nil AND parent == nil", group),
            animation: .default
        )
    }

    private var manageRestriction: PermissionError? {
        EffectivePermissionRepository().ledgerSettingsRestriction(in: group)
    }

    private var canManage: Bool { manageRestriction == nil }

    var body: some View {
        ZStack {
            LedgerBackground()
            ScrollView {
                VStack(spacing: 16) {
                    if let message = manageRestriction?.errorDescription {
                        LedgerNotice(message: message)
                    }

                    if rootCategories.isEmpty {
                        LedgerEmptyState(
                            systemImage: "square.grid.2x2",
                            title: .categoryEmptyTitle,
                            message: .categoryEmptyMessage,
                            actionTitle: canManage ? LedgerStringKey.categoryNewActionAdd : nil,
                            action: canManage ? presentRootCategory : nil
                        )

                        if canManage {
                            Button(action: installDefaults) {
                                Label(.categoryActionInstallDefaults, systemImage: "square.grid.2x2.fill")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(LedgerTheme.primary)
                        }
                    } else {
                        LedgerCard {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(rootCategories), id: \.objectID) { category in
                                    GroupCategoryTreeRow(
                                        category: category,
                                        depth: 0,
                                        canManage: canManage,
                                        onAddChild: { sheetRoute = .newCategory(parent: $0) },
                                        onRename: { sheetRoute = .rename($0) },
                                        onMerge: { sheetRoute = .merge($0) },
                                        onMove: move,
                                        onArchive: requestArchive
                                    )
                                }
                            }
                            .id(revision)
                        }
                    }

                    Text(.categoryFooter)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, LedgerTheme.pagePadding)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle(Text(.categoryTitle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canManage {
                Button(action: presentRootCategory) {
                    Image(systemName: "plus")
                        .fontWeight(.bold)
                }
                .accessibilityLabel(Text(.categoryActionAddGroupCategory))
            }
        }
        .sheet(item: $sheetRoute) { route in
            switch route {
            case let .newCategory(parent):
                NavigationStack {
                    NewCategoryView(group: group, parent: parent) {
                        dismissSheet()
                    }
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            case let .rename(category):
                NavigationStack {
                    RenameCategoryView(category: category) {
                        dismissSheet()
                    }
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            case let .merge(category):
                NavigationStack {
                    MergeCategoryView(category: category) {
                        dismissSheet()
                    }
                }
                .presentationDragIndicator(.visible)
            }
        }
        .confirmationDialog(
            Text(.categoryArchiveConfirmTitle),
            isPresented: archiveConfirmationBinding,
            titleVisibility: .visible,
            presenting: categoryPendingArchive
        ) { category in
            Button(role: .destructive) {
                categoryPendingArchive = nil
                archive(category)
            } label: {
                Text(verbatim: LedgerStringKey.categoryArchiveConfirmAction.string(
                    arguments: [categoryName(category)]
                ))
            }
            Button(role: .cancel) {
                categoryPendingArchive = nil
            } label: {
                Text(.commonActionCancel)
            }
        } message: { category in
            // 影響說明由 `CategoryRepository` 產生，那一層還沒遷移；它是這句話的參數，
            // 不是自己接在後面的另一句。
            Text(verbatim: LedgerStringKey.categoryArchiveConfirmMessage.string(
                arguments: [CategoryRepository().impact(of: category).summary]
            ))
        }
        .alert(Text(.categoryErrorUpdateTitle), isPresented: errorBinding) {
            Button(role: .cancel) {} label: {
                Text(.commonActionOK)
            }
        } message: {
            Text(verbatim: errorMessage ?? LedgerStringKey.commonErrorRetryLater.string())
        }
    }

    private func categoryName(_ category: LedgerCategory) -> String {
        category.name ?? LedgerStringKey.commonPlaceholderUnnamedCategory.string()
    }

    private var archiveConfirmationBinding: Binding<Bool> {
        Binding(
            get: { categoryPendingArchive != nil },
            set: { if !$0 { categoryPendingArchive = nil } }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func presentRootCategory() {
        sheetRoute = .newCategory(parent: nil)
    }

    /// 新增、改名與合併都會動到子分類那一層，父層的 FetchRequest 不會因此重新計算，
    /// 所以關掉表單時一併強制重畫，新增的子分類才會馬上出現在樹狀清單裡。
    private func dismissSheet() {
        sheetRoute = nil
        revision += 1
    }

    private func requestArchive(_ category: LedgerCategory) {
        categoryPendingArchive = category
    }

    private func archive(_ category: LedgerCategory) {
        do {
            try CategoryRepository().archiveCategory(category)
            revision += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func installDefaults() {
        do {
            try CategoryRepository().installDefaultCategories(in: group)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 只在同一層之間搬動。跨層搬動等於改變父子關係，那是合併要處理的事。
    private func move(_ category: LedgerCategory, by offset: Int) {
        guard let group = category.group else { return }
        let repository = CategoryRepository()
        var siblings = repository.siblings(of: category.parent, in: group)
        guard let index = siblings.firstIndex(of: category),
              siblings.indices.contains(index + offset)
        else { return }

        siblings.swapAt(index, index + offset)
        do {
            try repository.reorderCategories(siblings, parent: category.parent, in: group)
            revision += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct BookCategoriesView: View {
    @ObservedObject var book: LedgerBook

    @FetchRequest private var rootCategories: FetchedResults<LedgerCategory>

    @State private var errorMessage: String?
    @State private var isPresentingNewCategory = false
    @State private var revision = 0

    init(book: LedgerBook) {
        self.book = book
        _rootCategories = FetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \LedgerCategory.sortOrder, ascending: true)],
            predicate: book.group.map {
                NSPredicate(format: "group == %@ AND archivedAt == nil AND parent == nil", $0)
            } ?? NSPredicate(value: false),
            animation: .default
        )
    }

    private var manageRestriction: PermissionError? {
        guard let group = book.group else { return .missingCurrentMember }
        return EffectivePermissionRepository().ledgerSettingsRestriction(in: group)
    }

    private var canManage: Bool { manageRestriction == nil }

    /// FetchRequest 負責讓畫面跟著資料變動重畫，順序則交給帳本自己的設定。
    private var orderedRootCategories: [LedgerCategory] {
        let fetched = Set(rootCategories.map(\.objectID))
        return CategoryRepository()
            .manageableSiblings(of: nil, in: book)
            .filter { fetched.contains($0.objectID) }
    }

    var body: some View {
        ZStack {
            LedgerBackground()
            ScrollView {
                VStack(spacing: 16) {
                    if let message = manageRestriction?.errorDescription {
                        LedgerNotice(message: message)
                    }

                    if rootCategories.isEmpty {
                        LedgerEmptyState(
                            systemImage: "square.grid.2x2",
                            title: .categoryBookEmptyTitle,
                            message: .categoryBookEmptyMessage,
                            actionTitle: nil,
                            action: nil
                        )
                    } else {
                        LedgerCard {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(orderedRootCategories, id: \.objectID) { category in
                                    BookCategoryToggleRow(
                                        category: category,
                                        book: book,
                                        depth: 0,
                                        canManage: canManage,
                                        onError: { errorMessage = $0 },
                                        onUpdated: { revision += 1 },
                                        onMove: move
                                    )
                                }
                            }
                            .id(revision)
                        }
                    }

                    Text(.categoryBookFooter)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, LedgerTheme.pagePadding)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle(Text(.categoryBookTitle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canManage, book.group != nil {
                Button {
                    isPresentingNewCategory = true
                } label: {
                    Image(systemName: "plus")
                        .fontWeight(.bold)
                }
                .accessibilityLabel(Text(.categoryNewActionAdd))
            }
        }
        .sheet(isPresented: $isPresentingNewCategory) {
            if let group = book.group {
                NavigationStack {
                    NewCategoryView(group: group, book: book, parent: nil) {
                        isPresentingNewCategory = false
                        revision += 1
                    }
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
        .alert(Text(.categoryBookErrorTitle), isPresented: errorBinding) {
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

    /// 只搬動這本帳本的顯示順序，群組目錄與其他帳本不受影響。
    private func move(_ category: LedgerCategory, by offset: Int) {
        let repository = CategoryRepository()
        var siblings = repository.enabledSiblings(of: category.parent, in: book)
        guard let index = siblings.firstIndex(of: category),
              siblings.indices.contains(index + offset)
        else { return }

        siblings.swapAt(index, index + offset)
        do {
            try repository.reorderCategories(siblings, parent: category.parent, in: book)
            revision += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct GroupCategoryTreeRow: View {
    @ObservedObject var category: LedgerCategory
    let depth: Int
    let canManage: Bool
    let onAddChild: (LedgerCategory) -> Void
    let onRename: (LedgerCategory) -> Void
    let onMerge: (LedgerCategory) -> Void
    let onMove: (LedgerCategory, Int) -> Void
    let onArchive: (LedgerCategory) -> Void

    /// 子分類前面那個小圓點是跟著名稱走的層級記號，字放大時它也要放大，
    /// 否則在大字級下小到看不見。
    @ScaledMetric(relativeTo: .subheadline) private var depthMarkerScale: CGFloat = 1
    @StateObject private var actionCoordinator = CategoryRowActionCoordinator()

    private var children: [LedgerCategory] {
        guard let group = category.group else { return [] }
        return CategoryRepository().siblings(of: category, in: group)
    }

    private var siblings: [LedgerCategory] {
        guard let group = category.group else { return [] }
        return CategoryRepository().siblings(of: category.parent, in: group)
    }

    private var siblingIndex: Int? {
        siblings.firstIndex(of: category)
    }

    private var name: String {
        category.name ?? LedgerStringKey.commonPlaceholderUnnamedCategory.string()
    }

    private var enabledBookCount: Int {
        let assignments = category.bookAssignments as? Set<BookCategoryAssignment> ?? []
        return assignments.filter { $0.isEnabled && $0.book?.archivedAt == nil }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 5 * depthMarkerScale))
                    .foregroundStyle(.tertiary)
                    .opacity(depth > 0 ? 1 : 0)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: name)
                        .font(.subheadline.weight(depth == 0 ? .semibold : .regular))
                    Text(verbatim: LedgerStringKey.categoryRowEnabledBooks.string(
                        arguments: [Int64(enabledBookCount)]
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Spacer()
                if canManage {
                    // 一列可以做的事已經超過兩個圖示放得下的數量，收進動作面板也讓
                    // VoiceOver 讀得到每個動作的名稱，而不是一排看不懂的圖示。
                    Button {
                        actionCoordinator.present()
                    } label: {
                        Image(systemName: "ellipsis")
                            .ledgerTapTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: LedgerStringKey
                        .categoryMenuAccessibilityLabel.string(arguments: [name])))
                    .popover(
                        isPresented: $actionCoordinator.isPresented,
                        attachmentAnchor: .rect(.bounds)
                    ) {
                        GroupCategoryActionPopover(
                            canMoveUp: siblingIndex.map { $0 > 0 } ?? false,
                            canMoveDown: siblingIndex.map { $0 < siblings.count - 1 } ?? false,
                            onSelect: actionCoordinator.select
                        )
                        .onDisappear(perform: performPendingAction)
                        .presentationCompactAdaptation(.popover)
                    }
                }
            }
            .padding(.leading, CGFloat(depth) * 18)
            .padding(.vertical, 10)

            ForEach(children, id: \.objectID) { child in
                Divider().padding(.leading, CGFloat(depth) * 18 + 15)
                GroupCategoryTreeRow(
                    category: child,
                    depth: depth + 1,
                    canManage: canManage,
                    onAddChild: onAddChild,
                    onRename: onRename,
                    onMerge: onMerge,
                    onMove: onMove,
                    onArchive: onArchive
                )
            }
        }
    }

    private func performPendingAction() {
        guard let action = actionCoordinator.takePendingAction() else { return }
        switch action {
        case .rename:
            onRename(category)
        case .addChild:
            onAddChild(category)
        case let .move(offset):
            onMove(category, offset)
        case .merge:
            onMerge(category)
        case .archive:
            onArchive(category)
        }
    }
}

private struct GroupCategoryActionPopover: View {
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onSelect: (CategoryRowAction) -> Void

    var body: some View {
        VStack(spacing: 0) {
            actionButton(
                .categoryActionRename,
                systemImage: "pencil",
                action: .rename
            )
            actionButton(
                .categoryActionAddChild,
                systemImage: "plus.circle",
                action: .addChild
            )
            actionButton(
                .categoryActionMoveUp,
                systemImage: "arrow.up",
                action: .move(-1),
                isEnabled: canMoveUp
            )
            actionButton(
                .categoryActionMoveDown,
                systemImage: "arrow.down",
                action: .move(1),
                isEnabled: canMoveDown
            )
            actionButton(
                .categoryActionMerge,
                systemImage: "arrow.triangle.merge",
                action: .merge
            )
            Divider().padding(.vertical, 4)
            actionButton(
                .categoryActionArchive,
                systemImage: "archivebox",
                action: .archive,
                tint: LedgerTheme.coral
            )
        }
        .padding(8)
        .frame(minWidth: 270)
    }

    private func actionButton(
        _ title: LedgerStringKey,
        systemImage: String,
        action: CategoryRowAction,
        isEnabled: Bool = true,
        tint: Color = LedgerTheme.primary
    ) -> some View {
        Button {
            onSelect(action)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.body.weight(.medium))
                    .foregroundStyle(tint)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(title)
                    .foregroundStyle(action == .archive ? tint : .primary)
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: LedgerTheme.tapTargetMinimum)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.42)
    }
}

private struct RenameCategoryView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var category: LedgerCategory
    let onSaved: () -> Void

    @State private var draft: CategoryDraft
    @State private var errorMessage: String?

    init(category: LedgerCategory, onSaved: @escaping () -> Void) {
        self.category = category
        self.onSaved = onSaved
        _draft = State(initialValue: CategoryDraft(name: category.name ?? ""))
    }

    var body: some View {
        Form {
            Section {
                TextField("", text: $draft.name, prompt: Text(.categoryRenameNamePlaceholder))
                    .accessibilityLabel(Text(.categoryRenameNamePlaceholder))
            } header: {
                Text(.categoryRenameSectionName)
            } footer: {
                Text(verbatim: LedgerStringKey.categoryRenameFooter.string(
                    arguments: [CategoryRepository().impact(of: category).summary]
                ))
            }
        }
        .navigationTitle(Text(.categoryRenameTitle))
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
            try CategoryRepository().renameCategory(category, using: draft)
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct MergeCategoryView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var category: LedgerCategory
    let onMerged: () -> Void

    @State private var selectedTargetID: NSManagedObjectID?
    @State private var errorMessage: String?

    private var targets: [LedgerCategory] {
        CategoryRepository().mergeTargets(for: category)
    }

    private var selectedTarget: LedgerCategory? {
        targets.first { $0.objectID == selectedTargetID }
    }

    var body: some View {
        Form {
            Section {
                // 影響說明由 `CategoryRepository` 產生，那一層還沒遷移。
                Text(verbatim: CategoryRepository().impact(of: category).summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } header: {
                Text(verbatim: LedgerStringKey.categoryMergeHeader.string(
                    arguments: [category.name
                        ?? LedgerStringKey.commonPlaceholderUnnamedCategory.string()]
                ))
            }

            Section {
                if targets.isEmpty {
                    Text(.categoryMergeTargetsEmpty)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(targets, id: \.objectID) { target in
                        Button {
                            selectedTargetID = target.objectID
                        } label: {
                            HStack {
                                Text(verbatim: path(of: target))
                                    .foregroundStyle(.primary)
                                Spacer()
                                if target.objectID == selectedTargetID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(LedgerTheme.primary)
                                        .accessibilityHidden(true)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(
                            target.objectID == selectedTargetID
                                ? [.isButton, .isSelected]
                                : .isButton
                        )
                    }
                }
            } footer: {
                Text(.categoryMergeFooter)
            }
        }
        .navigationTitle(Text(.categoryMergeTitle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: {
                    Text(.commonActionCancel)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: merge) {
                    Text(.categoryMergeTitle)
                }
                .disabled(selectedTarget == nil)
            }
        }
        .alert(Text(.categoryMergeErrorTitle), isPresented: errorBinding) {
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

    /// 同名的子分類分屬不同父分類時，只顯示名稱會讓人選錯合併目標。
    private func path(of category: LedgerCategory) -> String {
        var names: [String] = []
        var current: LedgerCategory? = category
        var visited = Set<NSManagedObjectID>()
        while let value = current, visited.insert(value.objectID).inserted {
            names.insert(
                value.name ?? LedgerStringKey.commonPlaceholderUnnamedCategory.string(),
                at: 0
            )
            current = value.parent
        }
        return names.joined(separator: " › ")
    }

    private func merge() {
        guard let target = selectedTarget else { return }
        do {
            try CategoryRepository().mergeCategory(category, into: target)
            onMerged()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct BookCategoryToggleRow: View {
    @ObservedObject var category: LedgerCategory
    @ObservedObject var book: LedgerBook
    let depth: Int
    let canManage: Bool
    let onError: (String) -> Void
    let onUpdated: () -> Void
    let onMove: (LedgerCategory, Int) -> Void

    /// 子分類依這本帳本的顯示順序排列，未啟用的排在最後。
    private var children: [LedgerCategory] {
        CategoryRepository().manageableSiblings(of: category, in: book)
    }

    private var name: String {
        category.name ?? LedgerStringKey.commonPlaceholderUnnamedCategory.string()
    }

    private var isEnabled: Bool {
        CategoryRepository().isCategoryAvailable(category, in: book)
    }

    private var orderableSiblings: [LedgerCategory] {
        CategoryRepository().enabledSiblings(of: category.parent, in: book)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Toggle(isOn: Binding(
                    get: { isEnabled },
                    set: updateAvailability
                )) {
                    Text(verbatim: name)
                        .font(.subheadline.weight(depth == 0 ? .semibold : .regular))
                }
                .disabled(!canManage)

                if canManage, isEnabled, let index = orderableSiblings.firstIndex(of: category) {
                    Menu {
                        Button {
                            onMove(category, -1)
                        } label: {
                            Label(.categoryActionMoveUp, systemImage: "arrow.up")
                        }
                        .disabled(index == 0)
                        Button {
                            onMove(category, 1)
                        } label: {
                            Label(.categoryActionMoveDown, systemImage: "arrow.down")
                        }
                        .disabled(index == orderableSiblings.count - 1)
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .ledgerTapTarget()
                    }
                    .accessibilityLabel(Text(verbatim: LedgerStringKey
                        .categoryBookReorderAccessibilityLabel.string(arguments: [name])))
                }
            }
            .padding(.leading, CGFloat(depth) * 18)
            .padding(.vertical, 6)

            ForEach(children, id: \.objectID) { child in
                Divider().padding(.leading, CGFloat(depth) * 18 + 15)
                BookCategoryToggleRow(
                    category: child,
                    book: book,
                    depth: depth + 1,
                    canManage: canManage,
                    onError: onError,
                    onUpdated: onUpdated,
                    onMove: onMove
                )
            }
        }
    }

    private func updateAvailability(_ enabled: Bool) {
        do {
            try CategoryRepository().setCategory(category, enabled: enabled, in: book)
            onUpdated()
        } catch {
            onError(error.localizedDescription)
        }
    }
}
