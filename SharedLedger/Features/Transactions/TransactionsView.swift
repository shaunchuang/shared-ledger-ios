import CoreData
import SwiftUI

struct TransactionsView: View {
    private enum Filter: String, CaseIterable, Identifiable {
        case all = "全部"
        case expense = "支出"
        case income = "收入"
        case transfer = "轉帳"

        var id: Self { self }

        var kind: EntryKind? {
            switch self {
            case .all: return nil
            case .expense: return .expense
            case .income: return .income
            case .transfer: return .transfer
            }
        }
    }

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \LedgerGroup.updatedAt, ascending: false)],
        animation: .default
    ) private var groups: FetchedResults<LedgerGroup>

    @State private var filter: Filter = .all
    @State private var isPresentingNewEntry = false
    @State private var selectedGroupID: NSManagedObjectID?

    private var selectedGroup: LedgerGroup? {
        if let selectedGroupID, let match = groups.first(where: { $0.objectID == selectedGroupID }) {
            return match
        }
        return groups.first
    }

    var body: some View {
        ZStack {
            LedgerBackground()
            if let group = selectedGroup {
                VStack(spacing: 0) {
                    header(for: group)
                    TransactionListView(group: group, kind: filter.kind) {
                        isPresentingNewEntry = true
                    }
                    .id(group.objectID)
                }
            } else {
                ScrollView {
                    LedgerEmptyState(
                        systemImage: "person.3",
                        title: "先建立一個群組",
                        message: "交易記錄屬於群組，請先在「群組」分頁建立群組，再回來新增交易。"
                    )
                    .padding(.horizontal, LedgerTheme.pagePadding)
                    .padding(.top, 24)
                }
            }
        }
        .navigationTitle("交易")
        .toolbar {
            if selectedGroup != nil {
                Button {
                    isPresentingNewEntry = true
                } label: {
                    Image(systemName: "plus")
                        .fontWeight(.bold)
                }
                .accessibilityLabel("新增交易")
            }
        }
        .sheet(isPresented: $isPresentingNewEntry) {
            if let group = selectedGroup {
                NavigationStack {
                    NewTransactionView(group: group) {
                        isPresentingNewEntry = false
                    }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    @ViewBuilder
    private func header(for group: LedgerGroup) -> some View {
        VStack(spacing: 14) {
            if groups.count > 1 {
                Menu {
                    ForEach(groups, id: \.objectID) { candidate in
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
                    HStack(spacing: 6) {
                        Text(group.name ?? "未命名群組")
                            .font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(LedgerTheme.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Picker("交易類型", selection: $filter) {
                ForEach(Filter.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, LedgerTheme.pagePadding)
        .padding(.top, 12)
    }
}

private struct TransactionListView: View {
    @FetchRequest private var entries: FetchedResults<LedgerEntry>
    let onAddFirst: () -> Void

    init(group: LedgerGroup, kind: EntryKind?, onAddFirst: @escaping () -> Void) {
        self.onAddFirst = onAddFirst
        let predicate: NSPredicate
        if let kind {
            predicate = NSPredicate(format: "group == %@ AND kind == %@", group, kind.rawValue)
        } else {
            predicate = NSPredicate(format: "group == %@", group)
        }
        _entries = FetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \LedgerEntry.date, ascending: false)],
            predicate: predicate,
            animation: .default
        )
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if entries.isEmpty {
                    LedgerEmptyState(
                        systemImage: "receipt",
                        title: "帳本還是空的",
                        message: "新增第一筆共同收支，之後就能在這裡快速搜尋、篩選與核對。",
                        actionTitle: "新增第一筆交易",
                        action: onAddFirst
                    )
                } else {
                    ForEach(entries, id: \.objectID) { entry in
                        EntryRow(entry: entry)
                    }
                }
            }
            .padding(.horizontal, LedgerTheme.pagePadding)
            .padding(.top, 16)
            .padding(.bottom, 28)
        }
    }
}

private struct EntryRow: View {
    @ObservedObject var entry: LedgerEntry

    private var kind: EntryKind {
        EntryKind(rawValue: entry.kind ?? "") ?? .expense
    }

    private var title: String {
        if let categoryName = entry.category?.name, !categoryName.isEmpty {
            return categoryName
        }
        if let note = entry.note, !note.isEmpty {
            return note
        }
        return kind.displayName
    }

    private var subtitle: String {
        var parts: [String] = []
        if let date = entry.date {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        if kind == .transfer, let from = entry.sourceAccount?.name, let to = entry.destinationAccount?.name {
            parts.append("\(from) → \(to)")
        } else if let account = entry.sourceAccount?.name {
            parts.append(account)
        }
        return parts.joined(separator: " · ")
    }

    private var amountText: String {
        let amount = (entry.amount as Decimal?) ?? 0
        let absoluteAmount = amount < 0 ? -amount : amount
        let formatted = (absoluteAmount as NSDecimalNumber).stringValue
        switch kind {
        case .income: return "+$\(formatted)"
        case .expense: return "-$\(formatted)"
        case .transfer: return "$\(formatted)"
        case .balanceAdjustment:
            return amount >= 0 ? "+$\(formatted)" : "-$\(formatted)"
        }
    }

    private var amountColor: Color {
        switch kind {
        case .income: return LedgerTheme.primary
        case .expense: return LedgerTheme.coral
        case .transfer: return .secondary
        case .balanceAdjustment: return .blue
        }
    }

    var body: some View {
        LedgerCard {
            HStack(spacing: 14) {
                LedgerIconBadge(systemImage: kind.systemImage, tint: kind.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(amountText)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(amountColor)
            }
        }
    }
}

#Preview {
    NavigationStack { TransactionsView() }
        .environment(
            \.managedObjectContext,
            PersistenceController(inMemory: true).container.viewContext
        )
}
