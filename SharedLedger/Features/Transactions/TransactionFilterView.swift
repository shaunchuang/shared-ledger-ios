import CoreData
import SwiftUI
import UIKit

/// 交易搜尋的複合篩選面板。
///
/// 直接綁定呼叫端的 `TransactionQuery`，關掉面板前就能看到結果變化；不做「套用」
/// 按鈕，是為了讓使用者一邊調整一邊確認自己收斂到什麼範圍。
struct TransactionFilterView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var group: LedgerGroup
    @Binding var query: TransactionQuery
    @Binding var scope: ReportBookScope
    @Binding var selectedBookIDs: Set<UUID>
    let currentBookName: String

    private var currencyCode: String {
        LedgerCurrency.normalizedCode(group.currencyCode)
    }

    private var amountKeyboard: UIKeyboardType {
        LedgerCurrency.fractionDigits(for: currencyCode) == 0 ? .numberPad : .decimalPad
    }

    private var activeBooks: [LedgerBook] {
        BookRepository().books(in: group)
    }

    private var accounts: [LedgerAccount] {
        (group.accounts as? Set<LedgerAccount> ?? [])
            .filter { $0.archivedAt == nil }
            .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    private var members: [Member] {
        (group.members as? Set<Member> ?? [])
            .filter { $0.archivedAt == nil }
            .sorted { ($0.displayName ?? "") < ($1.displayName ?? "") }
    }

    private var categoryOptions: [CategoryOption] {
        let categories = CategoryRepository().categories(in: group)
        let roots = categories.filter { $0.parent == nil }
        return roots.flatMap { options(for: $0, depth: 0, all: categories) }
    }

    var body: some View {
        Form {
            scopeSection
            dateSection
            amountSection
            accountSection
            categorySection
            memberSection
            voidedSection
        }
        .navigationTitle(Text(.transactionFilterTitle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    let keyword = query.keyword
                    query = TransactionQuery()
                    // 關鍵字來自搜尋列而不是這個面板，重設篩選不該把使用者正在
                    // 輸入的搜尋字一起清掉。
                    query.keyword = keyword
                    scope = .currentBook
                    selectedBookIDs = []
                } label: {
                    Text(.transactionFilterActionReset)
                }
                .disabled(!query.hasActiveFilters && scope == .currentBook)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button { dismiss() } label: {
                    Text(.commonActionDone)
                }
            }
        }
    }

    private var scopeSection: some View {
        Section {
            Picker(selection: $scope) {
                ForEach(ReportBookScope.allCases) { option in
                    Text(option.displayNameKey).tag(option)
                }
            } label: {
                Text(.transactionFilterFieldBookScope)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(Text(.transactionFilterFieldBookScope))

            if scope == .selectedBookIDs {
                ForEach(activeBooks, id: \.objectID) { book in
                    if let id = book.id {
                        selectionRow(
                            title: book.name ?? LedgerStringKey.commonPlaceholderUnnamedBook.string(),
                            isSelected: selectedBookIDs.contains(id)
                        ) {
                            toggle(id, in: &selectedBookIDs)
                        }
                    }
                }
            }
        } header: {
            Text(.transactionFilterSectionScope)
        } footer: {
            Text(verbatim: scopeFooter)
        }
    }

    private var scopeFooter: String {
        switch scope {
        case .allActiveBooks:
            return LedgerStringKey.transactionFilterScopeFooterAllBooks.string()
        case .currentBook:
            return LedgerStringKey.transactionFilterScopeFooterCurrentBook.string(
                arguments: [currentBookName]
            )
        case .selectedBookIDs:
            guard !selectedBookIDs.isEmpty else {
                return LedgerStringKey.transactionFilterScopeFooterNoSelection.string()
            }
            return LedgerStringKey.transactionFilterScopeFooterSelected.string(
                arguments: [Int64(selectedBookIDs.count)]
            )
        }
    }

    private var dateSection: some View {
        Section {
            Toggle(isOn: dateRangeBinding) {
                Text(.transactionFilterDateToggle)
            }
            if query.startDate != nil || query.endDate != nil {
                DatePicker(
                    selection: dateBinding(for: \.startDate, fallback: defaultStartDate),
                    displayedComponents: .date
                ) {
                    Text(.transactionFilterDateStart)
                }
                DatePicker(
                    selection: dateBinding(for: \.endDate, fallback: Date()),
                    displayedComponents: .date
                ) {
                    Text(.transactionFilterDateEnd)
                }
                HStack {
                    quickRangeButton(.transactionFilterDateThisMonth, months: 0)
                    quickRangeButton(.transactionFilterDateLastMonth, months: -1)
                    Button {
                        let calendar = Calendar.current
                        query.endDate = Date()
                        query.startDate = calendar.date(byAdding: .day, value: -89, to: Date())
                    } label: {
                        Text(.transactionFilterDateLast90Days)
                    }
                    .buttonStyle(.borderless)
                }
                .font(.footnote.weight(.semibold))
            }
        } header: {
            Text(.transactionFilterSectionDate)
        } footer: {
            if query.hasInvertedDateRange {
                Text(.transactionFilterDateFooterInverted)
                    .foregroundStyle(LedgerTheme.coral)
            } else {
                Text(.transactionFilterDateFooterNormal)
            }
        }
    }

    private var amountSection: some View {
        Section {
            HStack {
                Text(.transactionFilterAmountMin)
                Spacer()
                TextField(
                    "",
                    text: $query.minAmountText,
                    prompt: Text(.transactionFilterAmountPlaceholder)
                )
                .keyboardType(amountKeyboard)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(Text(.transactionFilterAmountMin))
            }
            HStack {
                Text(.transactionFilterAmountMax)
                Spacer()
                TextField(
                    "",
                    text: $query.maxAmountText,
                    prompt: Text(.transactionFilterAmountPlaceholder)
                )
                .keyboardType(amountKeyboard)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(Text(.transactionFilterAmountMax))
            }
        } header: {
            Text(verbatim: LedgerStringKey.transactionFilterSectionAmount.string(
                arguments: [currencyCode]
            ))
        } footer: {
            if query.hasUnparsableAmountInput {
                Text(.transactionFilterAmountFooterUnparsable)
                    .foregroundStyle(LedgerTheme.coral)
            } else if query.hasInvertedAmountRange {
                Text(.transactionFilterAmountFooterInverted)
                    .foregroundStyle(LedgerTheme.coral)
            } else {
                Text(.transactionFilterAmountFooterNormal)
            }
        }
    }

    private var accountSection: some View {
        Section {
            if accounts.isEmpty {
                Text(.transactionFilterAccountEmpty)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(accounts, id: \.objectID) { account in
                    if let id = account.id {
                        selectionRow(
                            title: account.name
                                ?? LedgerStringKey.commonPlaceholderUnnamedAccount.string(),
                            isSelected: query.accountIDs.contains(id)
                        ) {
                            toggle(id, in: &query.accountIDs)
                        }
                    }
                }
            }
        } header: {
            Text(.transactionFilterSectionAccount)
        } footer: {
            Text(.transactionFilterAccountFooter)
        }
    }

    private var categorySection: some View {
        Section {
            selectionRow(
                title: LedgerStringKey.transactionFilterCategoryUncategorized.string(),
                isSelected: query.includesUncategorized
            ) {
                query.includesUncategorized.toggle()
            }
            ForEach(categoryOptions) { option in
                selectionRow(
                    title: option.name,
                    isSelected: query.categoryIDs.contains(option.id),
                    indent: option.depth
                ) {
                    toggle(option.id, in: &query.categoryIDs)
                }
            }
        } header: {
            Text(.transactionFilterSectionCategory)
        } footer: {
            Text(.transactionFilterCategoryFooter)
        }
    }

    private var memberSection: some View {
        Section {
            if members.isEmpty {
                Text(.transactionFilterMemberEmpty)
                    .foregroundStyle(.secondary)
            } else {
                DisclosureGroup {
                    ForEach(members, id: \.objectID) { member in
                        if let id = member.id {
                            selectionRow(
                                title: memberName(member),
                                isSelected: query.payerMemberIDs.contains(id)
                            ) {
                                toggle(id, in: &query.payerMemberIDs)
                            }
                        }
                    }
                } label: {
                    Text(.transactionFilterMemberPayers)
                }
                DisclosureGroup {
                    ForEach(members, id: \.objectID) { member in
                        if let id = member.id {
                            selectionRow(
                                title: memberName(member),
                                isSelected: query.participantMemberIDs.contains(id)
                            ) {
                                toggle(id, in: &query.participantMemberIDs)
                            }
                        }
                    }
                } label: {
                    Text(.transactionFilterMemberParticipants)
                }
            }
        } header: {
            Text(.transactionFilterSectionMember)
        } footer: {
            Text(.transactionFilterMemberFooter)
        }
    }

    private var voidedSection: some View {
        Section {
            Toggle(isOn: $query.includesVoided) {
                Text(.transactionFilterVoidedToggle)
            }
        } footer: {
            Text(.transactionFilterVoidedFooter)
        }
    }

    private func memberName(_ member: Member) -> String {
        member.displayName ?? LedgerStringKey.commonPlaceholderUnnamedMember.string()
    }

    private func quickRangeButton(_ title: LedgerStringKey, months: Int) -> some View {
        Button {
            let calendar = Calendar.current
            guard let anchor = calendar.date(byAdding: .month, value: months, to: Date()),
                  let interval = calendar.dateInterval(of: .month, for: anchor)
            else { return }
            query.startDate = interval.start
            // 區間的上界是下個月 1 日 00:00，往回一天才是使用者認知的「這個月最後一天」。
            query.endDate = calendar.date(byAdding: .day, value: -1, to: interval.end)
        } label: {
            Text(title)
        }
        .buttonStyle(.borderless)
    }

    private var defaultStartDate: Date {
        Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    }

    private var dateRangeBinding: Binding<Bool> {
        Binding(
            get: { query.startDate != nil || query.endDate != nil },
            set: { isOn in
                if isOn {
                    query.startDate = defaultStartDate
                    query.endDate = Date()
                } else {
                    query.startDate = nil
                    query.endDate = nil
                }
            }
        )
    }

    private func dateBinding(
        for keyPath: WritableKeyPath<TransactionQuery, Date?>,
        fallback: Date
    ) -> Binding<Date> {
        Binding(
            get: { query[keyPath: keyPath] ?? fallback },
            set: { query[keyPath: keyPath] = $0 }
        )
    }

    private func selectionRow(
        title: String,
        isSelected: Bool,
        indent: Int = 0,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if indent > 0 {
                    Spacer().frame(width: CGFloat(indent) * 16)
                }
                // 這些列的標題都是帳本、帳戶、分類或成員名稱，屬於資料而不是文案。
                Text(verbatim: title)
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(LedgerTheme.primary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func toggle<Value: Hashable>(_ value: Value, in set: inout Set<Value>) {
        if set.contains(value) {
            set.remove(value)
        } else {
            set.insert(value)
        }
    }

    private func options(
        for category: LedgerCategory,
        depth: Int,
        all: [LedgerCategory]
    ) -> [CategoryOption] {
        guard let id = category.id else { return [] }
        let children = all
            .filter { $0.parent == category }
            .flatMap { options(for: $0, depth: depth + 1, all: all) }
        let name = category.name ?? LedgerStringKey.commonPlaceholderUnnamedCategory.string()
        return [CategoryOption(id: id, name: name, depth: depth)] + children
    }

    private struct CategoryOption: Identifiable {
        let id: UUID
        let name: String
        let depth: Int
    }
}
