import CoreData
import Foundation
import SwiftUI

/// Everything the group management screen shows that is expensive to work out, held
/// together so it is resolved once and reused across the whole `body` pass.
///
/// Each of these questions used to be a computed property, and `body` asked most of
/// them several times per pass: the role alone was read by four sections, and the
/// member-management restriction by one more per member group. Every one of those
/// reads resolves the current member with a Core Data fetch and, for a shared group,
/// makes a synchronous `fetchShares` call into the CloudKit mirroring metadata — a
/// call that blocks the main thread for as long as a sync is holding the store. With
/// `body` re-running on every merged CloudKit change, opening the screen during a
/// sync froze the app.
private struct GroupManagementAccess {
    /// Nothing is known before the first resolution, so every management affordance
    /// stays hidden and no restriction is explained. Showing a notice for a state
    /// nobody has checked would flash the wrong reason on the frame before `onAppear`.
    static var unresolved: GroupManagementAccess { GroupManagementAccess() }

    /// The App role after the CloudKit participant permission has been applied, so
    /// the management UI matches what the repositories will actually allow.
    var role: MemberRole?
    /// Identified by object ID rather than by the object, so a member deleted between
    /// two resolutions is simply not matched by any row instead of being faulted.
    var currentMemberID: NSManagedObjectID?
    /// Why member management is unavailable, or `nil` when it is allowed.
    var memberManagementRestriction: PermissionError?
    var participantStatuses: [NSManagedObjectID: CloudParticipantStatus] = [:]
    /// Only the Apple Account holding the group in its private store can present the
    /// system sharing controller.
    var holdsShareLocally = false
    var isResolved = false

    var canManageMembers: Bool { isResolved && memberManagementRestriction == nil }
    var canManageGroupSettings: Bool { role?.canManageLedgerSettings == true }

    /// After an ownership transfer the Apple Account that created the share is an
    /// administrator rather than the App owner — it still has to be able to manage the
    /// participant list, because nobody else can.
    var canInviteMembers: Bool { holdsShareLocally && role?.canManageMembers == true }

    /// `nil` unless this device holds the owner seat, because nobody else can hand it
    /// over.
    var ownerMemberID: NSManagedObjectID? { role == .owner ? currentMemberID : nil }

    var managementNotice: String? {
        isResolved ? memberManagementRestriction?.errorDescription : nil
    }
}

struct GroupDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context

    @ObservedObject var group: LedgerGroup
    let onInvite: (LedgerGroup) -> Void

    @AppStorage private var selectedBookID: String
    @State private var errorMessage: String?
    @State private var pendingAction: PendingMemberAction?
    @State private var isRenamingGroup = false
    @State private var access = GroupManagementAccess.unresolved
    /// Summing it fetches every entry that moves money through the group's accounts,
    /// so it is resolved when that data changes rather than on every `body` pass.
    @State private var totalAccountBalance: Decimal = 0

    init(group: LedgerGroup, onInvite: @escaping (LedgerGroup) -> Void) {
        self.group = group
        self.onInvite = onInvite
        _selectedBookID = AppStorage(
            wrappedValue: "",
            BookSelectionStorage.key(for: group)
        )
    }

    /// Resolved from the cached identity by scanning the group's already-faulted
    /// members, so reading it costs nothing beyond the relationship itself.
    private var currentMember: Member? {
        guard let currentMemberID = access.currentMemberID else { return nil }
        let members = group.members as? Set<Member> ?? []
        return members.first { $0.objectID == currentMemberID }
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

    /// The most notable participant-mapping problem across the group's members, in
    /// severity order, so the section explains the badges once instead of repeating
    /// a paragraph on every row.
    private func participantNotice(
        from statuses: [NSManagedObjectID: CloudParticipantStatus]
    ) -> String? {
        let values = Array(statuses.values)
        if let unavailable = values.first(where: { $0 == .shareUnavailable }) {
            return unavailable.explanation
        }
        if let missing = values.first(where: { $0 == .participantMissing }) {
            return missing.explanation
        }
        if let pending = values.first(where: {
            if case let .mapped(_, _, isAccepted) = $0 { return !isAccepted }
            return false
        }) {
            return pending.explanation
        }
        if let unmapped = values.first(where: { $0 == .unmapped }) {
            return unmapped.explanation
        }
        return nil
    }

    /// Whether the row offers ownership transfer, and why it is unavailable when the
    /// member could hold the seat but the CloudKit mapping is not ready. `ownerID` is
    /// `nil` unless this device holds the owner seat, because nobody else can hand it
    /// over.
    private func ownershipTransferOption(
        for member: Member,
        status: CloudParticipantStatus,
        ownerID: NSManagedObjectID?
    ) -> OwnershipTransferOption? {
        guard let ownerID, member.objectID != ownerID else { return nil }
        let repository = GroupRepository()
        guard repository.isOwnershipTransferCandidate(member, in: group) else { return nil }
        guard let restriction = repository.ownershipTransferRestriction(
            to: member,
            in: group,
            participantStatus: status
        ) else { return .available }

        switch restriction {
        case .ownershipTransferRequiresWritableParticipant:
            return .blocked(reason: .groupOwnershipTransferBlockedWritable)
        default:
            return .blocked(reason: .groupOwnershipTransferBlockedMapping)
        }
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
        .navigationTitle(Text(verbatim: group.name
            ?? LedgerStringKey.groupDetailTitleFallback.string()))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            normalizeSelectedBook()
            reloadAccess()
            reloadAccountBalance()
        }
        .onChange(of: activeBooks.count) {
            normalizeSelectedBook()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .NSManagedObjectContextObjectsDidChange,
                object: context
            )
        ) { notification in
            if ContextChangeObserver.touches(notification, .groupPermissions) {
                reloadAccess()
            }
            if ContextChangeObserver.touches(notification, .accountBalances) {
                reloadAccountBalance()
            }
        }
        .sheet(isPresented: $isRenamingGroup) {
            NavigationStack {
                RenameGroupView(group: group) {
                    isRenamingGroup = false
                }
            }
        }
        .alert(Text(.groupDetailErrorTitle), isPresented: errorBinding) {
            Button(role: .cancel) {} label: {
                Text(.commonActionOK)
            }
        } message: {
            // 錯誤內容來自 repository，那一層還沒遷移到 catalog。
            Text(verbatim: errorMessage ?? LedgerStringKey.commonErrorRetryLater.string())
        }
        .alert(item: $pendingAction) { action in
            Alert(
                title: Text(action.titleKey),
                message: Text(verbatim: action.message),
                primaryButton: primaryAlertButton(for: action),
                secondaryButton: .cancel()
            )
        }
    }

    private var memberSection: some View {
        let statuses = access.participantStatuses
        // Every row needs to know whether this device holds the seat it would be
        // handing over.
        let ownerID = access.ownerMemberID
        return VStack(alignment: .leading, spacing: 12) {
            LedgerSectionHeader(title: .groupDetailSectionMembers)
            LedgerCard(padding: 0) {
                VStack(spacing: 0) {
                    memberRows(activeMembers, statuses: statuses, ownerID: ownerID)
                    if !pendingMembers.isEmpty {
                        if !activeMembers.isEmpty { Divider().padding(.leading, 72) }
                        memberRows(pendingMembers, statuses: statuses, ownerID: ownerID)
                    }
                    if activeMembers.isEmpty && pendingMembers.isEmpty {
                        Text(.groupDetailMembersEmpty)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
            }

            if let message = access.managementNotice {
                LedgerNotice(message: message)
            }

            if let message = participantNotice(from: statuses) {
                LedgerNotice(message: message, systemImage: "person.2.badge.gearshape")
            }

            if !inactiveMembers.isEmpty {
                DisclosureGroup {
                    LedgerCard(padding: 0) {
                        VStack(spacing: 0) {
                            memberRows(inactiveMembers, statuses: statuses, ownerID: ownerID)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text(verbatim: LedgerStringKey.groupDetailMembersInactive.string(
                        arguments: [Int64(inactiveMembers.count)]
                    ))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func memberRows(
        _ members: [Member],
        statuses: [NSManagedObjectID: CloudParticipantStatus],
        ownerID: NSManagedObjectID?
    ) -> some View {
        ForEach(Array(members.enumerated()), id: \.element.objectID) { index, member in
            MemberRow(
                member: member,
                participantStatus: statuses[member.objectID] ?? .notShared,
                isCurrentUser: member.objectID == access.currentMemberID,
                canManage: access.canManageMembers,
                ownershipTransfer: ownershipTransferOption(
                    for: member,
                    status: statuses[member.objectID] ?? .notShared,
                    ownerID: ownerID
                ),
                onResend: { resendInvitation(member) },
                onRevoke: {
                    pendingAction = PendingMemberAction(kind: .revokeInvitation, member: member)
                },
                onRemove: {
                    pendingAction = PendingMemberAction(kind: .removeMember, member: member)
                },
                onTransferOwnership: {
                    pendingAction = PendingMemberAction(kind: .transferOwnership, member: member)
                }
            )
            if index < members.count - 1 {
                Divider().padding(.leading, 72)
            }
        }
    }

    private var groupSettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LedgerSectionHeader(title: .groupDetailSectionSettings)
            LedgerCard(padding: 0) {
                VStack(spacing: 0) {
                    if access.canManageGroupSettings {
                        Button {
                            isRenamingGroup = true
                        } label: {
                            LedgerNavRow(
                                title: .groupFieldName,
                                detail: group.name
                                    ?? LedgerStringKey.commonPlaceholderUnnamedGroup.string(),
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
                            title: .groupDetailRowAccountsTitle,
                            detail: .groupDetailRowAccountsDetail,
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
                            title: .groupDetailRowCategoriesTitle,
                            detail: .groupDetailRowCategoriesDetail,
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
            LedgerSectionHeader(title: .groupDetailSectionBookSettings)
            LedgerCard(padding: 0) {
                VStack(spacing: 0) {
                    if let selectedBook {
                        NavigationLink {
                            BookCategoriesView(book: selectedBook)
                        } label: {
                            LedgerNavRow(
                                title: .groupDetailRowBookCategoriesTitle,
                                detail: LedgerStringKey.groupDetailRowBookCategoriesDetail.string(
                                    arguments: [
                                        selectedBook.name
                                            ?? LedgerStringKey.bookLabelCurrent.string()
                                    ]
                                ),
                                icon: "square.grid.2x2.fill",
                                tint: LedgerTheme.amber
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(.groupDetailBookSettingsPreparing)
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
        if access.canInviteMembers {
            VStack(spacing: 10) {
                Button {
                    onInvite(group)
                } label: {
                    Label(.groupDetailActionShare, systemImage: "person.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LedgerPrimaryButtonStyle())

                Text(.groupDetailShareFooter)
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
                Label(.groupDetailActionLeave, systemImage: "rectangle.portrait.and.arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        } else if access.role == .owner {
            Text(.groupDetailOwnerCannotLeave)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var bookSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LedgerSectionHeader(title: .bookLabelCurrent)
            LedgerCard(padding: 0) {
                VStack(spacing: 0) {
                    if let selectedBook {
                        Menu {
                            ForEach(activeBooks, id: \.objectID) { book in
                                Button {
                                    select(book)
                                } label: {
                                    let name = book.name
                                        ?? LedgerStringKey.commonPlaceholderUnnamedBook.string()
                                    if book == selectedBook {
                                        Label {
                                            Text(verbatim: name)
                                        } icon: {
                                            Image(systemName: "checkmark")
                                        }
                                    } else {
                                        Text(verbatim: name)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 14) {
                                LedgerIconBadge(systemImage: "book.closed.fill", tint: LedgerTheme.primary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: selectedBook.name
                                        ?? LedgerStringKey.commonPlaceholderUnnamedBook.string())
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(selectedBook.isDefault
                                        ? LedgerStringKey.bookLabelCurrentAndDefault
                                        : LedgerStringKey.bookLabelCurrent)
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
                        .accessibilityLabel(Text(.transactionBookPickerAccessibilityLabel))
                    }

                    Divider().padding(.leading, 68)
                    NavigationLink {
                        BooksView(group: group, selectedBookID: $selectedBookID)
                    } label: {
                        LedgerNavRow(
                            title: .bookManageTitle,
                            detail: .bookManageDetail,
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
                    Text(.groupDetailBadgeShared)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(LedgerTheme.primaryStrong)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(LedgerTheme.mint.opacity(0.22), in: Capsule())
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: group.name
                        ?? LedgerStringKey.commonPlaceholderUnnamedGroup.string())
                        .font(.title2.weight(.bold))
                    Text(verbatim: summaryText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 成員數、貨幣與共同餘額組成的一句話。
    ///
    /// 三段各自是一個參數而不是在這裡串起來：語序在不同語言會變，中間的分隔點也不是
    /// 每種語言都這樣寫。
    private var summaryText: String {
        var parts = [
            LedgerStringKey.groupCardMemberCount.string(arguments: [Int64(activeMembers.count)])
        ]
        if !pendingMembers.isEmpty {
            parts.append(
                LedgerStringKey.groupCardPendingCount.string(
                    arguments: [Int64(pendingMembers.count)]
                )
            )
        }
        return LedgerStringKey.groupDetailSummary.string(arguments: [
            parts.joined(separator: " · "),
            currencyCode,
            LedgerCurrency.format(totalAccountBalance, currencyCode: currencyCode)
        ])
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    /// The repositories refuse the same actions with the same `PermissionError` this
    /// resolves, so the management UI and the write paths can never disagree.
    ///
    /// The permission is resolved once and every question is answered from it, because
    /// each resolution makes a synchronous `fetchShares` call for a shared group.
    private func reloadAccess() {
        let persistence = PersistenceController.shared
        let permissions = EffectivePermissionRepository(persistence: persistence)
        let permission = permissions.permission(in: group)
        access = GroupManagementAccess(
            role: permission.role,
            currentMemberID: CurrentMemberIdentityRepository(persistence: persistence)
                .currentMember(in: group)?
                .objectID,
            memberManagementRestriction: permissions.restriction(.memberManagement, for: permission),
            participantStatuses: GroupRepository(persistence: persistence)
                .cloudParticipantStatuses(in: group),
            holdsShareLocally: persistence.store(for: group) === persistence.privateStore,
            isResolved: true
        )
    }

    private func reloadAccountBalance() {
        totalAccountBalance = AccountRepository().totalBalance(for: accounts)
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
            if access.canInviteMembers {
                onInvite(group)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func primaryAlertButton(for action: PendingMemberAction) -> Alert.Button {
        let label = Text(action.confirmTitleKey)
        let confirm = { performConfirmedAction(action) }
        return action.isDestructive
            ? .destructive(label, action: confirm)
            : .default(label, action: confirm)
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
            case .transferOwnership:
                try GroupRepository().transferOwnership(to: action.member, in: group)
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

/// Whether a member row offers ownership transfer. A blocked option is still shown,
/// carrying its reason, so the missing participant mapping is visible instead of the
/// action simply not being there.
private enum OwnershipTransferOption {
    case available
    case blocked(reason: LedgerStringKey)
}

private struct PendingMemberAction: Identifiable {
    enum Kind {
        case revokeInvitation
        case removeMember
        case leaveGroup
        case transferOwnership
    }

    let id = UUID()
    let kind: Kind
    let member: Member

    var titleKey: LedgerStringKey {
        switch kind {
        case .revokeInvitation: .memberConfirmRevokeTitle
        case .removeMember: .memberConfirmRemoveTitle
        case .leaveGroup: .memberConfirmLeaveTitle
        case .transferOwnership: .memberConfirmTransferOwnershipTitle
        }
    }

    /// 退出群組講的是自己，不帶名字；其餘三種都在講被操作的那個人。
    var message: String {
        let name = member.displayName ?? LedgerStringKey.commonPlaceholderUnnamedMember.string()
        switch kind {
        case .revokeInvitation:
            return LedgerStringKey.memberConfirmRevokeMessage.string(arguments: [name])
        case .removeMember:
            return LedgerStringKey.memberConfirmRemoveMessage.string(arguments: [name])
        case .leaveGroup:
            return LedgerStringKey.memberConfirmLeaveMessage.string()
        case .transferOwnership:
            return LedgerStringKey.memberConfirmTransferOwnershipMessage.string(arguments: [name])
        }
    }

    var confirmTitleKey: LedgerStringKey {
        switch kind {
        case .revokeInvitation: .memberConfirmRevokeAction
        case .removeMember: .memberConfirmRemoveAction
        case .leaveGroup: .memberConfirmLeaveAction
        case .transferOwnership: .memberConfirmTransferOwnershipAction
        }
    }

    /// Ownership transfer changes who is in charge rather than taking something away,
    /// so it must not borrow the destructive alert styling of the other actions.
    var isDestructive: Bool {
        kind != .transferOwnership
    }
}

private struct MemberRow: View {
    @ObservedObject var member: Member
    let participantStatus: CloudParticipantStatus
    let isCurrentUser: Bool
    let canManage: Bool
    let ownershipTransfer: OwnershipTransferOption?
    let onResend: () -> Void
    let onRevoke: () -> Void
    let onRemove: () -> Void
    let onTransferOwnership: () -> Void

    private var name: String {
        member.displayName ?? LedgerStringKey.commonPlaceholderUnnamedMember.string()
    }

    private var roleName: String {
        member.role.flatMap(MemberRole.init(rawValue:))?.displayName
            ?? MemberRole.member.displayName
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
                Text(verbatim: name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isInactive ? .secondary : .primary)
                Text(verbatim: roleName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let participantBadge = participantStatus.badgeText {
                    Label {
                        // 徽章文字來自 `CloudParticipantStatus`，那一層還沒遷移。
                        Text(verbatim: participantBadge)
                    } icon: {
                        Image(systemName: participantIcon)
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(participantTint)
                    .accessibilityLabel(Text(verbatim: LedgerStringKey
                        .memberParticipantAccessibilityLabel
                        .string(arguments: [participantBadge])))
                }
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

    private var participantIcon: String {
        switch participantStatus {
        case .notShared, .unmapped:
            return "person.crop.circle.badge.questionmark"
        case .shareUnavailable:
            return "icloud.slash"
        case .participantMissing:
            return "person.crop.circle.badge.exclamationmark"
        case let .mapped(canWrite, _, isAccepted):
            if !isAccepted { return "clock" }
            return canWrite ? "icloud.and.arrow.up" : "eye"
        }
    }

    private var participantTint: Color {
        switch participantStatus {
        case .notShared, .unmapped, .shareUnavailable:
            return .secondary
        case .participantMissing:
            return LedgerTheme.coral
        case let .mapped(canWrite, _, isAccepted):
            if !isAccepted { return LedgerTheme.amber }
            return canWrite ? LedgerTheme.primary : LedgerTheme.amber
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isPending {
            Text(.memberBadgePending)
                .font(.caption.weight(.semibold))
                .foregroundStyle(LedgerTheme.amber)
        } else if isRevoked {
            Text(.memberBadgeRevoked)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        } else if isInactive {
            Text(.memberBadgeInactive)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        } else if isCurrentUser {
            Text(.memberBadgeCurrentUser)
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
                    Label(.memberActionResend, systemImage: "paperplane")
                }
            }
            if isPending {
                Button(role: .destructive, action: onRevoke) {
                    Label(.memberActionRevoke, systemImage: "xmark.circle")
                }
            }
            if !isCurrentUser,
               !isInactive,
               member.invitationStatus == InvitationStatus.accepted.rawValue,
               role != .owner {
                Button(role: .destructive, action: onRemove) {
                    Label(.memberActionRemove, systemImage: "person.badge.minus")
                }
            }
            if let ownershipTransfer {
                switch ownershipTransfer {
                case .available:
                    Button(action: onTransferOwnership) {
                        Label(
                            .memberActionTransferOwnership,
                            systemImage: "person.crop.circle.badge.checkmark"
                        )
                    }
                case let .blocked(reason):
                    Button {} label: {
                        Label(reason, systemImage: "person.crop.circle.badge.exclamationmark")
                    }
                    .accessibilityLabel(Text(reason))
                    .disabled(true)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel(Text(verbatim: LedgerStringKey.memberMenuAccessibilityLabel
            .string(arguments: [name])))
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
            Section {
                TextField("", text: $name, prompt: Text(.groupFieldName))
                    .accessibilityLabel(Text(.groupFieldName))
            } header: {
                Text(.groupFieldName)
            }
        }
        .navigationTitle(Text(.groupRenameTitle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: {
                    Text(.commonActionCancel)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: save) {
                    Text(.commonActionSave)
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .alert(Text(.commonErrorRenameFailed), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(role: .cancel) {} label: {
                Text(.commonActionOK)
            }
        } message: {
            Text(verbatim: errorMessage ?? LedgerStringKey.commonErrorRetryLater.string())
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
