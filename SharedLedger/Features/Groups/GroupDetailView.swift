import Foundation
import SwiftUI

struct GroupDetailView: View {
    @ObservedObject var group: LedgerGroup
    let onInvite: (LedgerGroup) -> Void

    private var members: [Member] {
        let set = group.members as? Set<Member> ?? []
        return set.sorted { ($0.displayName ?? "") < ($1.displayName ?? "") }
    }

    private var accounts: [LedgerAccount] {
        let set = group.accounts as? Set<LedgerAccount> ?? []
        return Array(set)
    }

    private var totalAccountBalance: Decimal {
        AccountRepository().totalBalance(for: accounts)
    }

    var body: some View {
        ZStack {
            LedgerBackground()
            ScrollView {
                VStack(spacing: 18) {
                    heroCard
                    VStack(alignment: .leading, spacing: 12) {
                        LedgerSectionHeader(title: "成員")
                        LedgerCard(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(members.enumerated()), id: \.element.objectID) { index, member in
                                    MemberRow(member: member)
                                    if index < members.count - 1 {
                                        Divider().padding(.leading, 72)
                                    }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        LedgerSectionHeader(title: "帳本設定")
                        LedgerCard(padding: 0) {
                            VStack(spacing: 0) {
                                NavigationLink {
                                    AccountsView(group: group)
                                } label: {
                                    LedgerNavRow(title: "帳號", detail: "現金、銀行帳號", icon: "creditcard.fill", tint: .blue)
                                }
                                .buttonStyle(.plain)
                                Divider().padding(.leading, 68)
                                NavigationLink {
                                    CategoriesView(group: group)
                                } label: {
                                    LedgerNavRow(title: "分類", detail: "整理收支類別", icon: "square.grid.2x2.fill", tint: LedgerTheme.amber)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Button {
                        onInvite(group)
                    } label: {
                        Label("邀請更多成員", systemImage: "person.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(LedgerPrimaryButtonStyle())
                }
                .padding(.horizontal, LedgerTheme.pagePadding)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle(group.name ?? "群組")
        .navigationBarTitleDisplayMode(.inline)
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
                    Text("\(members.count) 位成員 · 共同餘額 \(ledgerGroupAmount(totalAccountBalance))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private func ledgerGroupAmount(_ amount: Decimal) -> String {
    "$" + (amount as NSDecimalNumber).stringValue
}

private struct MemberRow: View {
    @ObservedObject var member: Member

    private var name: String {
        member.displayName ?? "未命名成員"
    }

    var body: some View {
        HStack(spacing: 14) {
            LedgerAvatar(name: name, size: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                Text((member.role == MemberRole.owner.rawValue) ? "群組擁有者" : "成員")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if member.invitationStatus == InvitationStatus.pending.rawValue {
                Text("待邀請")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LedgerTheme.amber)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(LedgerTheme.amber.opacity(0.12), in: Capsule())
            } else if member.isCurrentUser {
                Text("你")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
