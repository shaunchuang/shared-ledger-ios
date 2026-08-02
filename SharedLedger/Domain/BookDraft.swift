import Foundation

struct BookDraft: Equatable, Sendable {
    /// 建立群組時寫進 Core Data 的帳本名稱。寫進去之後就是使用者自己的資料，
    /// 之後改名或切換語言都不會回頭動它。
    static var defaultName: String { LedgerStringKey.defaultBookName.string() }

    var name = ""

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canCreate: Bool {
        !trimmedName.isEmpty
    }
}
