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
                            title: "先建立一個群組",
                            message: "請先到「設定」的「群組管理」建立群組，再回來管理共用分類。"
                        )
                        .padding(.horizontal, LedgerTheme.pagePadding)
                        .padding(.top, 24)
                    }
                }
                .navigationTitle("分類")
            }
        }
    }

    private func groupSelector(selectedGroup: LedgerGroup) -> some View {
        Menu {
            ForEach(Array(groups), id: \.objectID) { candidate in
                Button {
                    selectedGroupID = candidate.objectID
                } label: {
                    if candidate == selectedGroup {
                        Label(candidate.name ?? "未命名群組", systemImage: "checkmark")
                    } else {
                        Text(candidate.name ?? "未命名群組")
                    }
                }
            }
        } label: {
            Label(selectedGroup.name ?? "未命名群組", systemImage: "person.3.fill")
                .labelStyle(.titleAndIcon)
        }
        .accessibilityLabel("切換分類群組")
    }
}

struct CategoriesView: View {
    @ObservedObject var group: LedgerGroup

    @FetchRequest private var rootCategories: FetchedResults<LedgerCategory>

    @State private var isPresentingNewCategory = false
    @State private var newCategoryParent: LedgerCategory?
    @State private var categoryPendingArchive: LedgerCategory?
    @State private var categoryPendingRename: LedgerCategory?
    @State private var categoryPendingMerge: LedgerCategory?
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
                            title: "還沒有群組分類",
                            message: "建立一次即可讓群組內的多本帳本共用，再由各帳本選擇要使用的分類。",
                            actionTitle: canManage ? "新增分類" : nil,
                            action: canManage ? presentRootCategory : nil
                        )

                        if canManage {
                            Button(action: installDefaults) {
                                Label("套用內建分類", systemImage: "square.grid.2x2.fill")
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
                                        onAddChild: presentChildCategory,
                                        onRename: { categoryPendingRename = $0 },
                                        onMerge: { categoryPendingMerge = $0 },
                                        onMove: move,
                                        onArchive: requestArchive
                                    )
                                }
                            }
                            .id(revision)
                        }
                    }

                    Text("分類名稱與階層由整個群組共用；帳本設定只控制是否啟用，不會複製分類。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, LedgerTheme.pagePadding)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("分類")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canManage {
                Button(action: presentRootCategory) {
                    Image(systemName: "plus")
                        .fontWeight(.bold)
                }
                .accessibilityLabel("新增群組分類")
            }
        }
        .sheet(isPresented: $isPresentingNewCategory) {
            NavigationStack {
                NewCategoryView(group: group, parent: newCategoryParent) {
                    isPresentingNewCategory = false
                }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $categoryPendingRename) { category in
            NavigationStack {
                RenameCategoryView(category: category) {
                    categoryPendingRename = nil
                    revision += 1
                }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $categoryPendingMerge) { category in
            NavigationStack {
                MergeCategoryView(category: category) {
                    categoryPendingMerge = nil
                    revision += 1
                }
            }
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "封存分類？",
            isPresented: archiveConfirmationBinding,
            titleVisibility: .visible,
            presenting: categoryPendingArchive
        ) { category in
            Button("封存「\(category.name ?? "未命名分類")」", role: .destructive) {
                categoryPendingArchive = nil
                archive(category)
            }
            Button("取消", role: .cancel) {
                categoryPendingArchive = nil
            }
        } message: { category in
            Text("封存後會從所有帳本的新交易選單隱藏，但既有交易與歷史報表仍會保留。"
                + CategoryRepository().impact(of: category).summary)
        }
        .alert("無法更新分類", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "請稍後再試。")
        }
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
        newCategoryParent = nil
        isPresentingNewCategory = true
    }

    private func presentChildCategory(_ parent: LedgerCategory) {
        newCategoryParent = parent
        isPresentingNewCategory = true
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
                            title: "群組還沒有分類",
                            message: "請先到群組分類建立共用分類，再回來選擇這本帳本要使用的項目。",
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

                    Text("停用只會從這本帳本的新交易選單隱藏分類，既有交易與其他帳本不受影響；顯示順序也只套用在這本帳本。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, LedgerTheme.pagePadding)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("帳本可用分類")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canManage, book.group != nil {
                Button {
                    isPresentingNewCategory = true
                } label: {
                    Image(systemName: "plus")
                        .fontWeight(.bold)
                }
                .accessibilityLabel("新增分類")
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
        .alert("無法更新帳本分類", isPresented: errorBinding) {
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

    private var enabledBookCount: Int {
        let assignments = category.bookAssignments as? Set<BookCategoryAssignment> ?? []
        return assignments.filter { $0.isEnabled && $0.book?.archivedAt == nil }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 5))
                    .foregroundStyle(.tertiary)
                    .opacity(depth > 0 ? 1 : 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.name ?? "未命名分類")
                        .font(.subheadline.weight(depth == 0 ? .semibold : .regular))
                    Text("\(enabledBookCount) 本帳本使用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if canManage {
                    // 一列可以做的事已經超過兩個圖示放得下的數量，收進選單也讓
                    // VoiceOver 讀得到每個動作的名稱，而不是一排看不懂的圖示。
                    Menu {
                        Button {
                            onRename(category)
                        } label: {
                            Label("重新命名", systemImage: "pencil")
                        }
                        Button {
                            onAddChild(category)
                        } label: {
                            Label("新增子分類", systemImage: "plus.circle")
                        }
                        if let index = siblingIndex {
                            Button {
                                onMove(category, -1)
                            } label: {
                                Label("上移", systemImage: "arrow.up")
                            }
                            .disabled(index == 0)
                            Button {
                                onMove(category, 1)
                            } label: {
                                Label("下移", systemImage: "arrow.down")
                            }
                            .disabled(index == siblings.count - 1)
                        }
                        Button {
                            onMerge(category)
                        } label: {
                            Label("合併到其他分類", systemImage: "arrow.triangle.merge")
                        }
                        Button(role: .destructive) {
                            onArchive(category)
                        } label: {
                            Label("封存分類", systemImage: "archivebox")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 36, height: 36)
                    }
                    .accessibilityLabel("分類「\(category.name ?? "未命名分類")」選項")
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
                TextField("分類名稱", text: $draft.name)
            } header: {
                Text("名稱")
            } footer: {
                Text("名稱屬於整個群組，改名後所有使用這個分類的帳本、報表與歷史交易都會顯示新名稱。"
                    + CategoryRepository().impact(of: category).summary)
            }
        }
        .navigationTitle("重新命名分類")
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
                Text(CategoryRepository().impact(of: category).summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } header: {
                Text("將「\(category.name ?? "未命名分類")」合併到")
            }

            Section {
                if targets.isEmpty {
                    Text("這個群組沒有其他可以合併的分類。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(targets, id: \.objectID) { target in
                        Button {
                            selectedTargetID = target.objectID
                        } label: {
                            HStack {
                                Text(path(of: target))
                                    .foregroundStyle(.primary)
                                Spacer()
                                if target.objectID == selectedTargetID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(LedgerTheme.primary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } footer: {
                Text("歷史交易與子分類會改掛到目標分類，來源分類則會封存；已經記錄的金額與報表總額不會改變。")
            }
        }
        .navigationTitle("合併分類")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("合併", action: merge)
                    .disabled(selectedTarget == nil)
            }
        }
        .alert("無法合併分類", isPresented: errorBinding) {
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

    /// 同名的子分類分屬不同父分類時，只顯示名稱會讓人選錯合併目標。
    private func path(of category: LedgerCategory) -> String {
        var names: [String] = []
        var current: LedgerCategory? = category
        var visited = Set<NSManagedObjectID>()
        while let value = current, visited.insert(value.objectID).inserted {
            names.insert(value.name ?? "未命名分類", at: 0)
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
                    Text(category.name ?? "未命名分類")
                        .font(.subheadline.weight(depth == 0 ? .semibold : .regular))
                }
                .disabled(!canManage)

                if canManage, isEnabled, let index = orderableSiblings.firstIndex(of: category) {
                    Menu {
                        Button {
                            onMove(category, -1)
                        } label: {
                            Label("上移", systemImage: "arrow.up")
                        }
                        .disabled(index == 0)
                        Button {
                            onMove(category, 1)
                        } label: {
                            Label("下移", systemImage: "arrow.down")
                        }
                        .disabled(index == orderableSiblings.count - 1)
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .frame(width: 36, height: 36)
                    }
                    .accessibilityLabel("調整「\(category.name ?? "未命名分類")」的顯示順序")
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
