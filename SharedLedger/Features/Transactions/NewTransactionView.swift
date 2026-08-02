import CoreData
import SwiftUI
import UIKit

struct NewTransactionView: View {
    @Environment(\.dismiss) private var dismiss

    let book: LedgerBook
    let entry: LedgerEntry?
    let onSaved: () -> Void

    @FetchRequest private var accounts: FetchedResults<LedgerAccount>
    @FetchRequest private var categories: FetchedResults<LedgerCategory>

    @State private var draft: TransactionDraft
    @State private var errorMessage: String?

    init(
        book: LedgerBook,
        entry: LedgerEntry? = nil,
        onSaved: @escaping () -> Void
    ) {
        self.book = book
        self.entry = entry
        self.onSaved = onSaved
        _draft = State(initialValue: entry.map(TransactionDraft.init(entry:)) ?? TransactionDraft())

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
            ((entry?.splits as? Set<EntrySplit>) ?? []).compactMap { $0.member?.id }
                + ((entry?.payments as? Set<EntryPayment>) ?? []).compactMap { $0.member?.id }
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
            Section {
                Picker(selection: $draft.kind) {
                    ForEach(EntryKind.userCreatableCases, id: \.self) { kind in
                        Text(kind.displayNameKey).tag(kind)
                    }
                } label: {
                    Text(.transactionFormFieldKind)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(Text(.transactionFormFieldKind))
            }
            .listRowBackground(Color.clear)

            Section {
                HStack {
                    Text(.transactionFormFieldAmount)
                    Spacer()
                    // 貨幣代碼是資料，不翻譯。
                    Text(verbatim: currencyCode)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    // 標籤留空：欄位名稱已經在同一列的左側，這裡只需要提示輸入格式。
                    TextField("", text: $draft.amountText, prompt: Text(verbatim: "0"))
                        .keyboardType(amountKeyboardType)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel(Text(.transactionFormFieldAmount))
                }
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
                    Picker(selection: $draft.categoryID) {
                        Text(.transactionFormCategoryNone).tag(UUID?.none)
                        ForEach(availableCategories, id: \.objectID) { category in
                            Text(verbatim: categoryLabel(category)).tag(category.id)
                        }
                    } label: {
                        Text(.transactionFormFieldCategory)
                    }
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
                .disabled(!draft.canSave)
            }
        }
        .onAppear {
            if entry == nil {
                prefillDefaults()
            }
        }
        .onChange(of: draft.amountText) { oldValue, newValue in
            syncSinglePaymentAmount(oldValue: oldValue, newValue: newValue)
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

    private func categoryLabel(_ category: LedgerCategory) -> String {
        var depth = 0
        var current = category.parent
        while let parent = current {
            depth += 1
            current = parent.parent
        }
        let prefix = String(repeating: "　", count: depth)
        return prefix + (category.name ?? LedgerStringKey.commonPlaceholderUnnamedCategory.string())
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

