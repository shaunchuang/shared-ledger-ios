import SwiftUI

struct NewAccountView: View {
    @Environment(\.dismiss) private var dismiss

    let group: LedgerGroup
    let onCreated: () -> Void

    @State private var draft = AccountDraft()
    @State private var errorMessage: String?

    private var currencyCode: String {
        LedgerCurrency.normalizedCode(group.currencyCode)
    }

    var body: some View {
        Form {
            Section {
                TextField("", text: $draft.name, prompt: Text(.accountNewNamePlaceholder))
                    .accessibilityLabel(Text(.accountNewSectionName))
            } header: {
                Text(.accountNewSectionName)
            }

            Section {
                Picker(selection: $draft.type) {
                    ForEach(AccountType.allCases) { type in
                        Label(type.displayNameKey, systemImage: type.systemImage).tag(type)
                    }
                } label: {
                    Text(.accountTypeField)
                }
            } header: {
                Text(.accountNewSectionType)
            }

            Section {
                HStack {
                    Text(verbatim: currencyCode)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("", text: $draft.openingBalanceText, prompt: Text(verbatim: "0"))
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel(Text(.accountNewSectionOpeningBalance))
                }
            } header: {
                Text(.accountNewSectionOpeningBalance)
            } footer: {
                Text(.accountNewOpeningBalanceFooter)
            }
        }
        .navigationTitle(Text(.accountNewTitle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: {
                    Text(.commonActionCancel)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: createAccount) {
                    Text(.commonActionAdd)
                }
                .disabled(!draft.canCreate)
            }
        }
        .alert(Text(.accountNewErrorTitle), isPresented: errorBinding) {
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

    private func createAccount() {
        do {
            try AccountRepository().createAccount(from: draft, in: group)
            onCreated()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
