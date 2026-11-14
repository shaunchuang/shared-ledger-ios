import CoreData
import Foundation
import WidgetKit

/// 這台裝置上、只屬於使用者自己的資料有多少。
struct LocalPersonalDataSummary: Equatable, Sendable {
    /// 共享群組裡「我是哪一位成員」的對應筆數。
    let identityMappingCount: Int
    /// 通知偏好或遞送紀錄有沒有被寫過。
    let hasNotificationData: Bool
    /// 記著幾個群組最後一次確認到的 iCloud 寫入權限。
    let cachedPermissionCount: Int
    var hasWidgetData: Bool = false
    var hasWatchData: Bool = false

    static let empty = LocalPersonalDataSummary(
        identityMappingCount: 0,
        hasNotificationData: false,
        cachedPermissionCount: 0
    )

    var isEmpty: Bool {
        identityMappingCount == 0 && !hasNotificationData && cachedPermissionCount == 0 && !hasWidgetData && !hasWatchData
    }
}

/// 刪除只存在這台裝置的個人資料。
///
/// 這是 P0-11 的另一半：群組刪除處理的是會同步出去、其他成員也看得到的帳務資料，
/// 這裡處理的是反過來的那一類——身分對應、通知偏好與遞送紀錄、CloudKit 權限快取，
/// 這些資料與小工具偏好／摘要都刻意不同步，因此必須在本機一併清除。
///
/// 帳務資料一筆都不動：這些全是可以重新推導的本機狀態，刪掉之後最壞的結果是共享
/// 群組要重新確認一次身分、通知偏好回到預設值。
@MainActor
struct LocalPersonalDataRepository {
    private let persistence: PersistenceController
    private let notificationStore: LedgerNotificationStore
    private let permissionCache: CloudPermissionCache
    private let widgetStore: LedgerWidgetStore
    private let watchDefaults: UserDefaults

    init(
        persistence: PersistenceController = .shared,
        notificationStore: LedgerNotificationStore = .standard,
        permissionCache: CloudPermissionCache? = nil,
        widgetStore: LedgerWidgetStore = .shared,
        watchDefaults: UserDefaults = .standard
    ) {
        self.persistence = persistence
        self.notificationStore = notificationStore
        self.permissionCache = permissionCache ?? persistence.cloudPermissionCache
        self.widgetStore = widgetStore
        self.watchDefaults = watchDefaults
    }

    func summary() -> LocalPersonalDataSummary {
        LocalPersonalDataSummary(
            identityMappingCount: identities().count,
            hasNotificationData: notificationStore.hasStoredData,
            cachedPermissionCount: permissionCache.storedGroupCount,
            hasWidgetData: widgetStore.hasStoredData,
            hasWatchData: !(watchDefaults.string(forKey: WatchLedgerService.selectionKey) ?? "").isEmpty
        )
    }

    /// Core Data 失敗時 rollback；本機偏好與小工具快取留到儲存成功後才清除。
    /// 檔案刪除失敗仍向呼叫端回報，不宣稱全部清除成功。
    func deleteAll() throws {
        let context = persistence.container.viewContext
        let stored = identities()
        if !stored.isEmpty {
            stored.forEach(context.delete)
            do {
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
        }

        notificationStore.reset()
        permissionCache.clearAll()
        try widgetStore.reset()
        watchDefaults.removeObject(forKey: WatchLedgerService.selectionKey)
        NotificationCenter.default.post(name: WatchLedgerService.selectionChanged, object: nil)
        WidgetCenter.shared.reloadTimelines(ofKind: LedgerWidgetStore.widgetKind)
    }

    /// 身分對應只寫在 private store，查詢也限定在那裡：shared store 裡不會有，
    /// 而未指定 store 的 fetch 會連別人的共享資料庫一起翻。
    private func identities() -> [LocalMemberIdentity] {
        let request = NSFetchRequest<LocalMemberIdentity>(entityName: "LocalMemberIdentity")
        request.affectedStores = [persistence.privateStore]
        return (try? persistence.container.viewContext.fetch(request)) ?? []
    }
}
