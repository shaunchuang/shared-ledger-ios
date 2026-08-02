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
                TextField("", text: $draft.name, prompt: Text(.categoryNewNamePlaceholder))
                    .accessibilityLabel(Text(.categoryNewHeaderRoot))
            } header: {
                if let parentName = parent?.name {
                    Text(verbatim: LedgerStringKey.categoryNewHeaderChild.string(
                        arguments: [parentName]
                    ))
                } else {
                    Text(.categoryNewHeaderRoot)
                }
            } footer: {
                Text(footerKey)
            }

            if let book {
                Section {
                    Toggle(isOn: $enablesEveryBook) {
                        Text(.categoryNewBookToggle)
                    }
                } footer: {
                    Text(verbatim: LedgerStringKey.categoryNewBookFooter.string(
                        arguments: [book.name ?? LedgerStringKey.bookLabelCurrent.string()]
                    ))
                }
            }
        }
        .navigationTitle(Text(.categoryActionAddGroupCategory))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: {
                    Text(.commonActionCancel)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: createCategory) {
                    Text(.commonActionAdd)
                }
                .disabled(!draft.canCreate)
            }
        }
        .alert(Text(.categoryNewErrorTitle), isPresented: errorBinding) {
            Button(role: .cancel) {} label: {
                Text(.commonActionOK)
            }
        } message: {
            Text(verbatim: errorMessage ?? LedgerStringKey.commonErrorRetryLater.string())
        }
    }

    private var footerKey: LedgerStringKey {
        book == nil ? .categoryNewFooterGroup : .categoryNewFooterBook
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
