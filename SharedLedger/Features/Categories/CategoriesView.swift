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
    @State private var errorMessage: String?

    init(group: LedgerGroup) {
        self.group = group
        _rootCategories = FetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \LedgerCategory.sortOrder, ascending: true)],
            predicate: NSPredicate(format: "group == %@ AND archivedAt == nil AND parent == nil", group),
            animation: .default
        )
    }

    private var canManage: Bool {
        CategoryRepository().canManageCategories(in: group)
    }

    var body: some View {
        ZStack {
            LedgerBackground()
            ScrollView {
                VStack(spacing: 16) {
                    if rootCategories.isEmpty {
                        LedgerEmptyState(
                            systemImage: "square.grid.2x2",
                            title: "還沒有群組分類",
                            message: "建立一次即可讓群組內的多本帳本共用，再由各帳本選擇要使用的分類。",
                            actionTitle: canManage ? "新增分類" : nil,
                            action: canManage ? presentRootCategory : nil
                        )
                    } else {
                        LedgerCard {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(rootCategories), id: \.objectID) { category in
                                    GroupCategoryTreeRow(
                                        category: category,
                                        depth: 0,
                                        canManage: canManage,
                                        onAddChild: presentChildCategory,
                                        onArchive: requestArchive
                                    )
                                }
                            }
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
        } message: { _ in
            Text("封存後會從所有帳本的新交易選單隱藏，但既有交易與歷史報表仍會保留。")
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct BookCategoriesView: View {
    @ObservedObject var book: LedgerBook

    @FetchRequest private var rootCategories: FetchedResults<LedgerCategory>

    @State private var errorMessage: String?
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

    private var canManage: Bool {
        guard let group = book.group else { return false }
        return CategoryRepository().canManageCategories(in: group)
    }

    var body: some View {
        ZStack {
            LedgerBackground()
            ScrollView {
                VStack(spacing: 16) {
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
                                ForEach(Array(rootCategories), id: \.objectID) { category in
                                    BookCategoryToggleRow(
                                        category: category,
                                        book: book,
                                        depth: 0,
                                        canManage: canManage,
                                        onError: { errorMessage = $0 },
                                        onUpdated: { revision += 1 }
                                    )
                                }
                            }
                            .id(revision)
                        }
                    }

                    Text("停用只會從這本帳本的新交易選單隱藏分類，既有交易與其他帳本不受影響。")
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
}

private struct GroupCategoryTreeRow: View {
    @ObservedObject var category: LedgerCategory
    let depth: Int
    let canManage: Bool
    let onAddChild: (LedgerCategory) -> Void
    let onArchive: (LedgerCategory) -> Void

    private var children: [LedgerCategory] {
        let set = category.children as? Set<LedgerCategory> ?? []
        return set.filter { $0.archivedAt == nil }.sorted { $0.sortOrder < $1.sortOrder }
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
                    Button {
                        onAddChild(category)
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(LedgerTheme.primary)
                    .accessibilityLabel("新增子分類")

                    Button(role: .destructive) {
                        onArchive(category)
                    } label: {
                        Image(systemName: "archivebox")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("封存分類")
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
                    onArchive: onArchive
                )
            }
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

    private var children: [LedgerCategory] {
        let set = category.children as? Set<LedgerCategory> ?? []
        return set.filter { $0.archivedAt == nil }.sorted { $0.sortOrder < $1.sortOrder }
    }

    private var isEnabled: Bool {
        CategoryRepository().isCategoryAvailable(category, in: book)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: Binding(
                get: { isEnabled },
                set: updateAvailability
            )) {
                Text(category.name ?? "未命名分類")
                    .font(.subheadline.weight(depth == 0 ? .semibold : .regular))
            }
            .disabled(!canManage)
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
                    onUpdated: onUpdated
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
