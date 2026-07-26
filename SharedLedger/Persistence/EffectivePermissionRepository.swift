import CloudKit
import CoreData
import Foundation

/// The permission the App is willing to act on for the current user in a group.
///
/// CloudKit is the only server-enforced boundary: a read-only `CKShare.Participant`
/// has its writes rejected by the server no matter what the App believes. The App
/// role is therefore clamped by the participant permission — it can be reduced by
/// CloudKit but never raised above it.
struct EffectivePermission: Equatable {
    enum Source: Equatable {
        /// The group is not shared through CloudKit, so only the App role applies.
        case localOnly
        /// Resolved from the `CKShare` participant currently held in the local store.
        case cloudParticipant
        /// The share is not available on this device yet, so the last permission
        /// successfully resolved for this group is being reused.
        case cachedCloudParticipant
        /// There is no confirmed App member for the current Apple Account.
        case missingIdentity
        /// A shared group whose participant permission has never been resolved on
        /// this device, so there is nothing safe to fall back to.
        case cloudPermissionUnknown
        /// The App member is bound to a different `CKShare` participant than the one
        /// operating this device.
        case participantMismatch
    }

    /// `nil` means the current user has no usable role at all and every mutation
    /// must be refused.
    let role: MemberRole?
    let source: Source
    /// True when the App role was reduced because CloudKit only grants read access.
    /// It distinguishes "you are read-only in the share" from "your App role is
    /// viewer", which need different explanations.
    let isClampedByCloud: Bool

    init(role: MemberRole?, source: Source, isClampedByCloud: Bool = false) {
        self.role = role
        self.source = source
        self.isClampedByCloud = isClampedByCloud
    }

    static let missingIdentity = EffectivePermission(role: nil, source: .missingIdentity)
    static let permissionUnknown = EffectivePermission(role: nil, source: .cloudPermissionUnknown)
    static let participantMismatch = EffectivePermission(role: nil, source: .participantMismatch)

    var canEditTransactions: Bool { role?.canEditTransactions == true }
    var canManageMembers: Bool { role?.canManageMembers == true }
    var canManageLedgerSettings: Bool { role?.canManageLedgerSettings == true }

    /// True when the App knows the user is present but CloudKit only grants reads.
    var isReadOnly: Bool { role == .viewer }
}

enum PermissionError: LocalizedError, Equatable {
    /// The current user has a role, but that role does not allow this action.
    case insufficientRole(MemberRole)
    /// CloudKit only grants read access, so no App role can authorise a write.
    case cloudReadOnly
    /// The share permission has never been resolved on this device, so writing
    /// could silently produce changes CloudKit will later reject.
    case cloudPermissionUnknown
    /// The App member is bound to a different CloudKit participant.
    case cloudParticipantMismatch
    /// There is no confirmed App member for the current Apple Account.
    case missingCurrentMember

    var errorDescription: String? {
        switch self {
        case let .insufficientRole(role):
            return "目前的群組角色是「\(role.displayName)」，沒有執行這項操作的權限。"
        case .cloudReadOnly:
            return "你在這個 iCloud 共享中的權限是唯讀，無法新增或修改共享資料。"
        case .cloudPermissionUnknown:
            return "尚未取得你在這個 iCloud 共享中的權限，暫時無法寫入。請連上網路等待共享同步完成後再試。"
        case .cloudParticipantMismatch:
            return "這個 App 成員對應到另一位 iCloud 共享參與者，為避免誤用他人身分寫入，已停止這項操作。"
        case .missingCurrentMember:
            return "尚未確認你在這個群組中的成員身分，無法執行這項操作。"
        }
    }
}

/// Remembers the last CloudKit write permission successfully resolved for a group
/// so an offline device keeps working with what it already knew instead of either
/// guessing a permission or blocking every write.
///
/// This is device-local on purpose: it is a cache of a CloudKit fact, never a
/// source of truth, and it must not sync between devices.
struct CloudPermissionCache {
    static let standard = CloudPermissionCache()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(for group: LedgerGroup) -> String? {
        guard let id = group.id else { return nil }
        return "cloudWritePermission.\(id.uuidString)"
    }

    func lastKnownWritePermission(for group: LedgerGroup) -> Bool? {
        guard let key = key(for: group) else { return nil }
        return defaults.object(forKey: key) as? Bool
    }

    func store(_ canWrite: Bool, for group: LedgerGroup) {
        guard let key = key(for: group) else { return }
        defaults.set(canWrite, forKey: key)
    }

    func clear(for group: LedgerGroup) {
        guard let key = key(for: group) else { return }
        defaults.removeObject(forKey: key)
    }
}

@MainActor
struct EffectivePermissionRepository {
    typealias ShareResolver = (LedgerGroup) throws -> CKShare?

    private let persistence: PersistenceController
    private let cache: CloudPermissionCache
    private let shareResolver: ShareResolver?

    init(
        persistence: PersistenceController = .shared,
        cache: CloudPermissionCache? = nil,
        shareResolver: ShareResolver? = nil
    ) {
        self.persistence = persistence
        self.cache = cache ?? persistence.cloudPermissionCache
        self.shareResolver = shareResolver
    }

    func permission(in group: LedgerGroup) -> EffectivePermission {
        guard let member = CurrentMemberIdentityRepository(persistence: persistence)
            .currentMember(in: group),
              let rawRole = member.role,
              let appRole = MemberRole(rawValue: rawRole)
        else { return .missingIdentity }

        guard persistence.store(for: group) !== persistence.privateStore else {
            // Groups in the private store belong to this Apple Account. CloudKit
            // always grants write access to your own private database — a read-only
            // participant's group lives in the shared store — so there is no ceiling
            // to apply. Drop any stale cache so a later re-share cannot inherit an
            // old permission.
            cache.clear(for: group)
            return EffectivePermission(role: appRole, source: .localOnly)
        }

        let share: CKShare?
        do {
            share = try resolveShare(for: group)
        } catch {
            // The local share metadata could not be read at all. Fall back to what
            // this device already knew rather than assuming either extreme.
            return cachedPermission(for: appRole, in: group)
        }

        guard let share,
              let participant = share.currentUserParticipant,
              participant.acceptanceStatus == .accepted
        else { return cachedPermission(for: appRole, in: group) }

        if let boundParticipantID = member.cloudParticipantID,
           boundParticipantID != participant.participantID {
            // This App member belongs to a different participant. Never fall back to
            // the cache here: the mapping itself is wrong, not merely unavailable.
            return .participantMismatch
        }

        let canWrite = participant.role == .owner || participant.permission == .readWrite
        cache.store(canWrite, for: group)
        return EffectivePermission(
            role: clamped(appRole, canWrite: canWrite),
            source: .cloudParticipant,
            isClampedByCloud: !canWrite
        )
    }

    // MARK: - Enforcement

    func requireTransactionWrite(in group: LedgerGroup) throws {
        if let restriction = transactionWriteRestriction(in: group) { throw restriction }
    }

    func requireLedgerSettingsManagement(in group: LedgerGroup) throws {
        if let restriction = ledgerSettingsRestriction(in: group) { throw restriction }
    }

    func requireMemberManagement(in group: LedgerGroup) throws {
        if let restriction = memberManagementRestriction(in: group) { throw restriction }
    }

    /// Why transaction writes are unavailable, or `nil` when they are allowed.
    /// Views use this to hide or explain a write action instead of letting the user
    /// reach a form that fails on save; the `require…` calls throw the same value, so
    /// the UI and the repositories can never disagree.
    func transactionWriteRestriction(in group: LedgerGroup) -> PermissionError? {
        restriction(in: group) { $0.canEditTransactions }
    }

    func ledgerSettingsRestriction(in group: LedgerGroup) -> PermissionError? {
        restriction(in: group) { $0.canManageLedgerSettings }
    }

    func memberManagementRestriction(in group: LedgerGroup) -> PermissionError? {
        restriction(in: group) { $0.canManageMembers }
    }

    private func restriction(
        in group: LedgerGroup,
        _ isAllowed: (EffectivePermission) -> Bool
    ) -> PermissionError? {
        let permission = permission(in: group)
        guard !isAllowed(permission) else { return nil }

        switch permission.source {
        case .missingIdentity:
            return .missingCurrentMember
        case .cloudPermissionUnknown:
            return .cloudPermissionUnknown
        case .participantMismatch:
            return .cloudParticipantMismatch
        case .localOnly, .cloudParticipant, .cachedCloudParticipant:
            guard let role = permission.role else { return .missingCurrentMember }
            // A viewer produced by a CloudKit clamp is a read-only participant, which
            // is a different problem from an App role that was viewer to begin with.
            if permission.isClampedByCloud { return .cloudReadOnly }
            return .insufficientRole(role)
        }
    }

    // MARK: - Helpers

    private func clamped(_ role: MemberRole, canWrite: Bool) -> MemberRole {
        canWrite ? role : .viewer
    }

    private func cachedPermission(
        for appRole: MemberRole,
        in group: LedgerGroup
    ) -> EffectivePermission {
        guard let canWrite = cache.lastKnownWritePermission(for: group) else {
            return .permissionUnknown
        }
        return EffectivePermission(
            role: clamped(appRole, canWrite: canWrite),
            source: .cachedCloudParticipant,
            isClampedByCloud: !canWrite
        )
    }

    private func resolveShare(for group: LedgerGroup) throws -> CKShare? {
        if let shareResolver { return try shareResolver(group) }
        return try persistence.existingShare(for: group.objectID)
    }
}
