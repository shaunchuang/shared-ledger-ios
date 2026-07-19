import CoreData
import SwiftUI

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
        return set.sorted { ($0.displayName ?? "") < ($1.displayName ?? "") }
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
                    TextField("0", text: $draft.amountText)
                        .keyboardType(.decimalPad)
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

                Section("付款人") {
                    Picker("誰付的", selection: $draft.payerMemberID) {
                        Text("請選擇").tag(UUID?.none)
                        ForEach(members, id: \.objectID) { member in
                            Text(member.displayName ?? "未命名成員").tag(member.id)
                        }
                    }
                }

                Section {
                    ForEach(members, id: \.objectID) { member in
                        Button {
                            toggleSplit(member)
                        } label: {
                            HStack {
                                Text(member.displayName ?? "未命名成員")
                                    .foregroundStyle(.primary)
                                Spacer()
                                if let id = member.id, draft.splitMemberIDs.contains(id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(LedgerTheme.primary)
                                } else {
                                    Image(systemName: "circle")
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("平分對象")
                } footer: {
                    Text("金額會平均分攤給勾選的成員。")
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
        if draft.payerMemberID == nil {
            draft.payerMemberID = members.first(where: { $0.isCurrentUser })?.id ?? members.first?.id
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
