import CoreData
import SwiftUI
import UIKit

struct NewTransactionView: View {
    @Environment(\.dismiss) private var dismiss

    let book: LedgerBook
    let onSaved: () -> Void

    @FetchRequest private var accounts: FetchedResults<LedgerAccount>
    @FetchRequest private var categories: FetchedResults<LedgerCategory>

    @State private var draft = TransactionDraft()
    @State private var errorMessage: String?

    init(book: LedgerBook, onSaved: @escaping () -> Void) {
        self.book = book
        self.onSaved = onSaved
        let accountPredicate = book.group.map {
            NSPredicate(format: "group == %@ AND archivedAt == nil", $0)
        } ?? NSPredicate(value: false)
        _accounts = FetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \LedgerAccount.createdAt, ascending: true)],
            predicate: accountPredicate
        )
        _categories = FetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \LedgerCategory.sortOrder, ascending: true)],
            predicate: book.group.map {
                NSPredicate(format: "group == %@ AND archivedAt == nil", $0)
            } ?? NSPredicate(value: false)
        )
    }

    private var members: [Member] {
        let set = book.group?.members as? Set<Member> ?? []
        return set
            .filter { $0.archivedAt == nil }
            .sorted { ($0.displayName ?? "") < ($1.displayName ?? "") }
    }

    private var currencyCode: String {
        LedgerCurrency.normalizedCode(book.group?.currencyCode)
    }

    private var availableCategories: [LedgerCategory] {
        let availableIDs = Set(
            CategoryRepository()
                .availableCategories(in: book)
                .map(\.objectID)
        )
        return categories.filter { availableIDs.contains($0.objectID) }
    }

    var body: some View {
        Form {
            Section {
                Picker("類型", selection: $draft.kind) {
                    ForEach(EntryKind.userCreatableCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
            }
            .listRowBackground(Color.clear)

            Section {
                HStack {
                    Text("金額")
                    Spacer()
                    Text(currencyCode)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("0", text: $draft.amountText)
                        .keyboardType(
                            LedgerCurrency.fractionDigits(for: currencyCode) == 0
                                ? .numberPad
                                : .decimalPad
                        )
                        .multilineTextAlignment(.trailing)
                }
                DatePicker("日期", selection: $draft.date, displayedComponents: .date)
            }

            if draft.kind == .transfer {
                Section("轉帳帳戶") {
                    if accounts.isEmpty {
                        Text("請先在群組設定新增至少兩個帳戶。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("轉出帳戶", selection: $draft.sourceAccountID) {
                            Text("請選擇").tag(UUID?.none)
                            ForEach(Array(accounts), id: \.objectID) { account in
                                Text(account.name ?? "未命名帳戶").tag(account.id)
                            }
                        }
                        Picker("轉入帳戶", selection: $draft.destinationAccountID) {
                            Text("請選擇").tag(UUID?.none)
                            ForEach(Array(accounts), id: \.objectID) { account in
                                Text(account.name ?? "未命名帳戶").tag(account.id)
                            }
                        }
                    }
                }
            } else {
                Section("帳戶與分類") {
                    if accounts.isEmpty {
                        Text("請先在群組設定新增帳戶。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("帳戶", selection: $draft.sourceAccountID) {
                            Text("請選擇").tag(UUID?.none)
                            ForEach(Array(accounts), id: \.objectID) { account in
                                Text(account.name ?? "未命名帳戶").tag(account.id)
                            }
                        }
                    }
                    Picker("分類", selection: $draft.categoryID) {
                        Text("未分類").tag(UUID?.none)
                        ForEach(availableCategories, id: \.objectID) { category in
                            Text(categoryLabel(category)).tag(category.id)
                        }
                    }
                }

                Section {
                    ForEach(members, id: \.objectID) { member in
                        HStack(spacing: 12) {
                            Button {
                                togglePayment(member)
                            } label: {
                                HStack(spacing: 10) {
                                    paymentSelectionIcon(for: member)
                                    Text(member.displayName ?? "未命名成員")
                                        .foregroundStyle(.primary)
                                }
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            if isPayingMember(member) {
                                TextField("0", text: paymentAmountBinding(for: member))
                                    .keyboardType(amountKeyboardType)
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: 120)
                                Text(currencyCode)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("付款人")
                } footer: {
                    Text(paymentSummary)
                }

                Section {
                    Picker("方式", selection: $draft.splitMode) {
                        ForEach(SplitMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    ForEach(members, id: \.objectID) { member in
                        HStack(spacing: 12) {
                            Button {
                                toggleSplit(member)
                            } label: {
                                HStack(spacing: 10) {
                                    splitSelectionIcon(for: member)
                                    Text(member.displayName ?? "未命名成員")
                                        .foregroundStyle(.primary)
                                }
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            if isSplitMember(member), draft.splitMode != .equal {
                                TextField("0", text: splitValueBinding(for: member))
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: 120)
                                Text(draft.splitMode == .percentage ? "%" : currencyCode)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("分攤")
                } footer: {
                    Text(splitSummary)
                }
            }

            Section("備註") {
                TextField("備註（選填）", text: $draft.note, axis: .vertical)
                    .lineLimit(2...4)
            }
        }
        .navigationTitle("新增交易")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("儲存", action: save)
                    .disabled(!draft.canSave)
            }
        }
        .onAppear(perform: prefillDefaults)
        .onChange(of: draft.amountText) { oldValue, newValue in
            syncSinglePaymentAmount(oldValue: oldValue, newValue: newValue)
        }
        .onChange(of: draft.splitMode) { _, _ in prefillSplitValues() }
        .alert("無法儲存交易", isPresented: errorBinding) {
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
        return "付款合計 \(LedgerCurrency.format(total, currencyCode: currencyCode))；必須等於交易金額。"
    }

    private var splitSummary: String {
        switch draft.splitMode {
        case .equal:
            return "金額會依貨幣最小單位平均分攤，尾差以固定順序分配。"
        case .percentage:
            let total = draft.splitMemberIDs.compactMap {
                draft.splitValueTexts[$0].flatMap(TransactionDraft.decimalValue(from:))
            }.reduce(0, +)
            return "比例合計 \(NSDecimalNumber(decimal: total).stringValue)%；必須等於 100%。"
        case .fixedAmount:
            let total = draft.splitMemberIDs.compactMap {
                draft.splitValueTexts[$0].flatMap(TransactionDraft.decimalValue(from:))
            }.reduce(0, +)
            return "分攤合計 \(LedgerCurrency.format(total, currencyCode: currencyCode))；必須等於交易金額。"
        }
    }

    private func categoryLabel(_ category: LedgerCategory) -> String {
        var depth = 0
        var current = category.parent
        while let parent = current {
            depth += 1
            current = parent.parent
        }
        let prefix = String(repeating: "　", count: depth)
        return prefix + (category.name ?? "未命名分類")
    }

    private func save() {
        do {
            try EntryRepository().createEntry(
                from: draft,
                in: book,
                accounts: Array(accounts),
                categories: availableCategories,
                members: members
            )
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension SplitMode {
    var displayName: String {
        switch self {
        case .equal: "平均"
        case .percentage: "比例"
        case .fixedAmount: "指定金額"
        }
    }
}
