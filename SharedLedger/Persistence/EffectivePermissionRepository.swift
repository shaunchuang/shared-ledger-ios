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

/// What the caller is about to do, so a restriction can be derived from an
/// `EffectivePermission` that has already been resolved.
///
/// Resolving a permission makes a synchronous `fetchShares` call for a shared group,
/// so a screen that needs both the role and the reason an action is unavailable must
/// be able to pay for that once rather than per question it asks.
enum PermissionRequirement {
    case transactionWrite
    case ledgerSettings
    case memberManagement

    func isSatisfied(by permission: EffectivePermission) -> Bool {
        switch self {
        case .transactionWrite: return permission.canEditTransactions
        case .ledgerSettings: return permission.canManageLedgerSettings
        case .memberManagement: return permission.canManageMembers
        }
    }
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
            return LedgerStringKey.errorPermissionRole.string(arguments: [role.displayName])
        case .cloudReadOnly:
            return LedgerStringKey.errorPermissionReadOnlyShare.string()
        case .cloudPermissionUnknown:
            return LedgerStringKey.errorPermissionAwaitingShare.string()
        case .cloudParticipantMismatch:
            return LedgerStringKey.errorPermissionMismatchedParticipant.string()
        case .missingCurrentMember:
            return LedgerStringKey.errorPermissionMissingCurrentMember.string()
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

    private static let keyPrefix = "cloudWritePermission."

    private func key(for group: LedgerGroup) -> String? {
        guard let id = group.id else { return nil }
        return Self.keyPrefix + id.uuidString
    }

    /// 這台裝置目前記著多少個群組的權限。刪除本機個人資料的畫面要說出數量，
    /// 不能只說「有一些」。
    var storedGroupCount: Int {
        storedKeys.count
    }

    func clearAll() {
        storedKeys.forEach(defaults.removeObject(forKey:))
    }

    private var storedKeys: [String] {
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(Self.keyPrefix) }
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

    /// Drops the cached CloudKit write permission for a group that is going away.
    /// The cache is keyed by group id in `UserDefaults`, so without this a deleted
    /// group leaves an entry behind for an id nothing can look up again.
    func forgetCachedPermission(for group: LedgerGroup) {
        cache.clear(for: group)
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
        restriction(.transactionWrite, for: permission(in: group))
    }

    func ledgerSettingsRestriction(in group: LedgerGroup) -> PermissionError? {
        restriction(.ledgerSettings, for: permission(in: group))
    }

    func memberManagementRestriction(in group: LedgerGroup) -> PermissionError? {
        restriction(.memberManagement, for: permission(in: group))
    }

    /// Why a requirement is unmet by an already-resolved permission, or `nil` when it
    /// is met. Callers that need several answers about the same group resolve the
    /// permission once and ask here, instead of re-resolving it per question.
    func restriction(
        _ requirement: PermissionRequirement,
        for permission: EffectivePermission
    ) -> PermissionError? {
        guard !requirement.isSatisfied(by: permission) else { return nil }

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
