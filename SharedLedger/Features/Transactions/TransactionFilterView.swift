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
        .navigationTitle("篩選交易")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("重設篩選") {
                    let keyword = query.keyword
                    query = TransactionQuery()
                    // 關鍵字來自搜尋列而不是這個面板，重設篩選不該把使用者正在
                    // 輸入的搜尋字一起清掉。
                    query.keyword = keyword
                    scope = .currentBook
                    selectedBookIDs = []
                }
                .disabled(!query.hasActiveFilters && scope == .currentBook)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
    }

    private var scopeSection: some View {
        Section {
            Picker("帳本範圍", selection: $scope) {
                ForEach(ReportBookScope.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)

            if scope == .selectedBookIDs {
                ForEach(activeBooks, id: \.objectID) { book in
                    if let id = book.id {
                        selectionRow(
                            title: book.name ?? "未命名帳本",
                            isSelected: selectedBookIDs.contains(id)
                        ) {
                            toggle(id, in: &selectedBookIDs)
                        }
                    }
                }
            }
        } header: {
            Text("搜尋範圍")
        } footer: {
            Text(scopeFooter)
        }
    }

    private var scopeFooter: String {
        switch scope {
        case .allActiveBooks:
            return "結果涵蓋這個群組所有使用中的帳本，每一筆都會標示所屬帳本。已封存帳本不納入。"
        case .currentBook:
            return "只搜尋「\(currentBookName)」的交易。"
        case .selectedBookIDs:
            return selectedBookIDs.isEmpty
                ? "尚未選擇帳本，目前不會有任何結果。"
                : "結果涵蓋已選的 \(selectedBookIDs.count) 本帳本。"
        }
    }

    private var dateSection: some View {
        Section {
            Toggle("限定日期範圍", isOn: dateRangeBinding)
            if query.startDate != nil || query.endDate != nil {
                DatePicker(
                    "開始日期",
                    selection: dateBinding(for: \.startDate, fallback: defaultStartDate),
                    displayedComponents: .date
                )
                DatePicker(
                    "結束日期",
                    selection: dateBinding(for: \.endDate, fallback: Date()),
                    displayedComponents: .date
                )
                HStack {
                    quickRangeButton("本月", months: 0)
                    quickRangeButton("上個月", months: -1)
                    Button("近 90 天") {
                        let calendar = Calendar.current
                        query.endDate = Date()
                        query.startDate = calendar.date(byAdding: .day, value: -89, to: Date())
                    }
                    .buttonStyle(.borderless)
                }
                .font(.footnote.weight(.semibold))
            }
        } header: {
            Text("日期")
        } footer: {
            if query.hasInvertedDateRange {
                Text("開始日期晚於結束日期，目前不會有任何結果。")
                    .foregroundStyle(LedgerTheme.coral)
            } else {
                Text("開始與結束當天的交易都會包含在內。")
            }
        }
    }

    private var amountSection: some View {
        Section {
            HStack {
                Text("最低金額")
                Spacer()
                TextField("不限", text: $query.minAmountText)
                    .keyboardType(amountKeyboard)
                    .multilineTextAlignment(.trailing)
            }
            HStack {
                Text("最高金額")
                Spacer()
                TextField("不限", text: $query.maxAmountText)
                    .keyboardType(amountKeyboard)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("金額（\(currencyCode)）")
        } footer: {
            if query.hasUnparsableAmountInput {
                Text("金額格式不正確，這個條件目前沒有生效。")
                    .foregroundStyle(LedgerTheme.coral)
            } else if query.hasInvertedAmountRange {
                Text("最低金額大於最高金額，目前不會有任何結果。")
                    .foregroundStyle(LedgerTheme.coral)
            } else {
                Text("比對交易金額本身，不是個別成員的分攤金額。")
            }
        }
    }

    private var accountSection: some View {
        Section {
            if accounts.isEmpty {
                Text("這個群組還沒有帳戶。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(accounts, id: \.objectID) { account in
                    if let id = account.id {
                        selectionRow(
                            title: account.name ?? "未命名帳戶",
                            isSelected: query.accountIDs.contains(id)
                        ) {
                            toggle(id, in: &query.accountIDs)
                        }
                    }
                }
            }
        } header: {
            Text("帳戶")
        } footer: {
            Text("轉帳只要轉出或轉入其中一邊符合就會列出。")
        }
    }

    private var categorySection: some View {
        Section {
            selectionRow(title: "未分類", isSelected: query.includesUncategorized) {
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
            Text("分類")
        } footer: {
            Text("選擇父分類會一併包含它底下的子分類。")
        }
    }

    private var memberSection: some View {
        Section {
            if members.isEmpty {
                Text("這個群組還沒有成員。")
                    .foregroundStyle(.secondary)
            } else {
                DisclosureGroup("付款人") {
                    ForEach(members, id: \.objectID) { member in
                        if let id = member.id {
                            selectionRow(
                                title: member.displayName ?? "未命名成員",
                                isSelected: query.payerMemberIDs.contains(id)
                            ) {
                                toggle(id, in: &query.payerMemberIDs)
                            }
                        }
                    }
                }
                DisclosureGroup("參與分攤的成員") {
                    ForEach(members, id: \.objectID) { member in
                        if let id = member.id {
                            selectionRow(
                                title: member.displayName ?? "未命名成員",
                                isSelected: query.participantMemberIDs.contains(id)
                            ) {
                                toggle(id, in: &query.participantMemberIDs)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("成員")
        } footer: {
            Text("付款人比對這筆交易的付款明細，參與成員比對分攤明細。")
        }
    }

    private var voidedSection: some View {
        Section {
            Toggle("包含已作廢的交易", isOn: $query.includesVoided)
        } footer: {
            Text("作廢交易不列入收支小計，只用來核對歷史紀錄。")
        }
    }

    private func quickRangeButton(_ title: String, months: Int) -> some View {
        Button(title) {
            let calendar = Calendar.current
            guard let anchor = calendar.date(byAdding: .month, value: months, to: Date()),
                  let interval = calendar.dateInterval(of: .month, for: anchor)
            else { return }
            query.startDate = interval.start
            // 區間的上界是下個月 1 日 00:00，往回一天才是使用者認知的「這個月最後一天」。
            query.endDate = calendar.date(byAdding: .day, value: -1, to: interval.end)
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
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(LedgerTheme.primary)
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
        return [CategoryOption(id: id, name: category.name ?? "未命名分類", depth: depth)] + children
    }

    private struct CategoryOption: Identifiable {
        let id: UUID
        let name: String
        let depth: Int
    }
}
