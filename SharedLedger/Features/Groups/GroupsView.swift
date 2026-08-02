import CoreData
import SwiftUI

struct GroupsView: View {
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \LedgerGroup.updatedAt, ascending: false)],
        animation: .default
    ) private var groups: FetchedResults<LedgerGroup>

    @Environment(\.managedObjectContext) private var context

    @State private var isCreatingGroup = false
    @State private var sharePayload: CloudSharePayload?
    @State private var sharingError: String?
    @State private var isPreparingShare = false
    /// Groups this device has been removed from. Deciding that per group runs a fetch
    /// against the private `LocalMemberIdentity` store, so it is resolved when the
    /// groups or their members change instead of on every `body` pass.
    @State private var removedGroupIDs: Set<NSManagedObjectID> = []

    private var visibleGroups: [LedgerGroup] {
        groups.filter { !removedGroupIDs.contains($0.objectID) }
    }

    var body: some View {
        ZStack {
            LedgerBackground()
            ScrollView {
                LazyVStack(spacing: 16) {
                    if visibleGroups.isEmpty {
                        emptyState
                    } else {
                        groupSummary
                        ForEach(visibleGroups, id: \.objectID) { group in
                            NavigationLink {
                                GroupDetailView(group: group, onInvite: prepareShare)
                            } label: {
                                GroupCard(group: group)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, LedgerTheme.pagePadding)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle(Text(.groupTitle))
        .onAppear(perform: reloadRemovedGroups)
        .onReceive(
            NotificationCenter.default.publisher(
                for: .NSManagedObjectContextObjectsDidChange,
                object: context
            )
        ) { notification in
            guard ContextChangeObserver.touches(notification, .groupPermissions) else { return }
            reloadRemovedGroups()
        }
        .toolbar {
            Button {
                isCreatingGroup = true
            } label: {
                Image(systemName: "plus")
                    .fontWeight(.bold)
            }
            .accessibilityLabel(Text(.groupActionCreate))
        }
        .sheet(isPresented: $isCreatingGroup) {
            NavigationStack {
                CreateGroupView { group in
                    prepareShare(group)
                }
            }
        }
        .sheet(item: $sharePayload) { payload in
            CloudSharingView(payload: payload) { message in
                sharePayload = nil
                sharingError = message
            }
        }
        .alert(Text(.groupErrorShareTitle), isPresented: sharingErrorBinding) {
            Button(role: .cancel) {} label: {
                Text(.commonActionOK)
            }
        } message: {
            // CloudKit 的錯誤說明由系統提供，只有預設訊息是自己的文案。
            Text(verbatim: sharingError ?? LedgerStringKey.groupErrorShareMessage.string())
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            HStack(spacing: 13) {
                LedgerMark(size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(.groupEmptyHeroTitle)
                        .font(.headline)
                    Text(.groupEmptyHeroSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            LedgerEmptyState(
                systemImage: "person.3.fill",
                title: .groupEmptyTitle,
                message: .groupEmptyMessage,
                actionTitle: .groupActionCreate
            ) {
                isCreatingGroup = true
            }
        }
    }

    private var groupSummary: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(.groupSummaryTitle)
                    .font(.title3.weight(.bold))
                Text(verbatim: LedgerStringKey.groupSummaryCount.string(
                    arguments: [Int64(visibleGroups.count)]
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer()
            LedgerIconBadge(systemImage: "person.3.fill")
        }
        .padding(.bottom, 2)
    }

    private func reloadRemovedGroups() {
        let identities = CurrentMemberIdentityRepository()
        removedGroupIDs = Set(
            groups
                .filter { identities.hasInactiveIdentity(in: $0) }
                .map(\.objectID)
        )
    }

    private var sharingErrorBinding: Binding<Bool> {
        Binding(
            get: { sharingError != nil },
            set: { if !$0 { sharingError = nil } }
        )
    }

    @MainActor
    private func prepareShare(_ group: LedgerGroup) {
        guard !isPreparingShare else { return }
        isPreparingShare = true

        Task { @MainActor in
            defer { isPreparingShare = false }

            do {
                let persistence = PersistenceController.shared
                let (share, container) = try await persistence.prepareShare(for: group)
                sharePayload = CloudSharePayload(
                    share: share,
                    container: container,
                    store: persistence.store(for: group),
                    group: group,
                    title: group.name ?? LedgerStringKey.groupShareDefaultTitle.string()
                )
            } catch {
                sharingError = error.localizedDescription
            }
        }
    }
}

struct MemberIdentitySelectionView: View {
    @ObservedObject var group: LedgerGroup
    let onResolved: () -> Void

    @State private var displayName = ""
    @State private var errorMessage: String?

    private var inactiveIdentity: Bool {
        CurrentMemberIdentityRepository().hasInactiveIdentity(in: group)
    }

    private var pendingMembers: [Member] {
        let members = group.members as? Set<Member> ?? []
        return members
            .filter {
                $0.archivedAt == nil
                    && $0.invitationStatus == InvitationStatus.pending.rawValue
                    && ($0.role == MemberRole.member.rawValue
                        || $0.role == MemberRole.viewer.rawValue)
            }
            .sorted { ($0.displayName ?? "") < ($1.displayName ?? "") }
    }

    var body: some View {
        Form {
            Section {
                Text(verbatim: LedgerStringKey.memberIdentityIntro.string(arguments: [groupName]))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if inactiveIdentity {
                Section {
                    Text(.memberIdentityInactive)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                if !pendingMembers.isEmpty {
                    Section {
                        ForEach(pendingMembers, id: \.objectID) { member in
                            let name = member.displayName
                                ?? LedgerStringKey.commonPlaceholderUnnamedMember.string()
                            Button {
                                claim(member)
                            } label: {
                                HStack {
                                    Text(verbatim: name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "checkmark.circle")
                                        .foregroundStyle(LedgerTheme.primary)
                                        .accessibilityHidden(true)
                                }
                            }
                            .accessibilityLabel(Text(verbatim: name))
                        }
                    } header: {
                        Text(.memberIdentitySectionPending)
                    }
                }

                Section {
                    TextField(
                        "",
                        text: $displayName,
                        prompt: Text(.memberIdentityDisplayNamePlaceholder)
                    )
                    .accessibilityLabel(Text(.memberIdentityDisplayNamePlaceholder))
                    Button {
                        joinAsNewMember()
                    } label: {
                        Text(.memberIdentityActionJoinAsNew)
                    }
                    .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text(.memberIdentitySectionNotListed)
                }
            }
        }
        .navigationTitle(Text(.memberIdentityTitle))
        .navigationBarTitleDisplayMode(.inline)
        .alert(Text(.memberIdentityErrorTitle), isPresented: errorBinding) {
            Button(role: .cancel) {} label: {
                Text(.commonActionOK)
            }
        } message: {
            Text(verbatim: errorMessage ?? LedgerStringKey.commonErrorRetryLater.string())
        }
    }

    private var groupName: String {
        group.name ?? LedgerStringKey.memberIdentityGroupFallback.string()
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func claim(_ member: Member) {
        do {
            try GroupRepository().claimCurrentMember(member, in: group)
            onResolved()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func joinAsNewMember() {
        do {
            try GroupRepository().joinSharedGroup(
                displayName: displayName,
                group: group
            )
            onResolved()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct GroupCard: View {
    @ObservedObject var group: LedgerGroup

    private var members: [Member] {
        Array(group.members as? Set<Member> ?? [])
    }

    private var activeCount: Int {
        members.filter {
            $0.archivedAt == nil
                && $0.invitationStatus == InvitationStatus.accepted.rawValue
        }.count
    }

    private var pendingCount: Int {
        members.filter {
            $0.archivedAt == nil
                && $0.invitationStatus == InvitationStatus.pending.rawValue
        }.count
    }

    var body: some View {
        LedgerCard {
            HStack(spacing: 15) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(LedgerTheme.mint.opacity(0.20))
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(LedgerTheme.primary)
                }
                .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: group.name
                        ?? LedgerStringKey.commonPlaceholderUnnamedGroup.string())
                        .font(.headline)
                        .foregroundStyle(.primary)
                    HStack(spacing: 8) {
                        Label {
                            Text(verbatim: LedgerStringKey.groupCardMemberCount.string(
                                arguments: [Int64(activeCount)]
                            ))
                        } icon: {
                            Image(systemName: "person.2")
                        }
                        // 分隔點是版面符號，不是文案。
                        Text(verbatim: "·")
                        Text(verbatim: LedgerCurrency.normalizedCode(group.currencyCode))
                        if pendingCount > 0 {
                            Text(verbatim: "·")
                            Text(verbatim: LedgerStringKey.groupCardPendingCount.string(
                                arguments: [Int64(pendingCount)]
                            ))
                            .foregroundStyle(LedgerTheme.amber)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        // 一張卡片就是一個群組：名稱、成員數與貨幣分開唸只會讓人不知道停在哪一個。
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack { GroupsView() }
        .environment(
            \.managedObjectContext,
            PersistenceController(inMemory: true).container.viewContext
        )
}
