import CoreData
import SwiftUI

struct GroupsView: View {
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \LedgerGroup.updatedAt, ascending: false)],
        animation: .default
    ) private var groups: FetchedResults<LedgerGroup>

    @State private var isCreatingGroup = false
    @State private var sharePayload: CloudSharePayload?
    @State private var sharingError: String?

    var body: some View {
        ZStack {
            LedgerBackground()
            ScrollView {
                LazyVStack(spacing: 16) {
                    if groups.isEmpty {
                        emptyState
                    } else {
                        groupSummary
                        ForEach(groups, id: \.objectID) { group in
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
        .navigationTitle("群組")
        .toolbar {
            Button {
                isCreatingGroup = true
            } label: {
                Image(systemName: "plus")
                    .fontWeight(.bold)
            }
            .accessibilityLabel("建立群組")
        }
        .sheet(isPresented: $isCreatingGroup) {
            NavigationStack {
                CreateGroupView { group in
                    prepareShare(group)
                }
            }
        }
        .sheet(item: $sharePayload) { payload in
            CloudSharingView(payload: payload)
        }
        .alert("無法建立邀請", isPresented: sharingErrorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(sharingError ?? "請確認 iCloud 狀態後再試。")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            HStack(spacing: 13) {
                LedgerMark(size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("一起記帳")
                        .font(.headline)
                    Text("共享每一筆，也共享安心")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            LedgerEmptyState(
                systemImage: "person.3.fill",
                title: "建立第一個群組",
                message: "適合家庭、伴侶、室友或旅行。邀請成員後，大家都能看到同一份帳本。",
                actionTitle: "建立群組"
            ) {
                isCreatingGroup = true
            }
        }
    }

    private var groupSummary: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("你的共享空間")
                    .font(.title3.weight(.bold))
                Text("共 \(groups.count) 個群組")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            LedgerIconBadge(systemImage: "person.3.fill")
        }
        .padding(.bottom, 2)
    }

    private var sharingErrorBinding: Binding<Bool> {
        Binding(
            get: { sharingError != nil },
            set: { if !$0 { sharingError = nil } }
        )
    }

    private func prepareShare(_ group: LedgerGroup) {
        Task {
            do {
                let (share, container) = try await PersistenceController.shared.prepareShare(for: group)
                sharePayload = CloudSharePayload(
                    share: share,
                    container: container,
                    title: group.name ?? "Shared Ledger 群組"
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

    private var pendingMembers: [Member] {
        let members = group.members as? Set<Member> ?? []
        return members
            .filter {
                $0.invitationStatus == InvitationStatus.pending.rawValue
                    && ($0.role == MemberRole.member.rawValue
                        || $0.role == MemberRole.viewer.rawValue)
            }
            .sorted { ($0.displayName ?? "") < ($1.displayName ?? "") }
    }

    var body: some View {
        Form {
            Section {
                Text("為了讓付款人、分攤與權限正確，請確認你在「\(group.name ?? "共享群組")」中的成員身分。這項對應只會保存到你的私人 iCloud 資料。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !pendingMembers.isEmpty {
                Section("選擇邀請你的名稱") {
                    ForEach(pendingMembers, id: \.objectID) { member in
                        Button {
                            claim(member)
                        } label: {
                            HStack {
                                Text(member.displayName ?? "未命名成員")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "checkmark.circle")
                                    .foregroundStyle(LedgerTheme.primary)
                            }
                        }
                    }
                }
            }

            Section("找不到你的名稱？") {
                TextField("你的顯示名稱", text: $displayName)
                Button("以新成員加入") {
                    joinAsNewMember()
                }
                .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle("確認成員身分")
        .navigationBarTitleDisplayMode(.inline)
        .alert("無法確認身分", isPresented: errorBinding) {
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

    private var pendingCount: Int {
        members.filter { $0.invitationStatus == InvitationStatus.pending.rawValue }.count
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
                    Text(group.name ?? "未命名群組")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    HStack(spacing: 8) {
                        Label("\(members.count) 位成員", systemImage: "person.2")
                        if pendingCount > 0 {
                            Text("·")
                            Text("\(pendingCount) 位待邀請")
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
            }
        }
    }
}

#Preview {
    NavigationStack { GroupsView() }
        .environment(
            \.managedObjectContext,
            PersistenceController(inMemory: true).container.viewContext
        )
}

