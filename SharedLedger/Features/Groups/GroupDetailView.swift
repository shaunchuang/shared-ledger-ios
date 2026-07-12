import SwiftUI

struct GroupDetailView: View {
    @ObservedObject var group: LedgerGroup
    let onInvite: (LedgerGroup) -> Void

    private var members: [Member] {
        let set = group.members as? Set<Member> ?? []
        return set.sorted { ($0.displayName ?? "") < ($1.displayName ?? "") }
    }

    var body: some View {
        List {
            Section("成員") {
                ForEach(members, id: \.objectID) { member in
                    HStack {
                        Label(member.displayName ?? "未命名成員", systemImage: "person.crop.circle")
                        Spacer()
                        if member.invitationStatus == InvitationStatus.pending.rawValue {
                            Text("待邀請")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else if member.isCurrentUser {
                            Text("你")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Button("邀請成員", systemImage: "person.badge.plus") {
                    onInvite(group)
                }
            }
        }
        .navigationTitle(group.name ?? "群組")
    }
}

