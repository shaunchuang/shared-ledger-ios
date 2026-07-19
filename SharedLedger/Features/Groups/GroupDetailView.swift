import Foundation
import SwiftUI

struct GroupDetailView: View {
    @ObservedObject var group: LedgerGroup
    let onInvite: (LedgerGroup) -> Void

    @AppStorage private var selectedBookID: String

    init(group: LedgerGroup, onInvite: @escaping (LedgerGroup) -> Void) {
        self.group = group
        self.onInvite = onInvite
        _selectedBookID = AppStorage(
            wrappedValue: "",
            BookSelectionStorage.key(for: group)
        )
    }

    private var members: [Member] {
        let set = group.members as? Set<Member> ?? []
        return set.sorted { ($0.displayName ?? "") < ($1.displayName ?? "") }
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

    var body: some View {
        ZStack {
            LedgerBackground()
            ScrollView {
                VStack(spacing: 18) {
                    heroCard
                    bookSection
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
                        LedgerSectionHeader(title: "群組帳號")
                        LedgerCard(padding: 0) {
                            NavigationLink {
                                AccountsView(group: group)
                            } label: {
                                LedgerNavRow(
                                    title: "帳號",
                                    detail: "所有帳本共用的現金、銀行與信用卡",
                                    icon: "creditcard.fill",
                                    tint: .blue
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        LedgerSectionHeader(title: "目前帳本設定")
                        LedgerCard(padding: 0) {
                            VStack(spacing: 0) {
                                if let selectedBook {
                                    NavigationLink {
                                        CategoriesView(book: selectedBook)
                                    } label: {
                                        LedgerNavRow(
                                            title: "分類",
                                            detail: "整理\(selectedBook.name ?? "目前帳本")的收支類別",
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
        .onAppear(perform: normalizeSelectedBook)
        .onChange(of: activeBooks.count) { _ in
            normalizeSelectedBook()
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
                    Text("\(members.count) 位成員 · 共同餘額 \(ledgerGroupAmount(totalAccountBalance))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
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
