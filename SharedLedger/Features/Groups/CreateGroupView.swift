import SwiftUI

struct CreateGroupView: View {
    @Environment(\.dismiss) private var dismiss

    let onCreated: (LedgerGroup) -> Void

    @State private var draft = GroupDraft()
    @State private var isShowingContacts = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("群組") {
                TextField("例如：台南旅行", text: $draft.name)
                TextField("你的顯示名稱", text: $draft.ownerDisplayName)
            }

            Section {
                if draft.invitees.isEmpty {
                    Text("尚未選擇聯絡人，也可以建立後再邀請。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(draft.invitees) { invitee in
                        Label(invitee.displayName, systemImage: "person.crop.circle")
                    }
                    .onDelete { offsets in
                        draft.invitees.remove(atOffsets: offsets)
                    }
                }

                Button("從聯絡人加入", systemImage: "person.crop.circle.badge.plus") {
                    isShowingContacts = true
                }
            } header: {
                Text("邀請成員")
            } footer: {
                Text("只會讀取你在系統選擇器中主動選取的聯絡人。")
            }
        }
        .navigationTitle("建立群組")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("建立") { createGroup() }
                    .disabled(!draft.canCreate)
            }
        }
        .sheet(isPresented: $isShowingContacts) {
            ContactPicker { contacts in
                draft.addInvitees(contacts)
                isShowingContacts = false
            }
        }
        .alert("無法建立群組", isPresented: errorBinding) {
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

    private func createGroup() {
        do {
            let group = try GroupRepository().createGroup(from: draft)
            onCreated(group)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

