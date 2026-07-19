import SwiftUI

struct NewCategoryView: View {
    @Environment(\.dismiss) private var dismiss

    let group: LedgerGroup
    let parent: LedgerCategory?
    let onCreated: () -> Void

    @State private var draft = CategoryDraft()
    @State private var errorMessage: String?

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
                Text("新分類會加入群組目錄，並預設啟用於所有使用中的帳本。")
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

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func createCategory() {
        do {
            try CategoryRepository().createCategory(from: draft, in: group, parent: parent)
            onCreated()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
