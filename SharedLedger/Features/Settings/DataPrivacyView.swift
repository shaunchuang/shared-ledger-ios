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

    /// 通知偏好被清掉之後要讓 App 層的協調器重新載入，否則設定頁的開關會停在舊值。
    @EnvironmentObject private var notifications: LedgerNotificationCoordinator

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \LedgerGroup.updatedAt, ascending: false)],
        animation: .default
    ) private var groups: FetchedResults<LedgerGroup>

    @State private var rows: [GroupDeletionRow] = []
    @State private var rowPendingDeletion: GroupDeletionRow?
    @State private var errorMessage: String?
    @State private var localData = LocalPersonalDataSummary.empty
    @State private var isConfirmingLocalDeletion = false

    var body: some View {
        Form {
            Section {
                Text(.privacyIntro)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if rows.isEmpty {
                Section {
                    Text(.privacyEmpty)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(rows) { row in
                    section(for: row)
                }
            }

            localDataSection
        }
        .navigationTitle(Text(.settingsRowDeleteTitle))
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
            Text(verbatim: deletionTitle),
            isPresented: deletionConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button(role: .destructive, action: deletePendingGroup) {
                Text(.privacyActionDeleteConfirm)
            }
            Button(role: .cancel) { rowPendingDeletion = nil } label: {
                Text(.commonActionCancel)
            }
        } message: {
            Text(verbatim: deletionMessage)
        }
        .alert(Text(.privacyErrorTitle), isPresented: errorBinding) {
            Button(role: .cancel) {} label: {
                Text(.commonActionOK)
            }
        } message: {
            Text(verbatim: errorMessage ?? LedgerStringKey.commonErrorRetryLater.string())
        }
        .confirmationDialog(
            Text(.privacyLocalConfirmTitle),
            isPresented: $isConfirmingLocalDeletion,
            titleVisibility: .visible
        ) {
            Button(role: .destructive, action: deleteLocalPersonalData) {
                Text(.privacyLocalConfirmAction)
            }
            Button(role: .cancel) {} label: {
                Text(.commonActionCancel)
            }
        } message: {
            Text(.privacyLocalConfirmMessage)
        }
    }

    /// 只存在這台裝置的個人資料。
    ///
    /// 和上面的群組刪除擺在同一個畫面，但講的是相反的一件事：群組刪除會影響其他成員，
    /// 這一段完全不會，所以文案要把「帳務資料不受影響」講清楚，否則使用者不敢按。
    private var localDataSection: some View {
        Section {
            if localData.isEmpty {
                Text(.privacyLocalEmpty)
                    .foregroundStyle(.secondary)
            } else {
                if localData.identityMappingCount > 0 {
                    Text(verbatim: LedgerStringKey.privacyLocalSummaryGroups.string(
                        arguments: [Int64(localData.identityMappingCount)]
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    isConfirmingLocalDeletion = true
                } label: {
                    Text(.privacyLocalAction)
                }
            }
        } header: {
            Text(.privacyLocalSection)
        } footer: {
            Text(.privacyLocalDescription)
        }
    }

    private func section(for row: GroupDeletionRow) -> some View {
        Section {
            LabeledContent {
                Text(verbatim: row.bookCount.formatted())
            } label: {
                Text(.privacyRowBooks)
            }
            LabeledContent {
                Text(verbatim: row.entryCount.formatted())
            } label: {
                Text(.privacyRowEntries)
            }
            LabeledContent {
                Text(verbatim: row.activeMemberCount.formatted())
            } label: {
                Text(.privacyRowMembers)
            }

            if let restriction = row.restriction {
                // 限制說明來自資料層的 `GroupError`，那一層還沒遷移。
                Text(verbatim: restriction.errorDescription
                    ?? LedgerStringKey.privacyRestrictionFallback.string())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Button(role: .destructive) {
                    rowPendingDeletion = row
                } label: {
                    Text(.privacyActionDelete)
                }
            }
        } header: {
            Text(verbatim: row.name)
        } footer: {
            Text(footerKey(for: row))
        }
    }

    private func footerKey(for row: GroupDeletionRow) -> LedgerStringKey {
        guard row.canDelete else { return .privacyFooterLeaveInstead }
        return row.affectsOtherMembers ? .privacyFooterAffectsOthers : .privacyFooterOwnGroup
    }

    private var deletionTitle: String {
        guard let rowPendingDeletion else {
            return LedgerStringKey.privacyConfirmTitleFallback.string()
        }
        return LedgerStringKey.privacyConfirmTitle.string(arguments: [rowPendingDeletion.name])
    }

    /// 三段各自是完整的句子：筆數、其他成員、無法復原。用哪幾段取決於這個群組還有
    /// 沒有別人，串接的順序在兩種語言剛好一致，但每一段都必須自己就是一句話。
    private var deletionMessage: String {
        guard let row = rowPendingDeletion else { return "" }
        var parts = [
            LedgerStringKey.privacyConfirmMessageCounts.string(
                arguments: [Int64(row.entryCount)]
            )
        ]
        if row.affectsOtherMembers {
            parts.append(
                LedgerStringKey.privacyConfirmMessageOthers.string(
                    arguments: [Int64(row.activeMemberCount - 1)]
                )
            )
        }
        parts.append(LedgerStringKey.privacyConfirmMessageIrreversible.string())
        return parts.joined(separator: " ")
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

    private func deleteLocalPersonalData() {
        do {
            try LocalPersonalDataRepository().deleteAll()
            notifications.reloadPreferences()
        } catch {
            errorMessage = error.localizedDescription
        }
        reloadRows()
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
                name: group.name ?? LedgerStringKey.commonPlaceholderUnnamedGroup.string(),
                bookCount: bookRepository.books(in: group, includeArchived: true).count,
                entryCount: (group.entries as? Set<LedgerEntry> ?? []).count,
                activeMemberCount: members.filter { $0.archivedAt == nil }.count,
                restriction: groupRepository.deletionRestriction(for: group)
            )
        }
        localData = LocalPersonalDataRepository().summary()
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
    let persistence = PersistenceController(inMemory: true)
    NavigationStack { DataPrivacyView() }
        .environment(\.managedObjectContext, persistence.container.viewContext)
        .environmentObject(LedgerNotificationCoordinator(persistence: persistence))
}
