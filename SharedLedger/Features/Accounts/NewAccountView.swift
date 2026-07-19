import SwiftUI

struct NewAccountView: View {
    @Environment(\.dismiss) private var dismiss

    let group: LedgerGroup
    let onCreated: () -> Void

    @State private var draft = AccountDraft()
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                TextField("帳戶名稱，例如：現金錢包", text: $draft.name)
            } header: {
                Text("名稱")
            }

            Section {
                Picker("類型", selection: $draft.type) {
                    ForEach(AccountType.allCases) { type in
                        Label(type.displayName, systemImage: type.systemImage).tag(type)
                    }
                }
            } header: {
                Text("帳戶類型")
            }

            Section {
                HStack {
                    Text("$")
                        .foregroundStyle(.secondary)
                    TextField("0", text: $draft.openingBalanceText)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("期初餘額")
            } footer: {
                Text("建立後若帳面與實際餘額不同，請使用餘額調整保留紀錄。")
            }
        }
        .navigationTitle("新增帳戶")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("新增", action: createAccount)
                    .disabled(!draft.canCreate)
            }
        }
        .alert("無法新增帳戶", isPresented: errorBinding) {
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
