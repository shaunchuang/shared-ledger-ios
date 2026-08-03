import Foundation

/// 通知偏好與遞送紀錄的存放處。
///
/// 刻意放在 `UserDefaults` 而不是 Core Data：這兩份資料都只屬於這台裝置。要收哪些
/// 通知是裝置的偏好，不該同步到別人的手機，也不該因為換到 iPad 就把已經在 iPhone
/// 上響過的通知再響一次。跟 `CloudPermissionCache` 一樣接受注入的 `UserDefaults`，
/// 測試才不會污染真的偏好設定。
struct LedgerNotificationStore {
    static let standard = LedgerNotificationStore()

    private enum Key {
        static let preferences = "notification.preferences"
        static let digest = "notification.digest"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadPreferences() -> LedgerNotificationPreferences {
        decode(LedgerNotificationPreferences.self, forKey: Key.preferences) ?? .default
    }

    func save(_ preferences: LedgerNotificationPreferences) {
        encode(preferences, forKey: Key.preferences)
    }

    func loadDigest() -> LedgerNotificationDigest {
        decode(LedgerNotificationDigest.self, forKey: Key.digest) ?? LedgerNotificationDigest()
    }

    func save(_ digest: LedgerNotificationDigest) {
        encode(digest, forKey: Key.digest)
    }

    /// 使用者調整過偏好，或 App 已經記下遞送基準。兩者都是刪除本機個人資料時要交代的東西。
    var hasStoredData: Bool {
        defaults.data(forKey: Key.preferences) != nil || defaults.data(forKey: Key.digest) != nil
    }

    /// 回到「從沒設定過」的狀態：偏好回到預設值，遞送紀錄清空。
    ///
    /// 清掉紀錄之後下一輪會重新取基準而不是補送舊事件，這正是刪除資料時該有的行為：
    /// 使用者要的是不留痕跡，不是清完之後被過去一天的通知洗版。
    func reset() {
        defaults.removeObject(forKey: Key.preferences)
        defaults.removeObject(forKey: Key.digest)
    }

    /// 解不開就當成沒設定過。
    ///
    /// 這兩份資料都是可以重新推導的偏好與紀錄，為了一筆壞掉的 JSON 讓通知整組壞掉
    /// （或更糟，讓 App 崩潰）並不划算；最壞的情況只是回到預設值並重新取一次基準。
    private func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func encode<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
