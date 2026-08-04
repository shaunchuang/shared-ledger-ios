import CoreData
import Foundation

/// 一筆使用者需要知道的交易衝突。
struct EntryConflict: Identifiable, Equatable {
    enum Reason: Equatable {
        /// 同一筆交易被兩台裝置各自編輯過。App 已經只採用其中一版，另一版的付款與
        /// 分攤還躺在資料裡等著被清掉。帳務數字不受影響。
        case superseded(rowCount: Int)
        /// 付款或分攤合計與交易金額對不起來。這種交易不會進入結算，要由使用者重新編輯。
        case mismatched
        /// 明細遲遲沒有同步過來。剛匯入的交易短暫如此是正常的，這裡只列出已經等很久的。
        case missingDetails
    }

    let entry: LedgerEntry
    let reason: Reason
    /// 這台裝置在該群組有沒有寫入權限，決定「清除」動作能不能按。
    let isWritable: Bool

    var id: NSManagedObjectID { entry.objectID }

    /// 帳務數字有沒有真的受影響。`superseded` 只是殘留資料，不影響任何計算。
    var affectsBalances: Bool {
        switch reason {
        case .superseded: return false
        case .mismatched, .missingDetails: return true
        }
    }

    var supersededRowCount: Int {
        if case let .superseded(rowCount) = reason { return rowCount }
        return entry.supersededChildCount
    }
}

/// 找出付款與分攤明細出問題的交易。
///
/// 這是 P0-10「資料衝突要有清楚且可恢復的使用者體驗」的資料來源。判斷本身全部在
/// `EntryConsistency` 與 `EntryRevision` 這兩個純值型別裡，這裡只負責把 Core Data
/// 的內容餵進去，並把每個群組的權限與作廢清單各查一次而不是每筆交易查一次。
@MainActor
struct EntryConflictScanner {
    private let persistence: PersistenceController

    init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    func conflicts(now: Date = Date(), limit: Int = 50) -> [EntryConflict] {
        let context = persistence.container.viewContext
        let request = NSFetchRequest<LedgerEntry>(entityName: "LedgerEntry")
        // 轉帳與餘額調整沒有付款與分攤明細，不可能有這種衝突。
        request.predicate = NSPredicate(
            format: "kind IN %@",
            [EntryKind.expense.rawValue, EntryKind.income.rawValue]
        )
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \LedgerEntry.updatedAt, ascending: false)
        ]
        request.relationshipKeyPathsForPrefetching = ["payments", "splits"]
        request.fetchBatchSize = 200
        guard let entries = try? context.fetch(request) else { return [] }

        let settled = now.addingTimeInterval(-EntryRepository.supersededChildRetention)
        let entryRepository = EntryRepository(persistence: persistence)
        let permissions = EffectivePermissionRepository(persistence: persistence)
        var voidedIDsByGroup: [NSManagedObjectID: Set<UUID>] = [:]
        var writableByGroup: [NSManagedObjectID: Bool] = [:]
        var conflicts: [EntryConflict] = []

        for entry in entries {
            guard conflicts.count < limit else { break }
            guard let group = entry.group else { continue }

            if voidedIDsByGroup[group.objectID] == nil {
                voidedIDsByGroup[group.objectID] = entryRepository.voidedEntryIDs(in: group)
            }
            let voidedIDs = voidedIDsByGroup[group.objectID] ?? []
            let isVoided = entry.id.map { voidedIDs.contains($0) } ?? false
            guard let reason = reason(
                for: entry,
                isVoided: isVoided,
                settledBefore: settled
            ) else { continue }

            if writableByGroup[group.objectID] == nil {
                writableByGroup[group.objectID] = permissions
                    .permission(in: group)
                    .canEditTransactions
            }
            let isWritable = writableByGroup[group.objectID] ?? false
            conflicts.append(
                EntryConflict(entry: entry, reason: reason, isWritable: isWritable)
            )
        }

        return conflicts
    }

    /// 沒問題的交易回傳 `nil`。
    private func reason(
        for entry: LedgerEntry,
        isVoided: Bool,
        settledBefore settled: Date
    ) -> EntryConflict.Reason? {
        // 作廢交易的金額被歸零、明細保留原值，拿去比對必然對不上，`consistency`
        // 已經把它排除；殘留的落選明細仍然值得清，所以作廢交易只看這一項。
        let supersededCount = entry.supersededChildCount

        switch entry.consistency(isVoided: isVoided) {
        case .mismatched:
            return .mismatched
        case .awaitingDetails:
            // 匯入還沒完成是正常狀態，等超過保留期限才算真的卡住。
            guard let updatedAt = entry.updatedAt, updatedAt < settled else { return nil }
            return .missingDetails
        case .balanced, .notApplicable:
            return supersededCount > 0 ? .superseded(rowCount: supersededCount) : nil
        }
    }
}
