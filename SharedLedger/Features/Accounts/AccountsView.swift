import CoreData
import SwiftUI

struct AccountsView: View {
    @ObservedObject var group: LedgerGroup

    @FetchRequest private var accounts: FetchedResults<LedgerAccount>
    private let accountRepository = AccountRepository()

    @State private var isPresentingNewAccount = false
    @State private var accountPendingArchive: LedgerAccount?
    @State private var errorMessage: String?
    @State private var accountBalances: [NSManagedObjectID: Decimal] = [:]
    @State private var hasLoadedBalances = false

    init(group: LedgerGroup) {
        self.group = group
        _accounts = FetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \LedgerAccount.createdAt, ascending: true)],
            predicate: NSPredicate(format: "group == %@", group),
            animation: .default
        )
    }

    private var activeAccounts: [LedgerAccount] {
        accounts.filter { $0.archivedAt == nil }
    }

    private var archivedAccounts: [LedgerAccount] {
        accounts.filter { $0.archivedAt != nil }
    }

    private func balances(for accounts: [LedgerAccount], repository: AccountRepository) -> [NSManagedObjectID: Decimal] {
        Dictionary(
            uniqueKeysWithValues: accounts.map { account in
                (account.objectID, repository.currentBalance(for: account))
            }
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
                            title: "還沒有帳戶",
                            message: "新增現金或銀行帳戶，設定期初餘額後開始記錄收支。",
                            actionTitle: "新增帳戶"
                        ) {
                            isPresentingNewAccount = true
                        }
                    } else if !activeAccounts.isEmpty {
                        LedgerCard(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(activeAccounts.enumerated()), id: \.element.objectID) { index, account in
                                    AccountRow(
                                        account: account,
                                        balance: accountBalances[account.objectID] ?? 0,
                                        onArchive: { accountPendingArchive = account }
                                    )
                                    if index < activeAccounts.count - 1 {
                                        Divider().padding(.leading, 68)
                                    }
                                }
                            }
                        }
                    }

                    if !archivedAccounts.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            LedgerSectionHeader(title: "已封存帳戶")
                            LedgerCard(padding: 0) {
                                VStack(spacing: 0) {
                                    ForEach(Array(archivedAccounts.enumerated()), id: \.element.objectID) { index, account in
                                        AccountRow(
                                            account: account,
                                            balance: accountBalances[account.objectID] ?? 0,
                                            onArchive: nil
                                        )
                                        if index < archivedAccounts.count - 1 {
                                            Divider().padding(.leading, 68)
                                        }
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
        .navigationTitle("帳戶")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button {
                isPresentingNewAccount = true
            } label: {
                Image(systemName: "plus")
                    .fontWeight(.bold)
            }
            .accessibilityLabel("新增帳戶")
        }
        .sheet(isPresented: $isPresentingNewAccount) {
            NavigationStack {
                NewAccountView(group: group) {
                    isPresentingNewAccount = false
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "封存帳戶？",
            isPresented: archiveConfirmationBinding,
            titleVisibility: .visible,
            presenting: accountPendingArchive
        ) { account in
            Button("封存「\(account.name ?? "未命名帳戶")」", role: .destructive) {
                archive(account)
            }
            Button("取消", role: .cancel) {}
        } message: { account in
            if accountRepository.hasHistory(account) {
                Text("這個帳戶已有交易或餘額調整，封存後仍會保留完整歷史。")
            } else {
                Text("封存後不會再出現在新增交易的帳戶選單中。")
            }
        }
        .alert("無法更新帳戶", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "請稍後再試。")
        }
        .onAppear {
            guard !hasLoadedBalances else { return }
            hasLoadedBalances = true
            refreshBalances()
        }
        .onChange(of: accounts.count) {
            refreshBalances()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .NSManagedObjectContextObjectsDidChange,
                object: group.managedObjectContext
            )
        ) { notification in
            guard shouldRefreshBalances(for: notification) else { return }
            refreshBalances()
        }
    }

    private var archiveConfirmationBinding: Binding<Bool> {
        Binding(
            get: { accountPendingArchive != nil },
            set: { if !$0 { accountPendingArchive = nil } }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func archive(_ account: LedgerAccount) {
        do {
            try accountRepository.archiveAccount(account)
            accountPendingArchive = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshBalances() {
        accountBalances = balances(for: Array(accounts), repository: accountRepository)
    }

    private func shouldRefreshBalances(for notification: Notification) -> Bool {
        let accountIDs = Set(accounts.map(\.objectID))
        let changedObjects = (
            (notification.userInfo?[NSInsertedObjectsKey] as? Set<NSManagedObject>) ?? []
        ).union(
            (notification.userInfo?[NSUpdatedObjectsKey] as? Set<NSManagedObject>) ?? []
        ).union(
            (notification.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject>) ?? []
        )

        return changedObjects.contains { object in
            if let ledgerAccount = object as? LedgerAccount {
                return accountIDs.contains(ledgerAccount.objectID)
            }
            if let entry = object as? LedgerEntry {
                if let sourceID = entry.sourceAccount?.objectID, accountIDs.contains(sourceID) {
                    return true
                }
                if let destinationID = entry.destinationAccount?.objectID, accountIDs.contains(destinationID) {
                    return true
                }
            }
            if let adjustment = object as? AccountAdjustment,
               let accountID = adjustment.account?.objectID {
                return accountIDs.contains(accountID)
            }
            return false
        }
    }
}

private struct AccountRow: View {
    @ObservedObject var account: LedgerAccount
    let balance: Decimal
    let onArchive: (() -> Void)?

    private var type: AccountType {
        AccountType(rawValue: account.accountType ?? "") ?? .cash
    }

    var body: some View {
        HStack(spacing: 4) {
            NavigationLink {
                AccountDetailView(account: account)
            } label: {
                HStack(spacing: 14) {
                    LedgerIconBadge(systemImage: type.systemImage)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.name ?? "未命名帳戶")
                            .font(.subheadline.weight(.semibold))
                        Text(account.archivedAt == nil ? type.displayName : "\(type.displayName) · 已封存")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(ledgerAmount(balance, currencyCode: account.group?.currencyCode))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(balance < 0 ? LedgerTheme.coral : .primary)
                        Text("目前餘額")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let onArchive {
                Menu {
                    Button(role: .destructive, action: onArchive) {
                        Label("封存帳戶", systemImage: "archivebox")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 32, height: 44)
                }
                .accessibilityLabel("帳戶選項")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct AccountDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var account: LedgerAccount
    private let accountRepository = AccountRepository()

    @FetchRequest private var entries: FetchedResults<LedgerEntry>
    @FetchRequest private var adjustments: FetchedResults<AccountAdjustment>

    @State private var isAdjustingBalance = false
    @State private var isConfirmingReconciliation = false
    @State private var isConfirmingArchive = false
    @State private var errorMessage: String?

    init(account: LedgerAccount) {
        self.account = account
        _entries = FetchRequest(
            sortDescriptors: [
                NSSortDescriptor(keyPath: \LedgerEntry.date, ascending: false),
                NSSortDescriptor(keyPath: \LedgerEntry.createdAt, ascending: false)
            ],
            predicate: NSPredicate(
                format: "sourceAccount == %@ OR destinationAccount == %@",
                account,
                account
            ),
            animation: .default
        )
        _adjustments = FetchRequest(
            sortDescriptors: [
                NSSortDescriptor(keyPath: \AccountAdjustment.createdAt, ascending: false)
            ],
            predicate: NSPredicate(format: "account == %@", account),
            animation: .default
        )
    }

    var body: some View {
        let currentBalance = accountRepository.currentBalance(for: account)

        ZStack {
            LedgerBackground()
            ScrollView {
                VStack(spacing: 18) {
                    balanceCard(currentBalance)
                    reconciliationCard
                    transactionHistory
                }
                .padding(.horizontal, LedgerTheme.pagePadding)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle(account.name ?? "帳戶明細")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if account.archivedAt == nil {
                Menu {
                    Button("調整餘額", systemImage: "slider.horizontal.3") {
                        isAdjustingBalance = true
                    }
                    Button("完成對帳", systemImage: "checkmark.seal") {
                        isConfirmingReconciliation = true
                    }
                    Divider()
                    Button("封存帳戶", systemImage: "archivebox", role: .destructive) {
                        isConfirmingArchive = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("帳戶操作")
            }
        }
        .sheet(isPresented: $isAdjustingBalance) {
            NavigationStack {
                BalanceAdjustmentView(account: account, currentBalance: currentBalance) {
                    isAdjustingBalance = false
                }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "確認完成對帳？",
            isPresented: $isConfirmingReconciliation,
            titleVisibility: .visible
        ) {
            Button("以目前餘額完成對帳") { reconcile() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("系統會保存目前餘額 \(ledgerAmount(currentBalance, currencyCode: account.group?.currencyCode)) 與對帳時間。")
        }
        .confirmationDialog(
            "封存帳戶？",
            isPresented: $isConfirmingArchive,
            titleVisibility: .visible
        ) {
            Button("封存帳戶", role: .destructive) { archive() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(historyItems.isEmpty
                 ? "封存後不會再出現在新增交易的帳戶選單中。"
                 : "所有歷史交易與餘額調整都會保留，不會被刪除。")
        }
        .alert("無法更新帳戶", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "請稍後再試。")
        }
    }

    private func balanceCard(_ currentBalance: Decimal) -> some View {
        LedgerCard {
            VStack(alignment: .leading, spacing: 16) {
                Label("目前餘額", systemImage: "creditcard.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(ledgerAmount(currentBalance, currencyCode: account.group?.currencyCode))
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(currentBalance < 0 ? LedgerTheme.coral : LedgerTheme.primaryStrong)
                    .contentTransition(.numericText())
                HStack {
                    Text("期初餘額")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(ledgerAmount((account.openingBalance as Decimal?) ?? 0, currencyCode: account.group?.currencyCode))
                        .fontWeight(.semibold)
                }
                .font(.subheadline)
            }
        }
    }

    private var reconciliationCard: some View {
        LedgerCard {
            VStack(alignment: .leading, spacing: 10) {
                LedgerSectionHeader(title: "最近對帳")
                if let date = account.lastReconciledAt,
                   let balance = account.lastReconciledBalance as Decimal? {
                    HStack {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(ledgerAmount(balance, currencyCode: account.group?.currencyCode))
                            .fontWeight(.semibold)
                    }
                    .font(.subheadline)
                } else {
                    Text("尚未對帳。確認實際帳戶餘額後，可保存目前餘額與時間作為核對基準。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var transactionHistory: some View {
        VStack(alignment: .leading, spacing: 12) {
            LedgerSectionHeader(title: "帳戶明細")
            if historyItems.isEmpty {
                LedgerEmptyState(
                    systemImage: "list.bullet.rectangle",
                    title: "尚無交易",
                    message: "收入、支出、轉帳與餘額調整會顯示在這裡。"
                )
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(historyItems) { item in
                        switch item {
                        case .entry(let entry):
                            AccountEntryRow(entry: entry, account: account)
                        case .adjustment(let adjustment):
                            AccountAdjustmentRow(adjustment: adjustment)
                        }
                    }
                }
            }
        }
    }

    private var historyItems: [AccountHistoryItem] {
        let entryItems = entries.map(AccountHistoryItem.entry)
        let adjustmentItems = adjustments.map(AccountHistoryItem.adjustment)
        return (entryItems + adjustmentItems).sorted { $0.date > $1.date }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func reconcile() {
        do {
            try AccountRepository().reconcile(account)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func archive() {
        do {
            try AccountRepository().archiveAccount(account)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct BalanceAdjustmentView: View {
    @Environment(\.dismiss) private var dismiss

    let account: LedgerAccount
    let onSaved: () -> Void

    @State private var targetBalanceText: String
    @State private var note = ""
    @State private var errorMessage: String?

    init(account: LedgerAccount, currentBalance: Decimal, onSaved: @escaping () -> Void) {
        self.account = account
        self.onSaved = onSaved
        _targetBalanceText = State(initialValue: (currentBalance as NSDecimalNumber).stringValue)
    }

    private var targetBalance: Decimal? {
        Decimal(string: targetBalanceText.trimmingCharacters(in: .whitespaces))
    }

    private var currencyCode: String {
        LedgerCurrency.normalizedCode(account.group?.currencyCode)
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(currencyCode)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("0", text: $targetBalanceText)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("實際餘額")
            } footer: {
                Text("系統會新增一筆差額調整，不會改寫或刪除既有交易。")
            }

            Section("備註") {
                TextField("例如：依銀行帳單調整", text: $note)
            }
        }
        .navigationTitle("調整餘額")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("儲存", action: save)
                    .disabled(targetBalance == nil)
            }
        }
        .alert("無法調整餘額", isPresented: errorBinding) {
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

    private func save() {
        guard let targetBalance else { return }
        do {
            try AccountRepository().adjustBalance(of: account, to: targetBalance, note: note)
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum AccountHistoryItem: Identifiable {
    case entry(LedgerEntry)
    case adjustment(AccountAdjustment)

    var id: NSManagedObjectID {
        switch self {
        case .entry(let entry):
            return entry.objectID
        case .adjustment(let adjustment):
            return adjustment.objectID
        }
    }

    var date: Date {
        switch self {
        case .entry(let entry):
            return entry.date ?? entry.createdAt ?? .distantPast
        case .adjustment(let adjustment):
            return adjustment.createdAt ?? .distantPast
        }
    }
}

private struct AccountAdjustmentRow: View {
    @ObservedObject var adjustment: AccountAdjustment

    private var amount: Decimal {
        (adjustment.amount as Decimal?) ?? 0
    }

    private var title: String {
        guard let note = adjustment.note, !note.isEmpty else { return "餘額調整" }
        return note
    }

    var body: some View {
        LedgerCard {
            HStack(spacing: 14) {
                LedgerIconBadge(systemImage: "slider.horizontal.3", tint: .blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(adjustment.createdAt?.formatted(date: .abbreviated, time: .omitted) ?? "日期未設定")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(signedLedgerAmount(amount, currencyCode: adjustment.account?.group?.currencyCode))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(amount < 0 ? LedgerTheme.coral : LedgerTheme.primary)
            }
        }
    }
}

private struct AccountEntryRow: View {
    @ObservedObject var entry: LedgerEntry
    @ObservedObject var account: LedgerAccount

    private var kind: EntryKind {
        EntryKind(rawValue: entry.kind ?? "") ?? .expense
    }

    private var effect: Decimal {
        AccountBalanceCalculator.effect(
            of: AccountBalanceMovement(
                kind: kind,
                amount: (entry.amount as Decimal?) ?? 0,
                isSourceAccount: entry.sourceAccount == account,
                isDestinationAccount: entry.destinationAccount == account
            )
        )
    }

    private var title: String {
        if kind == .transfer {
            if entry.sourceAccount == account {
                return "轉至 \(entry.destinationAccount?.name ?? "其他帳戶")"
            }
            return "轉自 \(entry.sourceAccount?.name ?? "其他帳戶")"
        }
        if let note = entry.note, !note.isEmpty {
            return note
        }
        return entry.category?.name ?? kind.displayName
    }

    private var subtitle: String {
        let date = entry.date?.formatted(date: .abbreviated, time: .omitted) ?? "日期未設定"
        guard let bookName = entry.book?.name, !bookName.isEmpty else { return date }
        return "\(date) · \(bookName)"
    }

    var body: some View {
        LedgerCard {
            HStack(spacing: 14) {
                LedgerIconBadge(systemImage: kind.systemImage, tint: kind.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(signedLedgerAmount(effect, currencyCode: account.group?.currencyCode))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(effect < 0 ? LedgerTheme.coral : LedgerTheme.primary)
            }
        }
    }
}

private func ledgerAmount(_ amount: Decimal, currencyCode: String?) -> String {
    LedgerCurrency.format(
        amount,
        currencyCode: LedgerCurrency.normalizedCode(currencyCode)
    )
}

private func signedLedgerAmount(_ amount: Decimal, currencyCode: String?) -> String {
    LedgerCurrency.format(
        amount,
        currencyCode: LedgerCurrency.normalizedCode(currencyCode),
        showPositiveSign: true
    )
}
