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
            return (id, member.displayName ?? "未命名成員")
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
                            Label(
                                """
                                有 \(snapshot.skippedEntryCount) 筆交易的付款或分攤資料尚未同步完成，\
                                已暫時不列入結算。等 iCloud 同步完成後會自動重新計算。
                                """,
                                systemImage: "exclamationmark.arrow.triangle.2.circlepath"
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                    }

                    Section("成員淨額") {
                        if result.balances.isEmpty {
                            Text("目前沒有需要計算的共同收支。")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(result.balances, id: \.memberID) { balance in
                                balanceRow(balance)
                            }
                        }
                    }

                    Section("建議付款") {
                        if result.suggestedTransfers.isEmpty {
                            Label("目前已結清", systemImage: "checkmark.circle.fill")
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
                    }

                    if !canRecordSettlements {
                        Section {
                            Label(
                                settlementRestriction?.errorDescription
                                    ?? "目前只能查看結算，不能新增或撤銷。",
                                systemImage: "lock.fill"
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                    }

                    Section("結算歷史") {
                        if history.isEmpty {
                            Text("尚無結算紀錄。")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(history) { item in
                                historyRow(item)
                            }
                        }
                    }
                }
            } else if selectedGroup == nil {
                LedgerEmptyState(
                    systemImage: "person.3",
                    title: "先建立一個群組",
                    message: "建立群組與帳本後，就能查看成員淨額與結算建議。"
                )
                .padding(.horizontal, LedgerTheme.pagePadding)
            } else {
                LedgerEmptyState(
                    systemImage: "book.closed",
                    title: "找不到可用帳本",
                    message: "請先在群組設定建立或啟用帳本。"
                )
                .padding(.horizontal, LedgerTheme.pagePadding)
            }
        }
        .navigationTitle("結算")
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
            "確定要撤銷這筆結算？",
            isPresented: reverseConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("撤銷結算", role: .destructive, action: reverseSelectedSettlement)
            Button("取消", role: .cancel) {
                settlementToReverse = nil
            }
        } message: {
            Text("撤銷後會重新計入原本的應收與應付餘額，歷史紀錄本身仍會保留。")
        }
        .alert("無法處理結算", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "請稍後再試。")
        }
    }

    private func groupAndBookSelector(group: LedgerGroup, book: LedgerBook) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Menu {
                ForEach(Array(groups), id: \.objectID) { candidate in
                    Button {
                        selectedGroupID = candidate.objectID
                    } label: {
                        if candidate.objectID == group.objectID {
                            Label(candidate.name ?? "未命名群組", systemImage: "checkmark")
                        } else {
                            Text(candidate.name ?? "未命名群組")
                        }
                    }
                }
            } label: {
                selectorLabel(group.name ?? "未命名群組", systemImage: "person.3.fill")
            }

            Menu {
                ForEach(activeBooks, id: \.objectID) { candidate in
                    Button {
                        selectedBookID = candidate.objectID
                    } label: {
                        if candidate.objectID == book.objectID {
                            Label(candidate.name ?? "未命名帳本", systemImage: "checkmark")
                        } else {
                            Text(candidate.name ?? "未命名帳本")
                        }
                    }
                }
            } label: {
                selectorLabel(book.name ?? "未命名帳本", systemImage: "book.closed.fill")
            }
        }
    }

    private func selectorLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            Text(title)
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(LedgerTheme.primary)
    }

    private func balanceRow(_ balance: MemberBalance) -> some View {
        HStack {
            Text(memberNames[balance.memberID] ?? "未命名成員")
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(balance.amount > 0 ? "應收" : balance.amount < 0 ? "應付" : "已平衡")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(
                    LedgerCurrency.format(
                        balance.amount < 0 ? -balance.amount : balance.amount,
                        currencyCode: currencyCode
                    )
                )
                .font(.subheadline.weight(.semibold))
            }
        }
    }

    private func transferRow(_ transfer: SettlementTransfer) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.right.circle.fill")
                .foregroundStyle(LedgerTheme.primary)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(memberNames[transfer.fromMemberID] ?? "未命名成員") → \(memberNames[transfer.toMemberID] ?? "未命名成員")")
                    .font(.subheadline.weight(.semibold))
                Text(canRecordSettlements ? "點一下記錄全額或部分結算" : "僅供查看")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(LedgerCurrency.format(transfer.amount, currencyCode: currencyCode))
                .font(.subheadline.weight(.bold))
        }
    }

    private func historyRow(_ item: SettlementHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(memberNames[item.fromMemberID] ?? "未命名成員") → \(memberNames[item.toMemberID] ?? "未命名成員")")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(LedgerCurrency.format(item.amount, currencyCode: currencyCode))
                    .font(.subheadline.weight(.bold))
            }
            HStack {
                Text(item.recordedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if item.isReversed {
                    Label("已撤銷", systemImage: "arrow.uturn.backward.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !item.isReversed, canRecordSettlements {
                    Button("撤銷", role: .destructive) {
                        settlementToReverse = item
                    }
                    .font(.caption.weight(.semibold))
                }
            }
            if !item.note.isEmpty {
                Text(item.note)
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
            Section("付款") {
                detailRow("付款人", value: payer?.displayName ?? "未命名成員")
                detailRow("收款人", value: recipient?.displayName ?? "未命名成員")
                HStack {
                    Text("金額")
                    Spacer()
                    TextField("0", text: $amountText)
                        .keyboardType(LedgerCurrency.fractionDigits(for: currencyCode) == 0 ? .numberPad : .decimalPad)
                        .multilineTextAlignment(.trailing)
                    Text(currencyCode)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("備註") {
                TextField("例如：現金、轉帳、外部付款（選填）", text: $note, axis: .vertical)
                    .lineLimit(2...4)
            }

            Section {
                Text("建議上限：\(LedgerCurrency.format(transfer.amount, currencyCode: currencyCode))。可以只記錄部分金額，剩餘款項會保留在結算建議中。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("記錄結算")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("儲存", action: save)
                    .disabled(amount.map { $0 <= 0 || $0 > transfer.amount } ?? true)
            }
        }
        .alert("無法儲存結算", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "請稍後再試。")
        }
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func save() {
        guard let payer, let recipient, let amount else {
            errorMessage = "找不到結算成員或金額格式不正確。"
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
