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
    @State private var balanceRefreshTask: Task<Void, Never>?

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

    /// Creating and archiving accounts is a ledger settings change, so it follows
    /// the same effective permission the repository enforces on save.
    private var settingsRestriction: PermissionError? {
        EffectivePermissionRepository().ledgerSettingsRestriction(in: group)
    }

    private var presentNewAccount: (() -> Void)? {
        guard settingsRestriction == nil else { return nil }
        return { isPresentingNewAccount = true }
    }

    private func archiveAction(for account: LedgerAccount) -> (() -> Void)? {
        guard settingsRestriction == nil else { return nil }
        return { accountPendingArchive = account }
    }

    var body: some View {
        ZStack {
            LedgerBackground()
            ScrollView {
                LazyVStack(spacing: 16) {
                    if let message = settingsRestriction?.errorDescription {
                        LedgerNotice(message: message)
                    }

                    if accounts.isEmpty {
                        LedgerEmptyState(
                            systemImage: "creditcard",
                            title: .accountEmptyTitle,
                            message: settingsRestriction == nil
                                ? LedgerStringKey.accountEmptyMessageWritable
                                : LedgerStringKey.accountEmptyMessageReadOnly,
                            actionTitle: settingsRestriction == nil
                                ? LedgerStringKey.accountNewTitle
                                : nil,
                            action: presentNewAccount
                        )
                    } else if !activeAccounts.isEmpty {
                        LedgerCard(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(activeAccounts.enumerated()), id: \.element.objectID) { index, account in
                                    AccountRow(
                                        account: account,
                                        balance: accountBalances[account.objectID] ?? 0,
                                        onArchive: archiveAction(for: account)
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
                            LedgerSectionHeader(title: .accountSectionArchived)
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
        .navigationTitle(Text(.accountTitle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if settingsRestriction == nil {
                Button {
                    isPresentingNewAccount = true
                } label: {
                    Image(systemName: "plus")
                        .fontWeight(.bold)
                }
                .accessibilityLabel(Text(.accountNewTitle))
            }
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
            Text(.accountArchiveConfirmTitle),
            isPresented: archiveConfirmationBinding,
            titleVisibility: .visible,
            presenting: accountPendingArchive
        ) { account in
            Button(role: .destructive) {
                archive(account)
            } label: {
                Text(verbatim: LedgerStringKey.accountArchiveConfirmAction.string(
                    arguments: [account.name
                        ?? LedgerStringKey.commonPlaceholderUnnamedAccount.string()]
                ))
            }
            Button(role: .cancel) {} label: {
                Text(.commonActionCancel)
            }
        } message: { account in
            if accountRepository.hasHistory(account) {
                Text(.accountArchiveConfirmMessageWithHistory)
            } else {
                Text(.accountArchiveConfirmMessagePlain)
            }
        }
        .alert(Text(.accountErrorUpdateTitle), isPresented: errorBinding) {
            Button(role: .cancel) {} label: {
                Text(.commonActionOK)
            }
        } message: {
            Text(verbatim: errorMessage ?? LedgerStringKey.commonErrorRetryLater.string())
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
        .onDisappear {
            balanceRefreshTask?.cancel()
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
        let accountSnapshot = Array(accounts)
        balanceRefreshTask?.cancel()
        balanceRefreshTask = Task {
            let refreshedBalances = await accountRepository.balances(for: accountSnapshot)
            guard !Task.isCancelled else { return }
            accountBalances = refreshedBalances
        }
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

    private var subtitle: String {
        guard account.archivedAt != nil else { return type.displayName }
        return LedgerStringKey.accountRowSubtitleArchived.string(arguments: [type.displayName])
    }

    var body: some View {
        HStack(spacing: 4) {
            NavigationLink {
                AccountDetailView(account: account)
            } label: {
                HStack(spacing: 14) {
                    LedgerIconBadge(systemImage: type.systemImage)
                    LedgerAdaptiveStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: account.name
                                ?? LedgerStringKey.commonPlaceholderUnnamedAccount.string())
                                .font(.subheadline.weight(.semibold))
                            Text(verbatim: subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        HStack(spacing: 6) {
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(verbatim: ledgerAmount(
                                    balance,
                                    currencyCode: account.group?.currencyCode
                                ))
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(balance < 0 ? LedgerTheme.coral : .primary)
                                Text(.accountDetailBalanceCurrent)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 名稱、類型與餘額是同一列的一句話。
            .accessibilityElement(children: .combine)

            if let onArchive {
                Menu {
                    Button(role: .destructive, action: onArchive) {
                        Label(.accountActionArchive, systemImage: "archivebox")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .ledgerTapTarget()
                }
                .accessibilityLabel(Text(.accountMenuAccessibilityLabel))
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

    /// 餘額是這個畫面的主角，字級要跟著使用者走；`.system(size:)` 本身不會。
    @ScaledMetric(relativeTo: .largeTitle) private var balanceFontSize: CGFloat = 38

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

    /// Balance adjustment and reconciliation post ledger entries, so they follow the
    /// transaction permission; archiving is a settings change.
    private var transactionRestriction: PermissionError? {
        guard let group = account.group else { return .missingCurrentMember }
        return EffectivePermissionRepository().transactionWriteRestriction(in: group)
    }

    private var settingsRestriction: PermissionError? {
        guard let group = account.group else { return .missingCurrentMember }
        return EffectivePermissionRepository().ledgerSettingsRestriction(in: group)
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
        .navigationTitle(Text(verbatim: account.name
            ?? LedgerStringKey.accountDetailTitleFallback.string()))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if account.archivedAt == nil,
               transactionRestriction == nil || settingsRestriction == nil {
                Menu {
                    if transactionRestriction == nil {
                        Button {
                            isAdjustingBalance = true
                        } label: {
                            Label(.accountActionAdjustBalance, systemImage: "slider.horizontal.3")
                        }
                        Button {
                            isConfirmingReconciliation = true
                        } label: {
                            Label(.accountActionReconcile, systemImage: "checkmark.seal")
                        }
                    }
                    if settingsRestriction == nil {
                        if transactionRestriction == nil { Divider() }
                        Button(role: .destructive) {
                            isConfirmingArchive = true
                        } label: {
                            Label(.accountActionArchive, systemImage: "archivebox")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(Text(.accountDetailMenuAccessibilityLabel))
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
            Text(.accountReconcileConfirmTitle),
            isPresented: $isConfirmingReconciliation,
            titleVisibility: .visible
        ) {
            Button { reconcile() } label: {
                Text(.accountReconcileConfirmAction)
            }
            Button(role: .cancel) {} label: {
                Text(.commonActionCancel)
            }
        } message: {
            Text(verbatim: LedgerStringKey.accountReconcileConfirmMessage.string(
                arguments: [ledgerAmount(
                    currentBalance,
                    currencyCode: account.group?.currencyCode
                )]
            ))
        }
        .confirmationDialog(
            Text(.accountArchiveConfirmTitle),
            isPresented: $isConfirmingArchive,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) { archive() } label: {
                Text(.accountActionArchive)
            }
            Button(role: .cancel) {} label: {
                Text(.commonActionCancel)
            }
        } message: {
            Text(historyItems.isEmpty
                 ? LedgerStringKey.accountArchiveConfirmMessagePlain
                 : LedgerStringKey.accountArchiveConfirmMessageKeepsHistory)
        }
        .alert(Text(.accountErrorUpdateTitle), isPresented: errorBinding) {
            Button(role: .cancel) {} label: {
                Text(.commonActionOK)
            }
        } message: {
            Text(verbatim: errorMessage ?? LedgerStringKey.commonErrorRetryLater.string())
        }
    }

    private func balanceCard(_ currentBalance: Decimal) -> some View {
        LedgerCard {
            VStack(alignment: .leading, spacing: 16) {
                Label(.accountDetailBalanceCurrent, systemImage: "creditcard.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(verbatim: ledgerAmount(
                    currentBalance,
                    currencyCode: account.group?.currencyCode
                ))
                .font(.system(size: balanceFontSize, weight: .bold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(currentBalance < 0 ? LedgerTheme.coral : LedgerTheme.primaryStrong)
                .contentTransition(.numericText())
                .accessibilityLabel(Text(.accountDetailBalanceCurrent))
                .accessibilityValue(Text(verbatim: ledgerAmount(
                    currentBalance,
                    currencyCode: account.group?.currencyCode
                )))
                LedgerAdaptiveStack(verticalSpacing: 2) {
                    Text(.accountDetailBalanceOpening)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: ledgerAmount(
                        (account.openingBalance as Decimal?) ?? 0,
                        currencyCode: account.group?.currencyCode
                    ))
                    .fontWeight(.semibold)
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var reconciliationCard: some View {
        LedgerCard {
            VStack(alignment: .leading, spacing: 10) {
                LedgerSectionHeader(title: .accountDetailSectionReconciliation)
                if let date = account.lastReconciledAt,
                   let balance = account.lastReconciledBalance as Decimal? {
                    HStack {
                        Text(verbatim: LedgerFormatters.timestamp(date))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(verbatim: ledgerAmount(
                            balance,
                            currencyCode: account.group?.currencyCode
                        ))
                        .fontWeight(.semibold)
                    }
                    .font(.subheadline)
                    .accessibilityElement(children: .combine)
                } else {
                    Text(.accountDetailReconciliationEmpty)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var transactionHistory: some View {
        VStack(alignment: .leading, spacing: 12) {
            LedgerSectionHeader(title: .accountDetailSectionHistory)
            if historyItems.isEmpty {
                LedgerEmptyState(
                    systemImage: "list.bullet.rectangle",
                    title: .accountDetailHistoryEmptyTitle,
                    message: .accountDetailHistoryEmptyMessage
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
                    Text(verbatim: currencyCode)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("", text: $targetBalanceText, prompt: Text(verbatim: "0"))
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel(Text(.accountAdjustmentSectionBalance))
                }
            } header: {
                Text(.accountAdjustmentSectionBalance)
            } footer: {
                Text(.accountAdjustmentSectionBalanceFooter)
            }

            Section {
                TextField("", text: $note, prompt: Text(.accountAdjustmentNotePlaceholder))
                    .accessibilityLabel(Text(.accountAdjustmentSectionNote))
            } header: {
                Text(.accountAdjustmentSectionNote)
            }
        }
        .navigationTitle(Text(.accountAdjustmentTitle))
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
                .disabled(targetBalance == nil)
            }
        }
        .alert(Text(.accountAdjustmentErrorTitle), isPresented: errorBinding) {
            Button(role: .cancel) {} label: {
                Text(.commonActionOK)
            }
        } message: {
            Text(verbatim: errorMessage ?? LedgerStringKey.commonErrorRetryLater.string())
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
        guard let note = adjustment.note, !note.isEmpty else {
            return LedgerStringKey.accountEntryAdjustmentTitle.string()
        }
        return note
    }

    private var dateText: String {
        adjustment.createdAt.map { LedgerFormatters.day($0) }
            ?? LedgerStringKey.commonPlaceholderNoDate.string()
    }

    var body: some View {
        LedgerCard {
            HStack(spacing: 14) {
                LedgerIconBadge(systemImage: "slider.horizontal.3", tint: .blue)
                LedgerAdaptiveStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: title)
                            .font(.subheadline.weight(.semibold))
                        Text(verbatim: dateText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: signedLedgerAmount(
                        amount,
                        currencyCode: adjustment.account?.group?.currencyCode
                    ))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(amount < 0 ? LedgerTheme.coral : LedgerTheme.primary)
                }
            }
        }
        .accessibilityElement(children: .combine)
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
            let other = LedgerStringKey.accountEntryTransferOther.string()
            if entry.sourceAccount == account {
                return LedgerStringKey.accountEntryTransferTo.string(
                    arguments: [entry.destinationAccount?.name ?? other]
                )
            }
            return LedgerStringKey.accountEntryTransferFrom.string(
                arguments: [entry.sourceAccount?.name ?? other]
            )
        }
        if let note = entry.note, !note.isEmpty {
            return note
        }
        return entry.category?.name ?? kind.displayName
    }

    private var subtitle: String {
        let date = entry.date.map { LedgerFormatters.day($0) }
            ?? LedgerStringKey.commonPlaceholderNoDate.string()
        guard let bookName = entry.book?.name, !bookName.isEmpty else { return date }
        return LedgerStringKey.accountEntrySubtitle.string(arguments: [date, bookName])
    }

    var body: some View {
        LedgerCard {
            HStack(spacing: 14) {
                LedgerIconBadge(systemImage: kind.systemImage, tint: kind.tint)
                LedgerAdaptiveStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: title)
                            .font(.subheadline.weight(.semibold))
                        Text(verbatim: subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: signedLedgerAmount(
                        effect,
                        currencyCode: account.group?.currencyCode
                    ))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(effect < 0 ? LedgerTheme.coral : LedgerTheme.primary)
                }
            }
        }
        .accessibilityElement(children: .combine)
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
