import SwiftUI

struct NewCategoryView: View {
    @Environment(\.dismiss) private var dismiss

    let group: LedgerGroup
    /// 有帳本時是「帳本情境的新增捷徑」：分類一樣屬於群組，但預設只在這本帳本啟用。
    let book: LedgerBook?
    let parent: LedgerCategory?
    let onCreated: () -> Void

    @State private var draft = CategoryDraft()
    @State private var enablesEveryBook: Bool
    @State private var errorMessage: String?

    init(
        group: LedgerGroup,
        book: LedgerBook? = nil,
        parent: LedgerCategory?,
        onCreated: @escaping () -> Void
    ) {
        self.group = group
        self.book = book
        self.parent = parent
        self.onCreated = onCreated
        _enablesEveryBook = State(initialValue: book == nil)
    }

    var body: some View {
        Form {
            Section {
                TextField("分類名稱，例如：交通", text: $draft.name)
            } header: {
                if let parentName = parent?.name {
                    Text("在「\(parentName)」下新增子分類")
                } else {
                    Text("分類名稱")
                }
            } footer: {
                Text(footerText)
            }

            if let book {
                Section {
                    Toggle("套用到所有使用中的帳本", isOn: $enablesEveryBook)
                } footer: {
                    Text("關閉時只有「\(book.name ?? "目前帳本")」會啟用這個分類，其他帳本可以之後自行啟用。")
                }
            }
        }
        .navigationTitle("新增群組分類")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("新增", action: createCategory)
                    .disabled(!draft.canCreate)
            }
        }
        .alert("無法新增分類", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "請稍後再試。")
        }
    }

    private var footerText: String {
        book == nil
            ? "新分類會加入群組目錄，並預設啟用於所有使用中的帳本。"
            : "新分類會加入群組目錄，其他帳本仍可以自行決定要不要啟用。"
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func createCategory() {
        do {
            let repository = CategoryRepository()
            if let book, !enablesEveryBook {
                try repository.createCategory(from: draft, in: book, parent: parent)
            } else {
                try repository.createCategory(from: draft, in: group, parent: parent)
            }
            onCreated()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
