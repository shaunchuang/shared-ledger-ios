import CoreData
import SwiftUI

struct SettlementRootView: View {
    @Environment(\.managedObjectContext) private var context

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \LedgerGroup.updatedAt, ascending: false)],
        animation: .default
    ) private var groups: FetchedResults<LedgerGroup>

    @State private var selectedGroupID: NSManagedObjectID?
    @State private var selectedBookID: NSManagedObjectID?
    @State private var snapshot = SettlementSnapshot.empty
    @State private var history: [SettlementHistoryItem] = []
    @State private var selectedTransfer: SettlementTransfer?
    @State private var settlementToReverse: SettlementHistoryItem?
    @State private var errorMessage: String?

    private var selectedGroup: LedgerGroup? {
        if let selectedGroupID,
           let match = groups.first(where: { $0.objectID == selectedGroupID }) {
            return match
        }
        return groups.first
    }

    private var activeBooks: [LedgerBook] {
        guard let selectedGroup else { return [] }
        return BookRepository().books(in: selectedGroup)
    }

    private var selectedBook: LedgerBook? {
        if let selectedBookID,
           let match = activeBooks.first(where: { $0.objectID == selectedBookID }) {
            return match
        }
        return activeBooks.first(where: \.isDefault) ?? activeBooks.first
    }

    private var result: SettlementResult { snapshot.result }

    private var currencyCode: String {
        LedgerCurrency.normalizedCode(selectedGroup?.currencyCode)
    }

    private var settlementRestriction: PermissionError? {
        guard let group = selectedBook?.group else { return .missingCurrentMember }
        return EffectivePermissionRepository().transactionWriteRestriction(in: group)
    }

    private var canRecordSettlements: Bool {
        selectedBook.map { SettlementRepository().canRecordSettlements(in: $0) } ?? false
    }

    private var memberNames: [UUID: String] {
        guard let selectedGroup else { return [:] }
        let members = selectedGroup.members as? Set<Member> ?? []
        return Dictionary(uniqueKeysWithValues: members.compactMap { member in
            guard let id = member.id else { return nil }
            return (id, member.displayName
                ?? LedgerStringKey.commonPlaceholderUnnamedMember.string())
        })
    }

    var body: some View {
        Group {
            if let selectedGroup, let selectedBook {
                List {
                    Section {
                        groupAndBookSelector(group: selectedGroup, book: selectedBook)
                    }

                    if snapshot.hasSkippedEntries {
                        Section {
                            Label {
                                Text(verbatim: LedgerStringKey.settlementSkippedNotice.string(
                                    arguments: [Int64(snapshot.skippedEntryCount)]
                                ))
                            } icon: {
                                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                    }

                    Section {
                        if result.balances.isEmpty {
                            Text(.settlementBalancesEmpty)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(result.balances, id: \.memberID) { balance in
                                balanceRow(balance)
                            }
                        }
                    } header: {
                        Text(.settlementSectionBalances)
                    }

                    Section {
                        if result.suggestedTransfers.isEmpty {
                            Label(.settlementSuggestionsSettled, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(LedgerTheme.primary)
                        } else {
                            ForEach(Array(result.suggestedTransfers.enumerated()), id: \.offset) { _, transfer in
                                Button {
                                    selectedTransfer = transfer
                                } label: {
                                    transferRow(transfer)
                                }
                                .buttonStyle(.plain)
                                .disabled(!canRecordSettlements)
                            }
                        }
                    } header: {
                        Text(.settlementSectionSuggestions)
                    }

                    if !canRecordSettlements {
                        Section {
                            Label {
                                // 權限說明來自資料層的 `PermissionError`，那一層還沒遷移。
                                Text(verbatim: settlementRestriction?.errorDescription
                                    ?? LedgerStringKey.settlementReadOnlyFallback.string())
                            } icon: {
                                Image(systemName: "lock.fill")
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                    }

                    Section {
                        if history.isEmpty {
                            Text(.settlementHistoryEmpty)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(history) { item in
                                historyRow(item)
                            }
                        }
                    } header: {
                        Text(.settlementSectionHistory)
                    }
                }
            } else if selectedGroup == nil {
                LedgerEmptyState(
                    systemImage: "person.3",
                    title: .settlementEmptyNoGroupTitle,
                    message: .settlementEmptyNoGroupMessage
                )
                .padding(.horizontal, LedgerTheme.pagePadding)
            } else {
                LedgerEmptyState(
                    systemImage: "book.closed",
                    title: .settlementEmptyNoBookTitle,
                    message: .settlementEmptyNoBookMessage
                )
                .padding(.horizontal, LedgerTheme.pagePadding)
            }
        }
        .navigationTitle(Text(.settlementTitle))
        .onAppear {
            normalizeSelection()
            reload()
        }
        .onChange(of: groups.count) { _, _ in
            normalizeSelection()
            reload()
        }
        .onChange(of: selectedGroupID) { _, _ in
            selectedBookID = nil
            normalizeSelection()
            reload()
        }
        .onChange(of: selectedBookID) { _, _ in
            reload()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .NSManagedObjectContextObjectsDidChange,
                object: context
            )
        ) { notification in
            // A TabView keeps this view alive while other tabs are on screen, so an
            // unfiltered subscription reruns the settlement solver for writes it does
            // not depend on — editing an account or a category, for example.
            guard affectsSettlement(notification) else { return }
            reload()
        }
        .sheet(isPresented: transferSheetBinding) {
            if let selectedBook, let selectedTransfer {
                NavigationStack {
                    SettlementRecordSheet(book: selectedBook, transfer: selectedTransfer) {
                        self.selectedTransfer = nil
                        reload()
                    }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .confirmationDialog(
            Text(.settlementReverseConfirmTitle),
            isPresented: reverseConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button(role: .destructive, action: reverseSelectedSettlement) {
                Text(.settlementReverseConfirmAction)
            }
            Button(role: .cancel) {
                settlementToReverse = nil
            } label: {
                Text(.commonActionCancel)
            }
        } message: {
            Text(.settlementReverseConfirmMessage)
        }
        .alert(Text(.settlementErrorTitle), isPresented: errorBinding) {
            Button(role: .cancel) {} label: {
                Text(.commonActionOK)
            }
        } message: {
            Text(verbatim: errorMessage ?? LedgerStringKey.commonErrorRetryLater.string())
        }
    }

    private func groupAndBookSelector(group: LedgerGroup, book: LedgerBook) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Menu {
                ForEach(Array(groups), id: \.objectID) { candidate in
                    Button {
                        selectedGroupID = candidate.objectID
                    } label: {
                        let name = candidate.name
                            ?? LedgerStringKey.commonPlaceholderUnnamedGroup.string()
                        if candidate.objectID == group.objectID {
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
                selectorLabel(
                    group.name ?? LedgerStringKey.commonPlaceholderUnnamedGroup.string(),
                    systemImage: "person.3.fill"
                )
            }
            .accessibilityLabel(Text(.transactionGroupPickerAccessibilityLabel))
            .accessibilityValue(Text(verbatim: group.name
                ?? LedgerStringKey.commonPlaceholderUnnamedGroup.string()))

            Menu {
                ForEach(activeBooks, id: \.objectID) { candidate in
                    Button {
                        selectedBookID = candidate.objectID
                    } label: {
                        let name = candidate.name
                            ?? LedgerStringKey.commonPlaceholderUnnamedBook.string()
                        if candidate.objectID == book.objectID {
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
                selectorLabel(
                    book.name ?? LedgerStringKey.commonPlaceholderUnnamedBook.string(),
                    systemImage: "book.closed.fill"
                )
            }
            .accessibilityLabel(Text(.transactionBookPickerAccessibilityLabel))
            .accessibilityValue(Text(verbatim: book.name
                ?? LedgerStringKey.commonPlaceholderUnnamedBook.string()))
        }
    }

    private func selectorLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .accessibilityHidden(true)
            Text(verbatim: title)
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.bold))
                .accessibilityHidden(true)
        }
        .foregroundStyle(LedgerTheme.primary)
    }

    private func balanceRow(_ balance: MemberBalance) -> some View {
        LedgerAdaptiveStack(verticalSpacing: 4) {
            Text(verbatim: memberName(balance.memberID))
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                Text(directionKey(for: balance.amount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(verbatim: LedgerCurrency.format(
                    balance.amount < 0 ? -balance.amount : balance.amount,
                    currencyCode: currencyCode
                ))
                .font(.subheadline.weight(.semibold))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func memberName(_ id: UUID) -> String {
        memberNames[id] ?? LedgerStringKey.commonPlaceholderUnnamedMember.string()
    }

    private func directionKey(for amount: Decimal) -> LedgerStringKey {
        if amount > 0 { return .settlementBalanceOwed }
        if amount < 0 { return .settlementBalanceOwes }
        return .settlementBalanceBalanced
    }

    private func route(from: UUID, to: UUID) -> String {
        LedgerStringKey.settlementTransferRoute.string(
            arguments: [memberName(from), memberName(to)]
        )
    }

    private func transferRow(_ transfer: SettlementTransfer) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.right.circle.fill")
                .foregroundStyle(LedgerTheme.primary)
                .accessibilityHidden(true)
            LedgerAdaptiveStack(verticalSpacing: 4) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: route(from: transfer.fromMemberID, to: transfer.toMemberID))
                        .font(.subheadline.weight(.semibold))
                    Text(canRecordSettlements
                         ? LedgerStringKey.settlementTransferHintTappable
                         : LedgerStringKey.settlementTransferHintReadOnly)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: LedgerCurrency.format(transfer.amount, currencyCode: currencyCode))
                    .font(.subheadline.weight(.bold))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func historyRow(_ item: SettlementHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LedgerAdaptiveStack(verticalSpacing: 2) {
                Text(verbatim: route(from: item.fromMemberID, to: item.toMemberID))
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: LedgerCurrency.format(item.amount, currencyCode: currencyCode))
                    .font(.subheadline.weight(.bold))
            }
            .accessibilityElement(children: .combine)
            HStack {
                Text(verbatim: LedgerFormatters.timestamp(item.recordedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if item.isReversed {
                    Label(.settlementHistoryBadgeReversed, systemImage: "arrow.uturn.backward.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !item.isReversed, canRecordSettlements {
                    Button(role: .destructive) {
                        settlementToReverse = item
                    } label: {
                        Text(.settlementActionReverse)
                    }
                    .font(.caption.weight(.semibold))
                }
            }
            if !item.note.isEmpty {
                // 備註是使用者輸入的內容。
                Text(verbatim: item.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var transferSheetBinding: Binding<Bool> {
        Binding(
            get: { selectedTransfer != nil },
            set: { if !$0 { selectedTransfer = nil } }
        )
    }

    private var reverseConfirmationBinding: Binding<Bool> {
        Binding(
            get: { settlementToReverse != nil },
            set: { if !$0 { settlementToReverse = nil } }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func normalizeSelection() {
        if selectedGroup == nil {
            selectedGroupID = groups.first?.objectID
        }
        guard let fallback = activeBooks.first(where: \.isDefault) ?? activeBooks.first else {
            selectedBookID = nil
            return
        }
        if selectedBook == nil {
            selectedBookID = fallback.objectID
        } else if selectedBookID == nil {
            selectedBookID = fallback.objectID
        }
    }

    /// Whether a context change touches anything `reload()` reads.
    ///
    /// `SettlementRepository.snapshot(in:)` walks the book's entries with their
    /// payments and splits, resolves the members those rows point at, reads the
    /// group's currency, and derives voided transactions and settlement history from
    /// the group's audit events. `activeBooks` also depends on the group's books, and
    /// the permission notices resolve the current member through its private
    /// `LocalMemberIdentity`. Anything outside that set — accounts, categories,
    /// balance adjustments — cannot change what this screen shows, so it must not
    /// trigger a recompute.
    ///
    /// Only the object's type is inspected, never its properties, so invalidated
    /// objects are safe to test here.
    private func affectsSettlement(_ notification: Notification) -> Bool {
        // A context reset reports `NSInvalidatedAllObjectsKey` instead of listing the
        // objects, so there is nothing to match against and it has to count as a hit.
        if notification.userInfo?[NSInvalidatedAllObjectsKey] != nil { return true }

        let changeKeys = [
            NSInsertedObjectsKey,
            NSUpdatedObjectsKey,
            NSDeletedObjectsKey,
            NSRefreshedObjectsKey,
            NSInvalidatedObjectsKey
        ]
        return changeKeys.contains { key in
            guard let objects = notification.userInfo?[key] as? Set<NSManagedObject> else {
                return false
            }
            return objects.contains { object in
                object is LedgerEntry
                    || object is EntryPayment
                    || object is EntrySplit
                    || object is Member
                    || object is AuditEvent
                    || object is LedgerGroup
                    || object is LedgerBook
                    || object is LocalMemberIdentity
            }
        }
    }

    private func reload() {
        guard let selectedBook else {
            snapshot = .empty
            history = []
            return
        }
        do {
            let repository = SettlementRepository()
            snapshot = try repository.snapshot(in: selectedBook)
            history = repository.history(in: selectedBook)
        } catch {
            snapshot = .empty
            history = []
            errorMessage = error.localizedDescription
        }
    }

    private func reverseSelectedSettlement() {
        guard let selectedBook, let settlementToReverse else { return }
        do {
            try SettlementRepository().reverseSettlement(settlementToReverse, in: selectedBook)
            self.settlementToReverse = nil
            reload()
        } catch {
            self.settlementToReverse = nil
            errorMessage = error.localizedDescription
        }
    }
}

private struct SettlementRecordSheet: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var book: LedgerBook
    let transfer: SettlementTransfer
    let onSaved: () -> Void

    @State private var amountText: String
    @State private var note = ""
    @State private var errorMessage: String?

    init(book: LedgerBook, transfer: SettlementTransfer, onSaved: @escaping () -> Void) {
        self.book = book
        self.transfer = transfer
        self.onSaved = onSaved
        _amountText = State(initialValue: NSDecimalNumber(decimal: transfer.amount).stringValue)
    }

    private var currencyCode: String {
        LedgerCurrency.normalizedCode(book.group?.currencyCode)
    }

    private var amount: Decimal? {
        Decimal(string: amountText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var membersByID: [UUID: Member] {
        let members = book.group?.members as? Set<Member> ?? []
        return Dictionary(uniqueKeysWithValues: members.compactMap { member in
            guard let id = member.id else { return nil }
            return (id, member)
        })
    }

    private var payer: Member? { membersByID[transfer.fromMemberID] }
    private var recipient: Member? { membersByID[transfer.toMemberID] }

    var body: some View {
        Form {
            Section {
                detailRow(.settlementRecordPayer, value: memberName(payer))
                detailRow(.settlementRecordRecipient, value: memberName(recipient))
                HStack {
                    Text(.settlementRecordAmount)
                    Spacer()
                    TextField("", text: $amountText, prompt: Text(verbatim: "0"))
                        .keyboardType(
                            LedgerCurrency.fractionDigits(for: currencyCode) == 0
                                ? .numberPad
                                : .decimalPad
                        )
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel(Text(.settlementRecordAmount))
                    Text(verbatim: currencyCode)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            } header: {
                Text(.settlementRecordSectionPayment)
            }

            Section {
                TextField(
                    "",
                    text: $note,
                    prompt: Text(.settlementRecordNotePlaceholder),
                    axis: .vertical
                )
                .lineLimit(2...4)
                .accessibilityLabel(Text(.settlementRecordSectionNote))
            } header: {
                Text(.settlementRecordSectionNote)
            }

            Section {
                Text(verbatim: LedgerStringKey.settlementRecordLimit.string(
                    arguments: [LedgerCurrency.format(transfer.amount, currencyCode: currencyCode)]
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(Text(.settlementRecordTitle))
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
                .disabled(amount.map { $0 <= 0 || $0 > transfer.amount } ?? true)
            }
        }
        .alert(Text(.settlementRecordErrorTitle), isPresented: errorBinding) {
            Button(role: .cancel) {} label: {
                Text(.commonActionOK)
            }
        } message: {
            Text(verbatim: errorMessage ?? LedgerStringKey.commonErrorRetryLater.string())
        }
    }

    private func memberName(_ member: Member?) -> String {
        member?.displayName ?? LedgerStringKey.commonPlaceholderUnnamedMember.string()
    }

    private func detailRow(_ title: LedgerStringKey, value: String) -> some View {
        LedgerAdaptiveStack(verticalSpacing: 2) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: value)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func save() {
        guard let payer, let recipient, let amount else {
            errorMessage = LedgerStringKey.settlementRecordErrorMissingMember.string()
            return
        }
        do {
            try SettlementRepository().recordSettlement(
                from: payer,
                to: recipient,
                amount: amount,
                note: note,
                in: book
            )
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    let persistence = PersistenceController(inMemory: true)
    NavigationStack { SettlementRootView() }
        .environment(\.managedObjectContext, persistence.container.viewContext)
}
