import CoreData
import SwiftUI
import UIKit

struct NewTransactionView: View {
    private enum Field: Hashable {
        case amount, note
        case payment(NSManagedObjectID)
        case split(NSManagedObjectID)
    }

    @Environment(\.dismiss) private var dismiss

    let book: LedgerBook
    let entry: LedgerEntry?
    let focusesAmount: Bool
    let onSaved: () -> Void

    @FetchRequest private var accounts: FetchedResults<LedgerAccount>
    @FetchRequest private var categories: FetchedResults<LedgerCategory>

    @State private var draft: TransactionDraft
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?
    @State private var didPrefill = false
    @State private var isSelectingCategory = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        book: LedgerBook,
        entry: LedgerEntry? = nil,
        initialKind: EntryKind = .expense,
        focusesAmount: Bool = false,
        onSaved: @escaping () -> Void
    ) {
        self.book = book
        self.entry = entry
        self.focusesAmount = focusesAmount
        self.onSaved = onSaved
        _draft = State(initialValue: entry.map(TransactionDraft.init(entry:)) ?? TransactionDraft(kind: initialKind))

        let accountPredicate: NSPredicate
        if let group = book.group {
            let existingAccountIDs = [entry?.sourceAccount?.id, entry?.destinationAccount?.id].compactMap { $0 }
            if existingAccountIDs.isEmpty {
                accountPredicate = NSPredicate(format: "group == %@ AND archivedAt == nil", group)
            } else {
                accountPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "group == %@", group),
                    NSCompoundPredicate(orPredicateWithSubpredicates: [
                        NSPredicate(format: "archivedAt == nil"),
                        NSPredicate(format: "id IN %@", existingAccountIDs)
                    ])
                ])
            }
        } else {
            accountPredicate = NSPredicate(value: false)
        }
        _accounts = FetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \LedgerAccount.createdAt, ascending: true)],
            predicate: accountPredicate
        )

        let categoryPredicate: NSPredicate
        if let group = book.group {
            if let categoryID = entry?.category?.id {
                categoryPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "group == %@", group),
                    NSCompoundPredicate(orPredicateWithSubpredicates: [
                        NSPredicate(format: "archivedAt == nil"),
                        NSPredicate(format: "id == %@", categoryID as CVarArg)
                    ])
                ])
            } else {
                categoryPredicate = NSPredicate(format: "group == %@ AND archivedAt == nil", group)
            }
        } else {
            categoryPredicate = NSPredicate(value: false)
        }
        _categories = FetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \LedgerCategory.sortOrder, ascending: true)],
            predicate: categoryPredicate
        )
    }

    private var members: [Member] {
        let set = book.group?.members as? Set<Member> ?? []
        let historicalIDs = Set(
            (entry?.liveSplits ?? []).compactMap { $0.member?.id }
                + (entry?.livePayments ?? []).compactMap { $0.member?.id }
        )
        return set
            .filter { member in
                member.archivedAt == nil || member.id.map(historicalIDs.contains) == true
            }
            .sorted { ($0.displayName ?? "") < ($1.displayName ?? "") }
    }

    private var currencyCode: String {
        LedgerCurrency.normalizedCode(book.group?.currencyCode)
    }

    /// 順序由帳本的分類設定決定；FetchRequest 只負責在分類變動時重畫。
    private var availableCategories: [LedgerCategory] {
        let fetchedIDs = Set(categories.map(\.objectID))
        var result = CategoryRepository()
            .availableCategories(in: book)
            .filter { fetchedIDs.contains($0.objectID) }
        if let current = entry?.category,
           !result.contains(where: { $0.objectID == current.objectID }) {
            result.append(current)
        }
        return result
    }

    var body: some View {
        Form {
            if accounts.isEmpty, let group = book.group {
                Section {
                    NavigationLink {
                        AccountsView(group: group)
                    } label: {
                        Label(.accountTitle, systemImage: "wallet.pass")
                    }
                } footer: {
                    Text(.transactionFormAccountsEmpty)
                }
            }
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: book.name ?? LedgerStringKey.commonPlaceholderUnnamedBook.string())
                            .font(.headline)
                        Text(verbatim: book.group?.name ?? LedgerStringKey.commonPlaceholderUnnamedGroup.string())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "book.closed.fill")
                        .foregroundStyle(LedgerTheme.primary)
                }
                .accessibilityElement(children: .combine)
            } header: {
                Text(.transactionDetailFieldBook)
            }
            Section {
                if dynamicTypeSize.isAccessibilitySize {
                    kindPicker.pickerStyle(.menu)
                } else {
                    kindPicker.pickerStyle(.segmented)
                }
            }
            .listRowBackground(Color.clear)

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(.transactionFormFieldAmount)
                            .font(.subheadline)
                        Spacer()
                        Text(verbatim: currencyCode)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    TextField("", text: $draft.amountText, prompt: Text(verbatim: "0"))
                        .font(.largeTitle.weight(.bold).monospacedDigit())
                        .keyboardType(amountKeyboardType)
                        .focused($focusedField, equals: .amount)
                        .accessibilityLabel(Text(.transactionFormFieldAmount))
                        .accessibilityIdentifier("transaction.amount")
                }
                .padding(.vertical, 8)
                DatePicker(selection: $draft.date, displayedComponents: .date) {
                    Text(.transactionFormFieldDate)
                }
            }

            if draft.kind == .transfer {
                Section {
                    if accounts.isEmpty {
                        Text(.transactionFormTransferAccountsEmpty)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(selection: $draft.sourceAccountID) {
                            accountOptions
                        } label: {
                            Text(.transactionFormFieldSourceAccount)
                        }
                        Picker(selection: $draft.destinationAccountID) {
                            accountOptions
                        } label: {
                            Text(.transactionFormFieldDestinationAccount)
                        }
                    }
                } header: {
                    Text(.transactionFormSectionTransferAccounts)
                }
            } else {
                Section {
                    if accounts.isEmpty {
                        Text(.transactionFormAccountsEmpty)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(selection: $draft.sourceAccountID) {
                            accountOptions
                        } label: {
                            Text(.transactionFormFieldAccount)
                        }
                    }
                    Button {
                        focusedField = nil
                        isSelectingCategory = true
                    } label: {
                        LedgerAdaptiveStack {
                            Text(.transactionFormFieldCategory)
                                .foregroundStyle(.primary)
                            HStack {
                                Text(verbatim: selectedCategoryLabel)
                                    .fixedSize(horizontal: false, vertical: true)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .accessibilityHidden(true)
                            }
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("transaction.category")
                } header: {
                    Text(.transactionFormSectionAccountAndCategory)
                }

                Section {
                    ForEach(members, id: \.objectID) { member in
                        HStack(spacing: 12) {
                            Button {
                                togglePayment(member)
                            } label: {
                                HStack(spacing: 10) {
                                    paymentSelectionIcon(for: member)
                                    Text(verbatim: memberName(member))
                                        .foregroundStyle(.primary)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(verbatim: memberName(member)))
                            .accessibilityAddTraits(
                                isPayingMember(member) ? [.isButton, .isSelected] : .isButton
                            )
                            .accessibilityHint(Text(.transactionFormPaymentToggleAccessibilityHint))

                            Spacer()

                            if isPayingMember(member) {
                                TextField(
                                    "",
                                    text: paymentAmountBinding(for: member),
                                    prompt: Text(verbatim: "0")
                                )
                                .focused($focusedField, equals: .payment(member.objectID))
                                .keyboardType(amountKeyboardType)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 120)
                                .accessibilityLabel(Text(verbatim: paymentFieldLabel(for: member)))
                                Text(verbatim: currencyCode)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                } header: {
                    Text(.transactionFormSectionPayers)
                } footer: {
                    Text(verbatim: paymentSummary)
                }

                Section {
                    Picker(selection: $draft.splitMode) {
                        ForEach(SplitMode.allCases, id: \.self) { mode in
                            Text(mode.displayNameKey).tag(mode)
                        }
                    } label: {
                        Text(.transactionFormFieldSplitMode)
                    }

                    ForEach(members, id: \.objectID) { member in
                        HStack(spacing: 12) {
                            Button {
                                toggleSplit(member)
                            } label: {
                                HStack(spacing: 10) {
                                    splitSelectionIcon(for: member)
                                    Text(verbatim: memberName(member))
                                        .foregroundStyle(.primary)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(verbatim: memberName(member)))
                            .accessibilityAddTraits(
                                isSplitMember(member) ? [.isButton, .isSelected] : .isButton
                            )
                            .accessibilityHint(Text(.transactionFormSplitToggleAccessibilityHint))

                            Spacer()

                            if isSplitMember(member), draft.splitMode != .equal {
                                TextField(
                                    "",
                                    text: splitValueBinding(for: member),
                                    prompt: Text(verbatim: "0")
                                )
                                .focused($focusedField, equals: .split(member.objectID))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 120)
                                .accessibilityLabel(Text(verbatim: splitFieldLabel(for: member)))
                                Text(verbatim: draft.splitMode == .percentage ? "%" : currencyCode)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                } header: {
                    Text(.transactionFormSectionSplits)
                } footer: {
                    Text(verbatim: splitSummary)
                }
            }

            Section {
                TextField(
                    "",
                    text: $draft.note,
                    prompt: Text(.transactionFormNotePlaceholder),
                    axis: .vertical
                )
                .focused($focusedField, equals: .note)
                .lineLimit(2...4)
                .accessibilityLabel(Text(.transactionFormSectionNote))
            } header: {
                Text(.transactionFormSectionNote)
            }
        }
        .navigationTitle(Text(
            entry == nil
                ? LedgerStringKey.transactionFormTitleNew
                : LedgerStringKey.transactionFormTitleEdit
        ))
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button { focusedField = nil } label: { Text(.commonActionDone) }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: {
                    Text(.commonActionCancel)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: save) {
                    Text(.commonActionSave)
                }
                .disabled(!draft.canSave)
            }
        }
        .onAppear {
            if entry == nil, !didPrefill {
                prefillDefaults()
                didPrefill = true
            }
        }
        .task {
            guard entry == nil, focusesAmount, !accounts.isEmpty else { return }
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            focusedField = .amount
        }
        .sheet(isPresented: $isSelectingCategory) {
            NavigationStack {
                TransactionCategorySelectionView(categories: availableCategories, selection: $draft.categoryID) {
                    isSelectingCategory = false
                }
            }
        }
        .onChange(of: draft.amountText) { oldValue, newValue in
            syncSinglePaymentAmount(oldValue: oldValue, newValue: newValue)
        }
        .onChange(of: accounts.count) { _, _ in
            if entry == nil, draft.sourceAccountID == nil {
                draft.sourceAccountID = accounts.first?.id
            }
        }
        .onChange(of: draft.splitMode) { _, _ in prefillSplitValues() }
        .alert(Text(.transactionFormErrorTitle), isPresented: errorBinding) {
            Button(role: .cancel) {} label: {
                Text(.commonActionOK)
            }
        } message: {
            // 驗證訊息來自 Domain 與 repository，那一層還沒遷移到 catalog。
            Text(verbatim: errorMessage ?? LedgerStringKey.commonErrorRetryLater.string())
        }
    }

    /// 帳戶選單在三個 Picker 裡完全一樣，抽出來才不會三份各自漂移。
    @ViewBuilder
    private var accountOptions: some View {
        Text(.transactionFormPickerUnselected).tag(UUID?.none)
        ForEach(Array(accounts), id: \.objectID) { account in
            Text(verbatim: account.name
                ?? LedgerStringKey.commonPlaceholderUnnamedAccount.string()).tag(account.id)
        }
    }

    private func memberName(_ member: Member) -> String {
        member.displayName ?? LedgerStringKey.commonPlaceholderUnnamedMember.string()
    }

    /// 金額欄位在畫面上沒有自己的標籤，VoiceOver 只會唸出「文字欄位」；
    /// 讀不出這一格是誰的錢，這個表單就沒辦法用聽的填完。
    private func paymentFieldLabel(for member: Member) -> String {
        LedgerStringKey.transactionFormPaymentAmountAccessibilityLabel.string(
            arguments: [memberName(member)]
        )
    }

    private func splitFieldLabel(for member: Member) -> String {
        let key: LedgerStringKey = draft.splitMode == .percentage
            ? .transactionFormSplitPercentageAccessibilityLabel
            : .transactionFormSplitAmountAccessibilityLabel
        return key.string(arguments: [memberName(member)])
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func prefillDefaults() {
        if draft.splitMemberIDs.isEmpty {
            draft.splitMemberIDs = Set(members.compactMap(\.id))
        }
        if draft.paymentDrafts.isEmpty {
            let memberID = book.group.flatMap {
                CurrentMemberIdentityRepository().currentMember(in: $0)?.id
            } ?? members.first?.id
            draft.payerMemberID = memberID
            draft.paymentDrafts = [
                TransactionPaymentDraft(memberID: memberID, amountText: draft.amountText)
            ]
        }
        if draft.sourceAccountID == nil {
            draft.sourceAccountID = accounts.first?.id
        }
    }

    private func toggleSplit(_ member: Member) {
        guard let id = member.id else { return }
        if draft.splitMemberIDs.contains(id) {
            draft.splitMemberIDs.remove(id)
        } else {
            draft.splitMemberIDs.insert(id)
        }
        prefillSplitValues()
    }

    private var amountKeyboardType: UIKeyboardType {
        LedgerCurrency.fractionDigits(for: currencyCode) == 0 ? .numberPad : .decimalPad
    }

    private func isSplitMember(_ member: Member) -> Bool {
        member.id.map(draft.splitMemberIDs.contains) == true
    }

    @ViewBuilder
    private func splitSelectionIcon(for member: Member) -> some View {
        if isSplitMember(member) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(LedgerTheme.primary)
        } else {
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
        }
    }

    private func splitValueBinding(for member: Member) -> Binding<String> {
        guard let id = member.id else { return .constant("") }
        return Binding(
            get: { draft.splitValueTexts[id, default: ""] },
            set: { draft.splitValueTexts[id] = $0 }
        )
    }

    private func prefillSplitValues() {
        guard draft.splitMode != .equal else {
            draft.splitValueTexts.removeAll()
            return
        }
        let ids = draft.splitMemberIDs.sorted { $0.uuidString < $1.uuidString }
        guard !ids.isEmpty else { return }

        switch draft.splitMode {
        case .equal:
            break
        case .percentage:
            let totalUnits = 10_000
            let baseUnits = totalUnits / ids.count
            var remainder = totalUnits % ids.count
            draft.splitValueTexts = Dictionary(uniqueKeysWithValues: ids.map { id in
                let units = baseUnits + (remainder > 0 ? 1 : 0)
                remainder = max(0, remainder - 1)
                let value = NSDecimalNumber(value: units)
                    .multiplying(byPowerOf10: -2)
                    .stringValue
                return (id, value)
            })
        case .fixedAmount:
            guard let amount = draft.amountValue,
                  let allocations = try? AllocationCalculator.calculateSplits(
                    total: amount,
                    mode: .equal,
                    inputs: ids.map { SplitInput(memberID: $0, value: nil) },
                    currencyCode: currencyCode
                  )
            else { return }
            draft.splitValueTexts = Dictionary(uniqueKeysWithValues: allocations.map {
                ($0.memberID, NSDecimalNumber(decimal: $0.amount).stringValue)
            })
        }
    }

    private func isPayingMember(_ member: Member) -> Bool {
        guard let id = member.id else { return false }
        return draft.paymentDrafts.contains { $0.memberID == id }
    }

    @ViewBuilder
    private func paymentSelectionIcon(for member: Member) -> some View {
        if isPayingMember(member) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(LedgerTheme.primary)
        } else {
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
        }
    }

    private func paymentAmountBinding(for member: Member) -> Binding<String> {
        guard let memberID = member.id else { return .constant("") }
        return Binding(
            get: {
                draft.paymentDrafts.first { $0.memberID == memberID }?.amountText ?? ""
            },
            set: { value in
                guard let index = draft.paymentDrafts.firstIndex(where: { $0.memberID == memberID })
                else { return }
                draft.paymentDrafts[index].amountText = value
            }
        )
    }

    private func togglePayment(_ member: Member) {
        guard let memberID = member.id else { return }
        if let index = draft.paymentDrafts.firstIndex(where: { $0.memberID == memberID }) {
            draft.paymentDrafts.remove(at: index)
        } else {
            let amountText = draft.paymentDrafts.isEmpty ? draft.amountText : ""
            draft.paymentDrafts.append(
                TransactionPaymentDraft(memberID: memberID, amountText: amountText)
            )
        }
        draft.payerMemberID = draft.paymentDrafts.count == 1
            ? draft.paymentDrafts.first?.memberID
            : nil
    }

    private func syncSinglePaymentAmount(oldValue: String, newValue: String) {
        guard draft.paymentDrafts.count == 1 else { return }
        let currentValue = draft.paymentDrafts[0].amountText
        if currentValue.isEmpty || currentValue == oldValue {
            draft.paymentDrafts[0].amountText = newValue
        }
    }

    private var paymentSummary: String {
        let total = draft.paymentDrafts.compactMap(\.amountValue).reduce(0, +)
        return LedgerStringKey.transactionFormPayersFooter.string(
            arguments: [LedgerCurrency.format(total, currencyCode: currencyCode)]
        )
    }

    private var splitSummary: String {
        switch draft.splitMode {
        case .equal:
            return LedgerStringKey.transactionFormSplitsFooterEqual.string()
        case .percentage:
            return LedgerStringKey.transactionFormSplitsFooterPercentage.string(
                arguments: [NSDecimalNumber(decimal: splitInputTotal).stringValue]
            )
        case .fixedAmount:
            return LedgerStringKey.transactionFormSplitsFooterFixedAmount.string(
                arguments: [LedgerCurrency.format(splitInputTotal, currencyCode: currencyCode)]
            )
        }
    }

    private var splitInputTotal: Decimal {
        draft.splitMemberIDs.compactMap {
            draft.splitValueTexts[$0].flatMap(TransactionDraft.decimalValue(from:))
        }.reduce(0, +)
    }

    private var kindPicker: some View {
        Picker(selection: $draft.kind) {
            ForEach(EntryKind.userCreatableCases, id: \.self) { kind in
                Text(kind.displayNameKey).tag(kind)
            }
        } label: {
            Text(.transactionFormFieldKind)
        }
        .accessibilityLabel(Text(.transactionFormFieldKind))
    }

    private var selectedCategoryLabel: String {
        guard let category = availableCategories.first(where: { $0.id == draft.categoryID }) else {
            return LedgerStringKey.transactionFormCategoryNone.string()
        }
        return transactionCategoryPath(category)
    }

    private func save() {
        do {
            let repository = EntryRepository()
            if let entry {
                try repository.updateEntry(
                    entry,
                    from: draft,
                    accounts: Array(accounts),
                    categories: availableCategories,
                    members: members
                )
            } else {
                try repository.createEntry(
                    from: draft,
                    in: book,
                    accounts: Array(accounts),
                    categories: availableCategories,
                    members: members
                )
            }
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}


/// Capture the destination at the tap, even if a background update changes the selection.
struct TransactionComposerRequest: Identifiable {
    let id = UUID()
    let book: LedgerBook
    let kind: EntryKind
}

struct TransactionQuickEntryButtons: View {
    let onSelect: (EntryKind) -> Void

    var body: some View {
        LedgerAdaptiveStack(horizontalSpacing: 10) {
            action(.expense, title: .transactionQuickEntryExpense, tint: LedgerTheme.coral)
            action(.income, title: .transactionQuickEntryIncome, tint: LedgerTheme.primaryStrong)
        }
    }

    private func action(_ kind: EntryKind, title: LedgerStringKey, tint: Color) -> some View {
        Button { onSelect(kind) } label: {
            Label(title, systemImage: kind.systemImage)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 50)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .foregroundStyle(tint)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

private func transactionCategoryPath(_ category: LedgerCategory) -> String {
    var names: [String] = []
    var current: LedgerCategory? = category
    var visited: Set<NSManagedObjectID> = []
    while let node = current, visited.insert(node.objectID).inserted {
        names.append(node.name ?? LedgerStringKey.commonPlaceholderUnnamedCategory.string())
        current = node.parent
    }
    return names.reversed().joined(separator: " › ")
}

private struct TransactionCategorySelectionView: View {
    let categories: [LedgerCategory]
    @Binding var selection: UUID?
    let closePicker: () -> Void
    var parent: LedgerCategory? = nil
    @State private var search = ""

    private var keyword: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var matches: [LedgerCategory] {
        if !keyword.isEmpty {
            return categories.filter { transactionCategoryPath($0).localizedStandardContains(keyword) }
        }
        if let parent {
            return categories.filter { $0.parent?.objectID == parent.objectID }
        }
        let availableIDs = Set(categories.map(\.objectID))
        return categories.filter { category in
            // An archived selection may be present without its ancestors while editing.
            guard let parentID = category.parent?.objectID else { return true }
            return !availableIDs.contains(parentID)
        }
    }

    var body: some View {
        List {
            if keyword.isEmpty {
                Button {
                    selection = parent?.id
                    closePicker()
                } label: {
                    row(parent.map {
                        LedgerStringKey.categoryPickerUseParent.string(arguments: [
                            $0.name ?? LedgerStringKey.commonPlaceholderUnnamedCategory.string()
                        ])
                    } ?? LedgerStringKey.transactionFormCategoryNone.string(), selected: selection == parent?.id)
                }
                .accessibilityAddTraits(selection == parent?.id ? .isSelected : [])
            }
            ForEach(matches, id: \.objectID) { category in
                if keyword.isEmpty, categories.contains(where: { $0.parent?.objectID == category.objectID }) {
                    NavigationLink {
                        TransactionCategorySelectionView(
                            categories: categories, selection: $selection,
                            closePicker: closePicker, parent: category
                        )
                    } label: {
                        row(category.name ?? LedgerStringKey.commonPlaceholderUnnamedCategory.string(),
                            selected: selection == category.id)
                    }
                    .accessibilityAddTraits(selection == category.id ? .isSelected : [])
                } else {
                    Button {
                        selection = category.id
                        closePicker()
                    } label: {
                        row(transactionCategoryPath(category), selected: selection == category.id)
                    }
                    .accessibilityAddTraits(selection == category.id ? .isSelected : [])
                }
            }
            if matches.isEmpty {
                ContentUnavailableView {
                    Label(.categoryPickerEmptyTitle, systemImage: "magnifyingglass")
                } description: {
                    Text(.categoryPickerEmptyMessage)
                }
            }
        }
        .navigationTitle(parent?.name ?? LedgerStringKey.transactionFormFieldCategory.string())
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: Text(.categoryPickerSearchPrompt))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(action: closePicker) { Text(.commonActionCancel) }
            }
        }
    }

    private func row(_ title: String, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: title)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "checkmark")
                    .foregroundStyle(LedgerTheme.primary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}
