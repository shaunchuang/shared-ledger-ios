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
            return LedgerStringKey.participantBadgeShareUnavailable.string()
        case .unmapped:
            return LedgerStringKey.participantBadgeUnmapped.string()
        case .participantMissing:
            return LedgerStringKey.participantBadgeParticipantMissing.string()
        case let .mapped(canWrite, isShareOwner, isAccepted):
            if !isAccepted { return LedgerStringKey.participantBadgeNotAccepted.string() }
            if isShareOwner { return LedgerStringKey.participantBadgeShareOwner.string() }
            return canWrite
                ? LedgerStringKey.participantBadgeWritable.string()
                : LedgerStringKey.participantBadgeReadOnly.string()
        }
    }

    /// Longer explanation for the detail line under member management.
    var explanation: String? {
        switch self {
        case .notShared:
            return nil
        case .shareUnavailable:
            return LedgerStringKey.participantExplanationShareUnavailable.string()
        case .unmapped:
            return LedgerStringKey.participantExplanationUnmapped.string()
        case .participantMissing:
            return LedgerStringKey.participantExplanationParticipantMissing.string()
        case let .mapped(canWrite, isShareOwner, isAccepted):
            if !isAccepted {
                return LedgerStringKey.participantExplanationNotAccepted.string()
            }
            if isShareOwner {
                return LedgerStringKey.participantExplanationShareOwner.string()
            }
            return canWrite
                ? LedgerStringKey.participantExplanationWritable.string()
                : LedgerStringKey.participantExplanationReadOnly.string()
        }
    }
}
