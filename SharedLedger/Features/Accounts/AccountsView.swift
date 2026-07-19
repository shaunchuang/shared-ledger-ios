import CoreData
import SwiftUI

struct AccountsView: View {
    @ObservedObject var group: LedgerGroup

    @FetchRequest private var accounts: FetchedResults<LedgerAccount>

    @State private var isPresentingNewAccount = false
    @State private var errorMessage: String?

    init(group: LedgerGroup) {
        self.group = group
        _accounts = FetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \LedgerAccount.createdAt, ascending: true)],
            predicate: NSPredicate(format: "group == %@ AND archivedAt == nil", group),
            animation: .default
        )
    }

    var body: some View {
        ZStack {
            LedgerBackground()
            ScrollView {
                LazyVStack(spacing: 16) {
                    if accounts.isEmpty {
                        LedgerEmptyState(
                            systemImage: "creditcard",
                            title: "還沒有帳號",
                            message: "新增現金或銀行帳號，開始記錄這個群組的收支。",
                            actionTitle: "新增帳號"
                        ) {
                            isPresentingNewAccount = true
                        }
                    } else {
                        LedgerCard(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(accounts.enumerated()), id: \.element.objectID) { index, account in
                                    AccountRow(account: account) {
                                        archive(account)
                                    }
                                    if index < accounts.count - 1 {
                                        Divider().padding(.leading, 68)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, LedgerTheme.pagePadding)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("帳號")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button {
                isPresentingNewAccount = true
            } label: {
                Image(systemName: "plus")
                    .fontWeight(.bold)
            }
            .accessibilityLabel("新增帳號")
        }
        .sheet(isPresented: $isPresentingNewAccount) {
            NavigationStack {
                NewAccountView(group: group) {
                    isPresentingNewAccount = false
                }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .alert("無法更新帳號", isPresented: errorBinding) {
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

    private func archive(_ account: LedgerAccount) {
        do {
            try AccountRepository().archiveAccount(account)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct AccountRow: View {
    @ObservedObject var account: LedgerAccount
    let onArchive: () -> Void

    private var type: AccountType {
        AccountType(rawValue: account.accountType ?? "") ?? .cash
    }

    var body: some View {
        HStack(spacing: 14) {
            LedgerIconBadge(systemImage: type.systemImage)
            VStack(alignment: .leading, spacing: 3) {
                Text(account.name ?? "未命名帳號")
                    .font(.subheadline.weight(.semibold))
                Text(type.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive, action: onArchive) {
                Image(systemName: "archivebox")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("封存帳號")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
