import CoreData
import Foundation

/// 交易明細的唯一讀取入口。
///
/// 規則寫在 `EntryRevision`；這裡只負責把 Core Data 的關聯換成純值再交給它。
/// 所有會用到付款或分攤的地方——結算、搜尋、匯出、交易詳情、編輯表單——都必須經過
/// 這幾個屬性，不再直接讀 `entry.payments` 或 `entry.splits`：只要有一個地方漏掉，
/// 那個畫面就會把兩次編輯的明細加在一起。
extension LedgerEntry {
    var livePayments: [EntryPayment] {
        EntryRevision.live(
            storedPayments,
            of: revisionID,
            revision: { $0.entryRevisionID }
        )
    }

    var liveSplits: [EntrySplit] {
        EntryRevision.live(
            storedSplits,
            of: revisionID,
            revision: { $0.entryRevisionID }
        )
    }

    /// 被另一次編輯取代、已經不算數的明細。
    ///
    /// 留著不刪是因為刪除本身也會同步出去：CloudKit 匯入交易與明細的順序沒有保證，
    /// 落選的那組在對方裝置上可能還是當選的那組。清除交給
    /// `EntryRepository.discardSupersededChildren`，它只處理已經穩定下來的交易。
    var supersededPayments: [EntryPayment] {
        EntryRevision.superseded(
            storedPayments,
            of: revisionID,
            revision: { $0.entryRevisionID }
        )
    }

    var supersededSplits: [EntrySplit] {
        EntryRevision.superseded(
            storedSplits,
            of: revisionID,
            revision: { $0.entryRevisionID }
        )
    }

    var supersededChildCount: Int {
        supersededPayments.count + supersededSplits.count
    }

    /// 已標記刪除但還沒 save 的物件仍留在關聯裡，先濾掉，免得剛被取代的明細在同一次
    /// 儲存中又被算進來。
    private var storedPayments: [EntryPayment] {
        (payments as? Set<EntryPayment> ?? []).filter { !$0.isDeleted }
    }

    private var storedSplits: [EntrySplit] {
        (splits as? Set<EntrySplit> ?? []).filter { !$0.isDeleted }
    }

    var entryKind: EntryKind {
        EntryKind(rawValue: kind ?? "") ?? .expense
    }

    /// - Parameter isVoided: 由呼叫端提供，因為作廢狀態存在群組的稽核紀錄裡，
    ///   逐筆交易去查會把整份稽核紀錄讀進記憶體。
    func consistency(isVoided: Bool) -> EntryConsistency {
        EntryConsistency.evaluate(
            kind: entryKind,
            amount: (amount as Decimal?) ?? 0,
            paymentAmounts: livePayments.map { ($0.amount as Decimal?) ?? 0 },
            splitAmounts: liveSplits.map { ($0.amount as Decimal?) ?? 0 },
            currencyCode: LedgerCurrency.normalizedCode(group?.currencyCode),
            isVoided: isVoided
        )
    }
}
