import CoreData
import SwiftUI

struct CategoriesView: View {
    @ObservedObject var book: LedgerBook

    @FetchRequest private var rootCategories: FetchedResults<LedgerCategory>

    @State private var isPresentingNewCategory = false
    @State private var newCategoryParent: LedgerCategory?
    @State private var errorMessage: String?

    init(book: LedgerBook) {
        self.book = book
        _rootCategories = FetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \LedgerCategory.sortOrder, ascending: true)],
            predicate: NSPredicate(format: "book == %@ AND archivedAt == nil AND parent == nil", book),
            animation: .default
        )
    }

    var body: some View {
        ZStack {
            LedgerBackground()
            ScrollView {
                VStack(spacing: 16) {
                    if rootCategories.isEmpty {
                        LedgerEmptyState(
                            systemImage: "square.grid.2x2",
                            title: "還沒有分類",
                            message: "建立分類來整理每一筆收支，也可以加入子分類。",
                            actionTitle: "新增分類"
                        ) {
                            newCategoryParent = nil
                            isPresentingNewCategory = true
                        }
                    } else {
                        LedgerCard {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(rootCategories), id: \.objectID) { category in
                                    CategoryTreeRow(category: category, depth: 0) { parent in
                                        newCategoryParent = parent
                                        isPresentingNewCategory = true
                                    } onArchive: { target in
                                        archive(target)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, LedgerTheme.pagePadding)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle(book.name ?? "分類")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button {
                newCategoryParent = nil
                isPresentingNewCategory = true
            } label: {
                Image(systemName: "plus")
                    .fontWeight(.bold)
            }
            .accessibilityLabel("新增分類")
        }
        .sheet(isPresented: $isPresentingNewCategory) {
            NavigationStack {
                NewCategoryView(book: book, parent: newCategoryParent) {
                    isPresentingNewCategory = false
                }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .alert("無法更新分類", isPresented: errorBinding) {
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

    private func archive(_ category: LedgerCategory) {
        do {
            try CategoryRepository().archiveCategory(category)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct CategoryTreeRow: View {
    @ObservedObject var category: LedgerCategory
    let depth: Int
    let onAddChild: (LedgerCategory) -> Void
    let onArchive: (LedgerCategory) -> Void

    private var children: [LedgerCategory] {
        let set = category.children as? Set<LedgerCategory> ?? []
        return set.filter { $0.archivedAt == nil }.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 5))
                    .foregroundStyle(.tertiary)
                    .opacity(depth > 0 ? 1 : 0)
                Text(category.name ?? "未命名分類")
                    .font(.subheadline.weight(depth == 0 ? .semibold : .regular))
                Spacer()
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
            .padding(.leading, CGFloat(depth) * 18)
            .padding(.vertical, 10)

            ForEach(children, id: \.objectID) { child in
                Divider().padding(.leading, CGFloat(depth) * 18 + 15)
                CategoryTreeRow(category: child, depth: depth + 1, onAddChild: onAddChild, onArchive: onArchive)
            }
        }
    }
}
