import Foundation
import SwiftUI

struct GroupDetailView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var group: LedgerGroup
    let onInvite: (LedgerGroup) -> Void

    @AppStorage private var selectedBookID: String
    @State private var errorMessage: String?
    @State private var pendingAction: PendingMemberAction?
    @State private var isRenamingGroup = false

    init(group: LedgerGroup, onInvite: @escaping (LedgerGroup) -> Void) {
        self.group = group
        self.onInvite = onInvite
        _selectedBookID = AppStorage(
            wrappedValue: "",
            BookSelectionStorage.key(for: group)
        )
    }

    private var currentMember: Member? {
        CurrentMemberIdentityRepository().currentMember(in: group)
    }

    /// The App role after the CloudKit participant permission has been applied, so
    /// the management UI matches what the repositories will actually allow.
    private var currentRole: MemberRole? {
        EffectivePermissionRepository().permission(in: group).role
    }

    private var activeMembers: [Member] {
        members(matching: { member in
            member.archivedAt == nil
                && member.invitationStatus == InvitationStatus.accepted.rawValue
        })
    }

    private var pendingMembers: [Member] {
        members(matching: { member in
            member.archivedAt == nil
                && member.invitationStatus == InvitationStatus.pending.rawValue
        })
    }

    private var inactiveMembers: [Member] {
        members(matching: { member in
            member.archivedAt != nil
                || member.invitationStatus == InvitationStatus.revoked.rawValue
        })
    }

    private var canManageMembers: Bool {
        currentRole?.canManageMembers == true
    }

    private var canManageGroupSettings: Bool {
        currentRole?.canManageLedgerSettings == true
    }

    private var canInviteMembers: Bool {
        let persistence = PersistenceController.shared
        return persistence.store(for: group) === persistence.privateStore
            && currentRole == .owner
    }

    private var activeBooks: [LedgerBook] {
        BookRepository().books(in: group)
    }

    private var selectedBook: LedgerBook? {
        activeBooks.first { $0.id?.uuidString == selectedBookID }
            ?? activeBooks.first(where: \.isDefault)
            ?? activeBooks.first
    }

    private var accounts: [LedgerAccount] {
        let set = group.accounts as? Set<LedgerAccount> ?? []
        return Array(set)
    }

    private var totalAccountBalance: Decimal {
        AccountRepository().totalBalance(for: accounts)
    }

    private var currencyCode: String {
        LedgerCurrency.normalizedCode(group.currencyCode)
    }

    var body: some View {
        ZStack {
            LedgerBackground()
            ScrollView {
                VStack(spacing: 18) {
                    heroCard
                    bookSection
                    memberSection
                    groupSettingsSection
                    currentBookSettingsSection
                    sharingSection
                    lifecycleSection
                }
                .padding(.horizontal, LedgerTheme.pagePadding)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle(group.name ?? "群組")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: normalizeSelectedBook)
        .onChange(of: activeBooks.count) {
            normalizeSelectedBook()
        }
        .sheet(isPresented: $isRenamingGroup) {
            NavigationStack {
                RenameGroupView(group: group) {
                    isRenamingGroup = false
                }
            }
        }
        .alert("無法完成群組操作", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "請稍後再試。")
        }
        .alert(item: $pendingAction) { action in
            Alert(
                title: Text(action.title),
                message: Text(action.message),
                primaryButton: .destructive(Text(action.confirmTitle)) {
                    performConfirmedAction(action)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var memberSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LedgerSectionHeader(title: "成員")
            LedgerCard(padding: 0) {
                VStack(spacing: 0) {
                    memberRows(activeMembers)
                    if !pendingMembers.isEmpty {
                        if !activeMembers.isEmpty { Divider().padding(.leading, 72) }
                        memberRows(pendingMembers)
                    }
                    if activeMembers.isEmpty && pendingMembers.isEmpty {
                        Text("目前沒有有效成員。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
            }

            if !inactiveMembers.isEmpty {
                DisclosureGroup("已離開或已撤回（\(inactiveMembers.count)）") {
                    LedgerCard(padding: 0) {
                        VStack(spacing: 0) {
                            memberRows(inactiveMembers)
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func memberRows(_ members: [Member]) -> some View {
        ForEach(Array(members.enumerated()), id: \.element.objectID) { index, member in
            MemberRow(
                member: member,
                isCurrentUser: member == currentMember,
                canManage: canManageMembers,
                canTransferOwnership: currentRole == .owner
                    && member != currentMember
                    && member.archivedAt == nil
                    && member.invitationStatus == InvitationStatus.accepted.rawValue,
                onResend: { resendInvitation(member) },
                onRevoke: {
                    pendingAction = PendingMemberAction(kind: .revokeInvitation, member: member)
                },
                onRemove: {
                    pendingAction = PendingMemberAction(kind: .removeMember, member: member)
                }
            )
            if index < members.count - 1 {
                Divider().padding(.leading, 72)
            }
        }
    }

    private var groupSettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LedgerSectionHeader(title: "群組設定")
            LedgerCard(padding: 0) {
                VStack(spacing: 0) {
                    if canManageGroupSettings {
                        Button {
                            isRenamingGroup = true
                        } label: {
                            LedgerNavRow(
                                title: "群組名稱",
                                detail: group.name ?? "未命名群組",
                                icon: "pencil",
                                tint: LedgerTheme.primary
                            )
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 68)
                    }

                    NavigationLink {
                        AccountsView(group: group)
                    } label: {
                        LedgerNavRow(
                            title: "帳戶",
                            detail: "所有帳本共用的現金、銀行與信用卡",
                            icon: "creditcard.fill",
                            tint: .blue
                        )
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 68)
                    NavigationLink {
                        CategoriesView(group: group)
                    } label: {
                        LedgerNavRow(
                            title: "分類管理",
                            detail: "所有帳本共用的分類目錄",
                            icon: "square.grid.2x2.fill",
                            tint: LedgerTheme.amber
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var currentBookSettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LedgerSectionHeader(title: "目前帳本設定")
            LedgerCard(padding: 0) {
                VStack(spacing: 0) {
                    if let selectedBook {
                        NavigationLink {
                            BookCategoriesView(book: selectedBook)
                        } label: {
                            LedgerNavRow(
                                title: "使用的分類",
                                detail: "選擇\(selectedBook.name ?? "目前帳本")可使用的群組分類",
                                icon: "square.grid.2x2.fill",
                                tint: LedgerTheme.amber
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text("正在準備主要帳本…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var sharingSection: some View {
        if canInviteMembers {
            VStack(spacing: 10) {
                Button {
                    onInvite(group)
                } label: {
                    Label("邀請／管理 iCloud 共享", systemImage: "person.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LedgerPrimaryButtonStyle())

                Text("App 內的成員狀態與 iCloud 共享參與者目前尚未建立一對一識別。移除成員後，請同時在 iCloud 共享畫面確認其存取權已移除。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var lifecycleSection: some View {
        if let currentMember, currentMember.role != MemberRole.owner.rawValue {
            Button(role: .destructive) {
                pendingAction = PendingMemberAction(kind: .leaveGroup, member: currentMember)
            } label: {
                Label("退出群組", systemImage: "rectangle.portrait.and.arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        } else if currentRole == .owner {
            Text("群組擁有者不能直接退出。擁有權移轉需要先完成 App Member 與 iCloud participant 的安全對應，因此目前暫不開放。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var bookSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LedgerSectionHeader(title: "目前帳本")
            LedgerCard(padding: 0) {
                VStack(spacing: 0) {
                    if let selectedBook {
                        Menu {
                            ForEach(activeBooks, id: \.objectID) { book in
                                Button {
                                    select(book)
                                } label: {
                                    if book == selectedBook {
                                        Label(book.name ?? "未命名帳本", systemImage: "checkmark")
                                    } else {
                                        Text(book.name ?? "未命名帳本")
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 14) {
                                LedgerIconBadge(systemImage: "book.closed.fill", tint: LedgerTheme.primary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(selectedBook.name ?? "未命名帳本")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(selectedBook.isDefault ? "目前帳本 · 預設" : "目前帳本")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("切換目前帳本")
                    }

                    Divider().padding(.leading, 68)
                    NavigationLink {
                        BooksView(group: group, selectedBookID: $selectedBookID)
                    } label: {
                        LedgerNavRow(
                            title: "管理帳本",
                            detail: "新增、排序、設定預設與封存",
                            icon: "books.vertical.fill",
                            tint: LedgerTheme.primary
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var heroCard: some View {
        LedgerCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    LedgerMark(size: 54)
                    Spacer()
                    Text("共享中")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(LedgerTheme.primaryStrong)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(LedgerTheme.mint.opacity(0.22), in: Capsule())
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(group.name ?? "未命名群組")
                        .font(.title2.weight(.bold))
                    var memberSummary: String {
                        var parts = ["\(activeMembers.count) 位成員"]
                        if !pendingMembers.isEmpty {
                            parts.append("\(pendingMembers.count) 位待邀請")
                        }
                        return parts.joined(separator: " · ")
                    }
                    Text("\(memberSummary) · \(currencyCode) · 共同餘額 \(ledgerGroupAmount(totalAccountBalance, currencyCode: currencyCode))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func members(matching predicate: (Member) -> Bool) -> [Member] {
        let set = group.members as? Set<Member> ?? []
        return set
            .filter(predicate)
            .sorted { ($0.displayName ?? "") < ($1.displayName ?? "") }
    }

    private func resendInvitation(_ member: Member) {
        do {
            try GroupRepository().resendInvitation(member, in: group)
            if canInviteMembers {
                onInvite(group)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func performConfirmedAction(_ action: PendingMemberAction) {
        do {
            switch action.kind {
            case .revokeInvitation:
                try GroupRepository().revokeInvitation(action.member, in: group)
            case .removeMember:
                try GroupRepository().removeMember(action.member, from: group)
            case .leaveGroup:
                try GroupRepository().leaveGroup(group)
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func select(_ book: LedgerBook) {
        guard book.archivedAt == nil, let id = book.id else { return }
        selectedBookID = id.uuidString
    }

    private func normalizeSelectedBook() {
        if let selectedBook, selectedBook.id?.uuidString == selectedBookID {
            return
        }
        if let fallback = activeBooks.first(where: \.isDefault) ?? activeBooks.first {
            select(fallback)
        }
    }
}

private struct PendingMemberAction: Identifiable {
    enum Kind {
        case revokeInvitation
        case removeMember
        case leaveGroup
    }

    let id = UUID()
    let kind: Kind
    let member: Member

    var title: String {
        switch kind {
        case .revokeInvitation: "撤回邀請？"
        case .removeMember: "移除成員？"
        case .leaveGroup: "退出群組？"
        }
    }

    var message: String {
        switch kind {
        case .revokeInvitation:
            "將撤回「\(member.displayName ?? "未命名成員")」的 App 邀請狀態。已產生的 iCloud 分享仍需在系統共享畫面確認存取權。"
        case .removeMember:
            "「\(member.displayName ?? "未命名成員")」會停止成為有效 App 成員，但歷史付款與分攤仍會保留。請另外確認 iCloud 共享存取權已移除。"
        case .leaveGroup:
            "退出後會保留你既有的付款與分攤歷史。重新加入必須由管理者重新邀請。"
        }
    }

    var confirmTitle: String {
        switch kind {
        case .revokeInvitation: "撤回"
        case .removeMember: "移除"
        case .leaveGroup: "退出"
        }
    }
}

private func ledgerGroupAmount(_ amount: Decimal, currencyCode: String) -> String {
    LedgerCurrency.format(amount, currencyCode: currencyCode)
}

private struct MemberRow: View {
    @ObservedObject var member: Member
    let isCurrentUser: Bool
    let canManage: Bool
    let canTransferOwnership: Bool
    let onResend: () -> Void
    let onRevoke: () -> Void
    let onRemove: () -> Void

    private var name: String {
        member.displayName ?? "未命名成員"
    }

    private var roleName: String {
        member.role.flatMap(MemberRole.init(rawValue:))?.displayName ?? "成員"
    }

    private var isPending: Bool {
        member.invitationStatus == InvitationStatus.pending.rawValue && member.archivedAt == nil
    }

    private var isRevoked: Bool {
        member.invitationStatus == InvitationStatus.revoked.rawValue
    }

    private var isInactive: Bool {
        member.archivedAt != nil
    }

    var body: some View {
        HStack(spacing: 14) {
            LedgerAvatar(name: name, size: 42)
                .opacity(isInactive ? 0.55 : 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isInactive ? .secondary : .primary)
                Text(roleName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusBadge
            if canManage {
                actionMenu
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isPending {
            Text("待邀請")
                .font(.caption.weight(.semibold))
                .foregroundStyle(LedgerTheme.amber)
        } else if isRevoked {
            Text("已撤回")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        } else if isInactive {
            Text("已離開")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        } else if isCurrentUser {
            Text("你")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actionMenu: some View {
        let role = member.role.flatMap(MemberRole.init(rawValue:))
        Menu {
            if isPending || isRevoked || isInactive {
                Button(action: onResend) {
                    Label("重新邀請", systemImage: "paperplane")
                }
            }
            if isPending {
                Button(role: .destructive, action: onRevoke) {
                    Label("撤回邀請", systemImage: "xmark.circle")
                }
            }
            if !isCurrentUser,
               !isInactive,
               member.invitationStatus == InvitationStatus.accepted.rawValue,
               role != .owner {
                Button(role: .destructive, action: onRemove) {
                    Label("移除成員", systemImage: "person.badge.minus")
                }
            }
            if canTransferOwnership {
                Button {} label: {
                    Label("擁有權移轉尚未開放", systemImage: "person.crop.circle.badge.checkmark")
                }
                .disabled(true)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("管理\(name)")
    }
}

private struct RenameGroupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var group: LedgerGroup
    let onSaved: () -> Void

    @State private var name: String
    @State private var errorMessage: String?

    init(group: LedgerGroup, onSaved: @escaping () -> Void) {
        self.group = group
        self.onSaved = onSaved
        _name = State(initialValue: group.name ?? "")
    }

    var body: some View {
        Form {
            Section("群組名稱") {
                TextField("群組名稱", text: $name)
            }
        }
        .navigationTitle("重新命名群組")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("儲存", action: save)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .alert("無法重新命名", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "請稍後再試。")
        }
    }

    private func save() {
        do {
            try GroupRepository().renameGroup(group, to: name)
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
