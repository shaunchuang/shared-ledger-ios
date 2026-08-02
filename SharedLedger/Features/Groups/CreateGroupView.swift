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
                        Text(.groupCreateHeroTitle)
                            .font(.headline)
                        Text(.groupCreateHeroSubtitle)
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
                    TextField(
                        "",
                        text: $draft.name,
                        prompt: Text(.groupCreateNamePlaceholder)
                    )
                    .textInputAutocapitalization(.words)
                    .accessibilityLabel(Text(.groupFieldName))
                }
                HStack(spacing: 13) {
                    LedgerIconBadge(systemImage: "person.crop.circle.fill", tint: .blue)
                    TextField(
                        "",
                        text: $draft.ownerDisplayName,
                        prompt: Text(.memberIdentityDisplayNamePlaceholder)
                    )
                    .accessibilityLabel(Text(.memberIdentityDisplayNamePlaceholder))
                }
                Picker(selection: $draft.currencyCode) {
                    ForEach(LedgerCurrency.supportedCodes, id: \.self) { code in
                        Text(verbatim: LedgerCurrency.displayName(for: code))
                            .tag(code)
                    }
                } label: {
                    HStack(spacing: 13) {
                        LedgerIconBadge(systemImage: "banknote.fill", tint: LedgerTheme.amber)
                        Text(.groupCreateFieldCurrency)
                    }
                }
                Toggle(isOn: $draft.usesDefaultCategories) {
                    HStack(spacing: 13) {
                        LedgerIconBadge(systemImage: "square.grid.2x2.fill", tint: LedgerTheme.amber)
                        Text(.groupCreateFieldDefaultCategories)
                    }
                }
            } header: {
                Text(.groupCreateSectionDetails)
            } footer: {
                Text(.groupCreateDetailsFooter)
            }
            .listRowBackground(LedgerTheme.surface)

            Section {
                if draft.invitees.isEmpty {
                    HStack(spacing: 13) {
                        LedgerIconBadge(systemImage: "person.crop.circle.badge.questionmark", tint: LedgerTheme.amber)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(.groupCreateInviteesEmptyTitle)
                                .font(.subheadline.weight(.medium))
                            Text(.groupCreateInviteesEmptyDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ForEach(draft.invitees) { invitee in
                        HStack(spacing: 13) {
                            LedgerAvatar(name: invitee.displayName, size: 40)
                            Text(verbatim: invitee.displayName)
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text(.memberBadgePending)
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
                    Label(.groupCreateActionAddContacts, systemImage: "person.crop.circle.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LedgerTheme.primary)
                }
            } header: {
                Text(.groupCreateSectionInvitees)
            } footer: {
                Text(.groupCreateInviteesFooter)
            }
            .listRowBackground(LedgerTheme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(LedgerBackground())
        .navigationTitle(Text(.groupCreateTitle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: {
                    Text(.commonActionCancel)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: createGroup) {
                Label(.groupCreateActionSubmit, systemImage: "arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(LedgerPrimaryButtonStyle())
            .disabled(!draft.canCreate)
            .opacity(draft.canCreate ? 1 : 0.48)
            .padding(.horizontal, LedgerTheme.pagePadding)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
        }
        .background(
            ContactPicker(isPresented: $isShowingContacts) { contacts in
                draft.addInvitees(contacts)
            }
        )
        .alert(Text(.groupCreateErrorTitle), isPresented: errorBinding) {
            Button(role: .cancel) {} label: {
                Text(.commonActionOK)
            }
        } message: {
            // 驗證訊息來自 repository，那一層還沒遷移到 catalog。
            Text(verbatim: errorMessage ?? LedgerStringKey.commonErrorRetryLater.string())
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

