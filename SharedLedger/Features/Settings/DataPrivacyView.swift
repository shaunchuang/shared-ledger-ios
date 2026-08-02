import CoreData
import SwiftUI

/// 一個群組在刪除畫面上的狀態。
///
/// 快取而不是在 `body` 裡即時算：解析刪除權限要查一次私有 store 的身分對應，
/// 而這個畫面每個群組都要問一次，放進 `body` 等於每次 render 都重跑一輪。
private struct GroupDeletionRow: Identifiable {
    let id: NSManagedObjectID
    let group: LedgerGroup
    let name: String
    let bookCount: Int
    let entryCount: Int
    let activeMemberCount: Int
    let restriction: GroupRepository.GroupError?

    /// 還有別的有效成員，代表刪除的影響會擴散出去，警告文字必須不同。
    var affectsOtherMembers: Bool { activeMemberCount > 1 }
    var canDelete: Bool { restriction == nil }
}

/// 資料刪除。
///
/// 刪除的後果依群組來自哪個 store 而完全不同，畫面必須先說清楚再讓使用者按下去：
/// 自己建立的群組刪掉就是連同所有參與者的副本一起消失，別人分享給你的群組則根本
/// 不歸這台裝置處置，只能退出。
struct DataPrivacyView: View {
    @Environment(\.managedObjectContext) private var context

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \LedgerGroup.updatedAt, ascending: false)],
        animation: .default
    ) private var groups: FetchedResults<LedgerGroup>

    @State private var rows: [GroupDeletionRow] = []
    @State private var rowPendingDeletion: GroupDeletionRow?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Text("刪除會移除資料本身，不只是隱藏。刪除前建議先到「匯出資料」保留一份 CSV。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if rows.isEmpty {
                Section {
                    Text("目前沒有任何群組資料。")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(rows) { row in
                    section(for: row)
                }
            }
        }
        .navigationTitle("刪除資料")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reloadRows)
        .onChange(of: groups.count) { _, _ in reloadRows() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .NSManagedObjectContextObjectsDidChange,
                object: context
            )
        ) { notification in
            guard ContextChangeObserver.touches(
                notification,
                .groupPermissions,
                .accountBalances
            ) else { return }
            reloadRows()
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: deletionConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("刪除群組與所有帳務", role: .destructive, action: deletePendingGroup)
            Button("取消", role: .cancel) { rowPendingDeletion = nil }
        } message: {
            Text(deletionMessage)
        }
        .alert("無法刪除", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "請稍後再試。")
        }
    }

    private func section(for row: GroupDeletionRow) -> some View {
        Section {
            LabeledContent("帳本", value: "\(row.bookCount)")
            LabeledContent("交易", value: "\(row.entryCount)")
            LabeledContent("成員", value: "\(row.activeMemberCount)")

            if let restriction = row.restriction {
                Text(restriction.errorDescription ?? "這個群組無法在這台裝置刪除。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Button("刪除這個群組", role: .destructive) {
                    rowPendingDeletion = row
                }
            }
        } header: {
            Text(row.name)
        } footer: {
            Text(footerText(for: row))
        }
    }

    private func footerText(for row: GroupDeletionRow) -> String {
        guard row.canDelete else {
            return "退出群組的入口在「群組管理」→ 選擇這個群組 → 成員管理。退出後你的歷史帳務仍會保留在群組裡，供其他成員對帳。"
        }
        if row.affectsOtherMembers {
            return "這個群組已經有其他成員。資料存放在你的 iCloud，刪除會讓所有已加入的成員同時失去這個群組的全部帳務，且無法復原。"
        }
        return "刪除會移除這個群組的所有帳本、帳戶、分類、交易、結算與稽核紀錄，且無法復原。"
    }

    private var deletionTitle: String {
        guard let rowPendingDeletion else { return "確定要刪除？" }
        return "確定要刪除「\(rowPendingDeletion.name)」？"
    }

    private var deletionMessage: String {
        guard let row = rowPendingDeletion else { return "" }
        let counts = "將刪除 \(row.entryCount) 筆交易與相關的帳本、帳戶、分類與結算紀錄。"
        guard row.affectsOtherMembers else { return counts + "此操作無法復原。" }
        return counts + "其他 \(row.activeMemberCount - 1) 位成員也會同時失去這個群組的資料。此操作無法復原。"
    }

    private var deletionConfirmationBinding: Binding<Bool> {
        Binding(
            get: { rowPendingDeletion != nil },
            set: { if !$0 { rowPendingDeletion = nil } }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func reloadRows() {
        let groupRepository = GroupRepository()
        let bookRepository = BookRepository()
        rows = groups.compactMap { group in
            guard !group.isDeleted else { return nil }
            let members = group.members as? Set<Member> ?? []
            return GroupDeletionRow(
                id: group.objectID,
                group: group,
                name: group.name ?? "未命名群組",
                bookCount: bookRepository.books(in: group, includeArchived: true).count,
                entryCount: (group.entries as? Set<LedgerEntry> ?? []).count,
                activeMemberCount: members.filter { $0.archivedAt == nil }.count,
                restriction: groupRepository.deletionRestriction(for: group)
            )
        }
    }

    private func deletePendingGroup() {
        guard let row = rowPendingDeletion else { return }
        rowPendingDeletion = nil
        do {
            try GroupRepository().deleteGroup(row.group)
        } catch {
            errorMessage = error.localizedDescription
        }
        reloadRows()
    }
}

#Preview {
    NavigationStack { DataPrivacyView() }
        .environment(
            \.managedObjectContext,
            PersistenceController(inMemory: true).container.viewContext
        )
}
