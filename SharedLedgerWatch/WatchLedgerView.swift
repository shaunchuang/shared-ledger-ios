import SwiftUI

struct WatchLedgerView: View {
    @ObservedObject var model: WatchLedgerModel

    var body: some View {
        List {
            if let pending = model.state.pending {
                Section {
                    Text(.watchPending)
                    Text(verbatim: LedgerCurrency.format(pending.amount, currencyCode: pending.currencyCode))
                    Text(pending.kind.displayNameKey)
                    Text(verbatim: LedgerFormatters.timestamp(pending.date))
                    Button { model.retry() } label: { Text(.watchRetry) }
                        .disabled(model.isSending)
                }
            }
            if let context = model.state.context, let snapshot = context.snapshot {
                Section {
                    Text(verbatim: snapshot.groupName).font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: snapshot.bookName).font(.headline)
                    TimelineView(.periodic(from: .now, by: 60)) { timeline in
                        if let summary = snapshot.summary(at: timeline.date) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(.widgetMonthExpense).font(.caption)
                                Text(verbatim: LedgerCurrency.format(summary.expense, currencyCode: snapshot.currencyCode))
                                    .font(.title3.bold()).minimumScaleFactor(0.6)
                                Text(.widgetMonthIncome).font(.caption)
                                Text(verbatim: LedgerCurrency.format(summary.income, currencyCode: snapshot.currencyCode))
                                Text(verbatim: LedgerStringKey.widgetTodayCount.string(arguments: [Int64(summary.todayCount)]))
                                    .font(.caption)
                            }
                        } else { Text(.widgetRefreshTitle) }
                    }
                    Text(verbatim: LedgerStringKey.widgetUpdatedAt.string(arguments: [LedgerFormatters.timestamp(snapshot.updatedAt)]))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if context.canCreate, model.state.pending == nil {
                    NavigationLink {
                        WatchEntryView(model: model, context: context, kind: .expense)
                    } label: { Label(.widgetAddExpense, systemImage: "minus.circle") }
                    NavigationLink {
                        WatchEntryView(model: model, context: context, kind: .income)
                    } label: { Label(.widgetAddIncome, systemImage: "plus.circle") }
                } else if let restriction = context.restriction { Text(verbatim: restriction) }
            } else {
                Text(verbatim: model.state.context?.restriction ?? LedgerStringKey.watchSetup.string())
            }
            if let message = model.message { Text(verbatim: message).font(.footnote) }
            Button { model.refresh() } label: { Label(.watchRefresh, systemImage: "arrow.clockwise") }
                .disabled(model.isSending)
            if model.isSending { ProgressView() }
        }
        .navigationTitle(Text(verbatim: "Shared Ledger"))
    }
}

private struct WatchEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: WatchLedgerModel
    let context: WatchLedgerContext
    let kind: EntryKind
    @State private var amount = ""
    @State private var accountID: UUID?
    @State private var categoryID: UUID?
    @State private var confirmsSave = false

    private var currency: String { context.snapshot?.currencyCode ?? LedgerCurrency.fallbackCode }
    private var amountValue: Decimal? { Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")) }
    private var canSave: Bool {
        guard let value = amountValue else { return false }
        return !value.isNaN && value > 0 && LedgerCurrency.isValidAmount(value, currencyCode: currency)
            && accountID != nil && model.state.pending == nil && !model.isSending
    }

    var body: some View {
        List {
            Text(verbatim: context.snapshot?.bookName ?? "").font(.headline)
            Text(verbatim: currency).font(.caption)
            Text(verbatim: amount.isEmpty ? "0" : amount).font(.title2.bold())
                .accessibilityLabel(Text(.transactionFormFieldAmount))
                .accessibilityValue(amount.isEmpty ? "0" : amount)
            // A numeric keypad works on every supported watch size and language,
            // without depending on Scribble or a full QWERTY keyboard.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", ".", "0", "⌫"], id: \.self) { key in
                    Button { append(key) } label: {
                        Text(verbatim: key).frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(key == "⌫" ? LedgerStringKey.watchBackspace.string() : key)
                    .disabled(key == "." && LedgerCurrency.fractionDigits(for: currency) == 0)
                }
            }
            Picker(selection: $accountID) {
                ForEach(context.accounts) { account in Text(verbatim: account.name).tag(Optional(account.id)) }
            } label: { Text(.transactionFormFieldAccount) }
            Picker(selection: $categoryID) {
                Text(.transactionFormCategoryNone).tag(UUID?.none)
                ForEach(context.categories) { category in Text(verbatim: category.name).tag(Optional(category.id)) }
            } label: { Text(.transactionFormFieldCategory) }
            Text(verbatim: LedgerStringKey.watchPayer.string(arguments: [context.payer?.name ?? ""]))
                .font(.footnote)
            Text(.watchEqualSplit).font(.footnote)
            ForEach(context.members) { member in Text(verbatim: member.name).font(.caption) }
            Button { confirmsSave = true } label: { Text(.commonActionSave) }
                .disabled(!canSave)
        }
        .navigationTitle(Text(kind.displayNameKey))
        .onAppear { if accountID == nil { accountID = context.accounts.first?.id } }
        .confirmationDialog(Text(.watchConfirm), isPresented: $confirmsSave, titleVisibility: .visible) {
            Button { save() } label: { Text(.commonActionSave) }
            Button(role: .cancel) {} label: { Text(.commonActionCancel) }
        } message: {
            Text(verbatim: LedgerCurrency.format(amountValue ?? 0, currencyCode: currency))
        }
    }

    private func append(_ key: String) {
        if key == "⌫" { if !amount.isEmpty { amount.removeLast() }; return }
        guard amount.count < 12 else { return }
        if key == "." {
            guard !amount.contains(".") else { return }
            if amount.isEmpty { amount = "0" }
        }
        amount += key
    }

    private func save() {
        guard canSave, let snapshot = context.snapshot, let groupID = context.groupID,
              let accountID, let payer = context.payer, let value = amountValue else { return }
        model.save(WatchLedgerRequest(id: UUID(), groupID: groupID, bookID: snapshot.bookID,
                                     currencyCode: currency, kind: kind, amount: value, date: Date(),
                                     accountID: accountID, categoryID: categoryID, payerID: payer.id,
                                     memberIDs: context.members.map(\.id)))
        dismiss()
    }
}
