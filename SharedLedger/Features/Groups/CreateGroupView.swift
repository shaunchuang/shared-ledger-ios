import SwiftUI

struct CreateGroupView: View {
    @Environment(\.dismiss) private var dismiss

    let onCreated: (LedgerGroup) -> Void

    @State private var draft = GroupDraft()
    @State private var isShowingContacts = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    LedgerMark(size: 54)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("建立共享空間")
                            .font(.headline)
                        Text("先命名群組，再邀請一起記帳的人。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }
            .listRowBackground(Color.clear)

            Section {
                HStack(spacing: 13) {
                    LedgerIconBadge(systemImage: "person.3.fill")
                    TextField("例如：台南旅行", text: $draft.name)
                        .textInputAutocapitalization(.words)
                }
                HStack(spacing: 13) {
                    LedgerIconBadge(systemImage: "person.crop.circle.fill", tint: .blue)
                    TextField("你的顯示名稱", text: $draft.ownerDisplayName)
                }
            } header: {
                Text("群組資料")
            }
            .listRowBackground(LedgerTheme.surface)

            Section {
                if draft.invitees.isEmpty {
                    HStack(spacing: 13) {
                        LedgerIconBadge(systemImage: "person.crop.circle.badge.questionmark", tint: LedgerTheme.amber)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("尚未選擇成員")
                                .font(.subheadline.weight(.medium))
                            Text("也可以先建立，之後再邀請")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ForEach(draft.invitees) { invitee in
                        HStack(spacing: 13) {
                            LedgerAvatar(name: invitee.displayName, size: 40)
                            Text(invitee.displayName)
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text("待邀請")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(LedgerTheme.amber)
                        }
                    }
                    .onDelete { offsets in
                        draft.invitees.remove(atOffsets: offsets)
                    }
                }

                Button {
                    isShowingContacts = true
                } label: {
                    Label("從聯絡人加入", systemImage: "person.crop.circle.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LedgerTheme.primary)
                }
            } header: {
                Text("邀請成員")
            } footer: {
                Text("只會讀取你在系統選擇器中主動選取的聯絡人。")
            }
            .listRowBackground(LedgerTheme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(LedgerBackground())
        .navigationTitle("建立群組")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: createGroup) {
                Label("建立並邀請", systemImage: "arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(LedgerPrimaryButtonStyle())
            .disabled(!draft.canCreate)
            .opacity(draft.canCreate ? 1 : 0.48)
            .padding(.horizontal, LedgerTheme.pagePadding)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
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

