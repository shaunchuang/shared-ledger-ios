import CoreData
import Foundation

/// 這台裝置上、只屬於使用者自己的資料有多少。
struct LocalPersonalDataSummary: Equatable, Sendable {
    /// 共享群組裡「我是哪一位成員」的對應筆數。
    let identityMappingCount: Int
    /// 通知偏好或遞送紀錄有沒有被寫過。
    let hasNotificationData: Bool
    /// 記著幾個群組最後一次確認到的 iCloud 寫入權限。
    let cachedPermissionCount: Int

    static let empty = LocalPersonalDataSummary(
        identityMappingCount: 0,
        hasNotificationData: false,
        cachedPermissionCount: 0
    )

    var isEmpty: Bool {
        identityMappingCount == 0 && !hasNotificationData && cachedPermissionCount == 0
    }
}

/// 刪除只存在這台裝置的個人資料。
///
/// 這是 P0-11 的另一半：群組刪除處理的是會同步出去、其他成員也看得到的帳務資料，
/// 這裡處理的是反過來的那一類——身分對應、通知偏好與遞送紀錄、CloudKit 權限快取，
/// 三者都刻意不同步，因此也不會有任何一台其他裝置替使用者清掉。
///
/// 帳務資料一筆都不動：這些全是可以重新推導的本機狀態，刪掉之後最壞的結果是共享
/// 群組要重新確認一次身分、通知偏好回到預設值。
@MainActor
struct LocalPersonalDataRepository {
    private let persistence: PersistenceController
    private let notificationStore: LedgerNotificationStore
    private let permissionCache: CloudPermissionCache

    init(
        persistence: PersistenceController = .shared,
        notificationStore: LedgerNotificationStore = .standard,
        permissionCache: CloudPermissionCache? = nil
    ) {
        self.persistence = persistence
        self.notificationStore = notificationStore
        self.permissionCache = permissionCache ?? persistence.cloudPermissionCache
    }

    func summary() -> LocalPersonalDataSummary {
        LocalPersonalDataSummary(
            identityMappingCount: identities().count,
            hasNotificationData: notificationStore.hasStoredData,
            cachedPermissionCount: permissionCache.storedGroupCount
        )
    }

    /// - Note: 三份資料一起清。Core Data 那一份失敗時整筆 rollback 並往外丟，
    ///   `UserDefaults` 的兩份留到 Core Data 成功之後才動，避免出現「通知偏好清掉了、
    ///   身分對應還在」這種一半的狀態。
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
    }

    /// 身分對應只寫在 private store，查詢也限定在那裡：shared store 裡不會有，
    /// 而未指定 store 的 fetch 會連別人的共享資料庫一起翻。
    private func identities() -> [LocalMemberIdentity] {
        let request = NSFetchRequest<LocalMemberIdentity>(entityName: "LocalMemberIdentity")
        request.affectedStores = [persistence.privateStore]
        return (try? persistence.container.viewContext.fetch(request)) ?? []
    }
}
