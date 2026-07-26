import Foundation

/// How an App member relates to the live `CKShare` participant list.
///
/// The App member and the CloudKit participant are separate identities that have to
/// be correlated explicitly, and the correlation can legitimately be incomplete — the
/// share may not have synced, or a member may never have claimed a seat. Member
/// management shows this so the state is visible instead of inferred, and so the
/// two-Apple-Account validation matrix can be checked on device rather than through a
/// debugger.
enum CloudParticipantStatus: Equatable {
    /// The group is not shared through CloudKit at all.
    case notShared
    /// The share metadata has not reached this device yet.
    case shareUnavailable
    /// The member has no participant identity bound yet.
    case unmapped
    /// The member is bound to a participant that is no longer in the share, which is
    /// what a removed or replaced participant looks like.
    case participantMissing
    /// The member resolves to a participant currently in the share.
    case mapped(canWrite: Bool, isShareOwner: Bool, isAccepted: Bool)

    var isMapped: Bool {
        if case .mapped = self { return true }
        return false
    }

    /// Short label for a member row. `nil` when there is nothing worth showing —
    /// an unshared group has no participants to report on.
    var badgeText: String? {
        switch self {
        case .notShared:
            return nil
        case .shareUnavailable:
            return "共享未同步"
        case .unmapped:
            return "未對應"
        case .participantMissing:
            return "參與者已不存在"
        case let .mapped(canWrite, isShareOwner, isAccepted):
            if !isAccepted { return "邀請未接受" }
            if isShareOwner { return "共享擁有者" }
            return canWrite ? "可編輯" : "唯讀"
        }
    }

    /// Longer explanation for the detail line under member management.
    var explanation: String? {
        switch self {
        case .notShared:
            return nil
        case .shareUnavailable:
            return "尚未取得這個群組的 iCloud 共享資料，請連上網路等待同步完成。"
        case .unmapped:
            return "這位成員還沒有對應到 iCloud 共享參與者。對方接受邀請並確認身分後才會建立對應。"
        case .participantMissing:
            return "這位成員原本對應的 iCloud 共享參與者已不在共享名單中，可能已被移除或自行退出。"
        case let .mapped(canWrite, isShareOwner, isAccepted):
            if !isAccepted {
                return "已建立對應，但對方尚未接受 iCloud 共享邀請。"
            }
            if isShareOwner {
                return "對應到 iCloud 共享的擁有者，具備完整寫入權限。"
            }
            return canWrite
                ? "對應到可讀寫的 iCloud 共享參與者。"
                : "對應到唯讀的 iCloud 共享參與者，在 App 中的寫入權限會一併降為唯讀。"
        }
    }
}
