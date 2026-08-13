import CoreData
import Foundation

extension AuditEvent {
    /// 記下這件事是誰做的。
    ///
    /// 名稱與識別碼要一起寫，因為兩者回答的是不同問題：
    ///
    /// - `actorMemberID` 回答「這是不是目前這位使用者做的」。通知靠它決定要不要跳出來，
    ///   而在此之前這個判斷只能拿顯示名稱比對——同一個群組裡有兩位同名成員時，A 記一筆
    ///   帳會被當成 B 自己的操作而不通知 B，B 記帳則反過來讓 A 收不到；成員改名之後，
    ///   使用者會開始收到自己每一筆操作的通知。
    /// - `actorDisplayName` 回答「當時是誰」。成員退出群組後 `actorMemberID` 可能已經
    ///   指不到任何人，那時稽核紀錄上還讀得懂的只剩這個當下的名稱快照。
    ///
    /// V10 之前的事件、以及還沒更新的裝置寫出來的事件，`actorMemberID` 會是 `nil`；
    /// 判斷端要能退回名稱比對，不能把「沒有識別碼」當成「不是我做的」。
    func recordActor(
        _ member: Member?,
        fallbackName: @autoclosure () -> String = LedgerStringKey.defaultMemberCurrentUser.string()
    ) {
        actorDisplayName = member?.displayName ?? fallbackName()
        actorMemberID = member?.id
    }
}
