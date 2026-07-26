import CloudKit
import CoreData
import Foundation

@MainActor
struct GroupRepository {
    private let persistence: PersistenceController

    init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    func createGroup(from draft: GroupDraft) throws -> LedgerGroup {
        guard draft.canCreate else { throw GroupError.invalidDraft }

        let context = persistence.container.viewContext
        let now = Date()

        let group = LedgerGroup(context: context)
        group.id = UUID()
        group.name = draft.trimmedName
        group.currencyCode = draft.normalizedCurrencyCode
        group.createdAt = now
        group.updatedAt = now
        context.assign(group, to: persistence.privateStore)

        let owner = Member(context: context)
        owner.id = UUID()
        owner.displayName = draft.trimmedOwnerDisplayName
        owner.role = MemberRole.owner.rawValue
        owner.invitationStatus = InvitationStatus.accepted.rawValue
        owner.joinedAt = now
        owner.group = group
        context.assign(owner, to: persistence.privateStore)

        for invitee in draft.invitees {
            let member = Member(context: context)
            member.id = UUID()
            member.displayName = invitee.displayName
            member.role = MemberRole.member.rawValue
            member.invitationStatus = InvitationStatus.pending.rawValue
            member.group = group
            context.assign(member, to: persistence.privateStore)
        }

        let defaultBook = LedgerBook(context: context)
        context.assign(defaultBook, to: persistence.privateStore)
        defaultBook.id = UUID()
        defaultBook.name = BookDraft.defaultName
        defaultBook.createdAt = now
        defaultBook.updatedAt = now
        defaultBook.isDefault = true
        defaultBook.sortOrder = 0
        defaultBook.group = group

        insertAudit(
            action: "group.created",
            actorDisplayName: draft.trimmedOwnerDisplayName,
            summary: "建立群組「\(draft.trimmedName)」",
            in: group,
            at: now
        )

        CurrentMemberIdentityRepository(persistence: persistence)
            .setCurrentMember(owner, in: group)

        do {
            try context.save()
            return group
        } catch {
            context.rollback()
            throw error
        }
    }

    func renameGroup(_ group: LedgerGroup, to name: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw GroupError.invalidGroupName }
        let actor = try currentActor(in: group, requiringMemberManagement: false)
        try EffectivePermissionRepository(persistence: persistence)
            .requireLedgerSettingsManagement(in: group)
        guard trimmedName != group.name else { return }

        let previousName = group.name ?? "未命名群組"
        let now = Date()
        group.name = trimmedName
        group.updatedAt = now
        insertAudit(
            action: "group.renamed",
            actorDisplayName: actor.displayName ?? "目前使用者",
            summary: "將群組「\(previousName)」重新命名為「\(trimmedName)」",
            in: group,
            at: now
        )
        try saveChanges()
    }

    func resendInvitation(_ member: Member, in group: LedgerGroup) throws {
        let actor = try currentActor(in: group, requiringMemberManagement: true)
        guard member.group == group else { throw GroupError.crossGroupMember }
        guard member.role != MemberRole.owner.rawValue else { throw GroupError.invalidMemberOperation }
        let canResendPending = member.invitationStatus == InvitationStatus.pending.rawValue
        let canRestoreRevoked = member.invitationStatus == InvitationStatus.revoked.rawValue
        let canRestoreRemoved = member.invitationStatus == InvitationStatus.accepted.rawValue
            && member.archivedAt != nil
        guard canResendPending || canRestoreRevoked || canRestoreRemoved else {
            throw GroupError.invitationNotPending
        }

        let now = Date()
        member.invitationStatus = InvitationStatus.pending.rawValue
        member.archivedAt = nil
        group.updatedAt = now
        insertAudit(
            action: "member.invitation.resent",
            actorDisplayName: actor.displayName ?? "目前使用者",
            summary: "重新邀請成員「\(member.displayName ?? "未命名成員")」",
            in: group,
            at: now
        )
        try saveChanges()
    }

    func revokeInvitation(_ member: Member, in group: LedgerGroup) throws {
        let actor = try currentActor(in: group, requiringMemberManagement: true)
        guard member.group == group else { throw GroupError.crossGroupMember }
        guard member.invitationStatus == InvitationStatus.pending.rawValue,
              member.archivedAt == nil
        else { throw GroupError.invitationNotPending }
        guard member.role != MemberRole.owner.rawValue else { throw GroupError.invalidMemberOperation }

        let now = Date()
        member.invitationStatus = InvitationStatus.revoked.rawValue
        member.archivedAt = now
        group.updatedAt = now
        insertAudit(
            action: "member.invitation.revoked",
            actorDisplayName: actor.displayName ?? "目前使用者",
            summary: "撤回成員「\(member.displayName ?? "未命名成員")」的 App 邀請狀態",
            in: group,
            at: now
        )
        try saveChanges()
    }

    func removeMember(_ member: Member, from group: LedgerGroup) throws {
        let actor = try currentActor(in: group, requiringMemberManagement: true)
        guard member.group == group else { throw GroupError.crossGroupMember }
        guard member != actor else { throw GroupError.useLeaveGroupForCurrentMember }
        guard member.archivedAt == nil,
              member.invitationStatus == InvitationStatus.accepted.rawValue
        else { throw GroupError.inactiveMember }
        guard member.role != MemberRole.owner.rawValue else {
            throw GroupError.ownerMustTransferBeforeLeaving
        }

        let now = Date()
        member.archivedAt = now
        group.updatedAt = now
        insertAudit(
            action: "member.removed",
            actorDisplayName: actor.displayName ?? "目前使用者",
            summary: "將成員「\(member.displayName ?? "未命名成員")」移出群組；歷史帳務關聯保留",
            in: group,
            at: now
        )
        try saveChanges()
    }

    /// Moves the App owner seat to another member of the same group.
    ///
    /// CloudKit share ownership does not move with it: the record zone stays in the
    /// Apple Account that created the share, so that account keeps holding the data
    /// and keeps managing the iCloud participant list. What moves is the App role —
    /// who manages members and ledger settings, and who is allowed to leave.
    ///
    /// The seat may only go to a member that is provably the person behind an
    /// accepted, writable `CKShare` participant. Without that correlation a `Member`
    /// row is just a display name, which is what
    /// `ownershipTransferRequiresCloudParticipantMapping` records.
    func transferOwnership(to member: Member, in group: LedgerGroup) throws {
        let actor = try currentActor(in: group, requiringMemberManagement: true)
        guard role(of: actor) == .owner else {
            throw GroupError.onlyOwnerCanTransferOwnership
        }
        if let restriction = ownershipTransferRestriction(to: member, in: group) {
            throw restriction
        }

        let now = Date()
        let previousOwnerName = actor.displayName ?? "目前使用者"
        member.role = MemberRole.owner.rawValue
        actor.role = MemberRole.administrator.rawValue
        // Without an explicit mapping, `CurrentMemberIdentityRepository` resolves the
        // current user of a private group through its single accepted owner. That is
        // no longer this member, so pin the identity before it stops being derivable.
        CurrentMemberIdentityRepository(persistence: persistence)
            .setCurrentMember(actor, in: group)
        group.updatedAt = now
        insertAudit(
            action: "group.ownership.transferred",
            actorDisplayName: previousOwnerName,
            summary: "將群組擁有權移轉給「\(member.displayName ?? "未命名成員")」；"
                + "「\(previousOwnerName)」改為管理員。iCloud 共享仍由原共享擁有者管理",
            in: group,
            at: now
        )
        try saveChanges()
    }

    /// Why `transferOwnership(to:in:)` would refuse this member, or `nil` when the
    /// member can take the seat. Member management uses it to explain a blocked
    /// transfer instead of offering one that fails on confirm.
    ///
    /// It deliberately does not check the current user's own permission — that is
    /// resolved by `currentActor(in:requiringMemberManagement:)` at transfer time.
    /// Pass `participantStatus` when the caller already resolved the group's statuses,
    /// because each lookup reads the group's share metadata.
    func ownershipTransferRestriction(
        to member: Member,
        in group: LedgerGroup,
        participantStatus: CloudParticipantStatus? = nil
    ) -> GroupError? {
        guard member.group == group else { return .crossGroupMember }
        guard role(of: member) != .owner else { return .invalidMemberOperation }
        guard member.archivedAt == nil,
              member.invitationStatus == InvitationStatus.accepted.rawValue
        else { return .inactiveMember }

        let status = participantStatus
            ?? cloudParticipantStatuses(in: group)[member.objectID]
            ?? .notShared
        switch status {
        case .notShared:
            // Only groups outside the shared store report this: the App role is the
            // whole authority there, exactly as `EffectivePermission.localOnly` treats
            // it, and there is no participant to correlate the member against. A
            // shared group whose share has not synced reports `.shareUnavailable`
            // instead, so an unverifiable member cannot slip through here.
            return nil
        case .shareUnavailable, .unmapped, .participantMissing:
            return .ownershipTransferRequiresCloudParticipantMapping
        case let .mapped(canWrite, _, isAccepted):
            guard isAccepted else { return .ownershipTransferRequiresCloudParticipantMapping }
            // A read-only participant would be clamped straight back to viewer by
            // `EffectivePermissionRepository`, leaving the group with an owner who
            // cannot act as one — and no owner able to hand the seat on again.
            guard canWrite else { return .ownershipTransferRequiresWritableParticipant }
            return nil
        }
    }

    /// Whether the member could take the owner seat at all, before the CloudKit
    /// mapping is considered. Passing `.notShared` skips the mapping half of the
    /// check, which member management reports separately so the reason stays visible.
    func isOwnershipTransferCandidate(_ member: Member, in group: LedgerGroup) -> Bool {
        ownershipTransferRestriction(
            to: member,
            in: group,
            participantStatus: .notShared
        ) == nil
    }

    func leaveGroup(_ group: LedgerGroup) throws {
        let identityRepository = CurrentMemberIdentityRepository(persistence: persistence)
        guard let actor = identityRepository.currentMember(in: group) else {
            throw GroupError.missingCurrentMember
        }
        guard actor.archivedAt == nil else { throw GroupError.inactiveMember }
        guard actor.role != MemberRole.owner.rawValue else {
            throw GroupError.ownerMustTransferBeforeLeaving
        }

        let now = Date()
        actor.archivedAt = now
        group.updatedAt = now
        insertAudit(
            action: "member.left",
            actorDisplayName: actor.displayName ?? "目前使用者",
            summary: "成員「\(actor.displayName ?? "未命名成員")」退出群組；歷史帳務關聯保留",
            in: group,
            at: now
        )
        try saveChanges()
    }

    /// Binds the CloudKit participant that is operating this device to the App member.
    /// `cloudParticipantID` is share-local and intentionally does not replace the
    /// private-only `LocalMemberIdentity` mapping used to identify the current user.
    func bindCurrentCloudParticipant(
        from share: CKShare,
        to member: Member,
        in group: LedgerGroup
    ) throws {
        guard let participant = share.currentUserParticipant else {
            throw GroupError.missingCloudParticipant
        }
        try bindCloudParticipant(participant, to: member, in: group)
        try saveChanges()
    }

    @discardableResult
    func claimCurrentMember(_ member: Member, in group: LedgerGroup) throws -> Member {
        guard persistence.store(for: group) === persistence.sharedStore else {
            throw GroupError.identityOnlyForSharedGroup
        }
        let identityRepository = CurrentMemberIdentityRepository(persistence: persistence)
        if let mappedMember = identityRepository.mappedMember(in: group) {
            if mappedMember.archivedAt != nil {
                throw GroupError.removedMemberCannotRejoin
            }
            if mappedMember != member {
                throw GroupError.invalidIdentityCandidate
            }
        }
        guard member.group == group,
              member.archivedAt == nil,
              member.invitationStatus == InvitationStatus.pending.rawValue,
              member.role == MemberRole.member.rawValue
                || member.role == MemberRole.viewer.rawValue
        else {
            throw GroupError.invalidIdentityCandidate
        }

        // Binding is opportunistic: the share metadata may not have reached this
        // device yet, and refusing the claim would leave the person with no App
        // identity at all. Writing is gated separately by
        // `EffectivePermissionRepository`, which denies mutations while the
        // CloudKit permission is still unknown.
        if let participant = availableCloudParticipant(in: group) {
            try validateCloudParticipant(participant, for: member, in: group)
            member.cloudParticipantID = participant.participantID
        }

        let context = persistence.container.viewContext
        let now = Date()
        member.invitationStatus = InvitationStatus.accepted.rawValue
        member.joinedAt = now
        group.updatedAt = now
        identityRepository.setCurrentMember(member, in: group)
        insertIdentityAudit(for: member, in: group, at: now)

        do {
            try context.save()
            return member
        } catch {
            context.rollback()
            throw error
        }
    }

    @discardableResult
    func joinSharedGroup(displayName: String, group: LedgerGroup) throws -> Member {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw GroupError.invalidDisplayName }
        guard persistence.store(for: group) === persistence.sharedStore else {
            throw GroupError.identityOnlyForSharedGroup
        }

        let identityRepository = CurrentMemberIdentityRepository(persistence: persistence)
        if let mappedMember = identityRepository.mappedMember(in: group) {
            if mappedMember.archivedAt != nil {
                throw GroupError.removedMemberCannotRejoin
            }
            throw GroupError.invalidIdentityCandidate
        }

        let participant = availableCloudParticipant(in: group)
        if let participant {
            try validateCloudParticipantForNewMember(participant, in: group)
        }

        let context = persistence.container.viewContext
        let store = persistence.store(for: group)
        let now = Date()
        let member = Member(context: context)
        context.assign(member, to: store)
        member.id = UUID()
        member.cloudParticipantID = participant?.participantID
        member.displayName = trimmedName
        member.invitationStatus = InvitationStatus.accepted.rawValue
        member.joinedAt = now
        member.role = MemberRole.member.rawValue
        member.group = group
        group.updatedAt = now
        identityRepository.setCurrentMember(member, in: group)
        insertIdentityAudit(for: member, in: group, at: now)

        do {
            try context.save()
            return member
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Joins every App member in the group to the live `CKShare` participant list.
    ///
    /// Unlike a plain mapping this keeps the members that did *not* resolve, because
    /// "not mapped yet" and "bound to a participant that is no longer in the share"
    /// are exactly the states member management and the two-Apple-Account validation
    /// matrix need to distinguish.
    func cloudParticipantStatuses(
        in group: LedgerGroup
    ) -> [NSManagedObjectID: CloudParticipantStatus] {
        let members = group.members as? Set<Member> ?? []

        let share: CKShare?
        do {
            share = try self.share(for: group)
        } catch {
            return statuses(for: members, allBeing: .shareUnavailable)
        }
        guard let share else {
            // A group that reached the shared store did so through a share, so a
            // missing share record means the metadata has not been mirrored to this
            // device — not that the group is unshared. Reporting `.notShared` there
            // would state as fact something this device cannot see. The private store
            // is the discriminator rather than the shared one, matching
            // `EffectivePermissionRepository`: the two are the same object when a
            // single in-memory store backs both configurations, and only "definitely
            // private" may skip the participant checks.
            let isShared = persistence.store(for: group) !== persistence.privateStore
            return statuses(for: members, allBeing: isShared ? .shareUnavailable : .notShared)
        }

        let participantsByID = Dictionary(
            share.participants.map { ($0.participantID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return Dictionary(uniqueKeysWithValues: members.map { member in
            guard let participantID = member.cloudParticipantID else {
                return (member.objectID, CloudParticipantStatus.unmapped)
            }
            guard let participant = participantsByID[participantID] else {
                return (member.objectID, CloudParticipantStatus.participantMissing)
            }
            return (
                member.objectID,
                CloudParticipantStatus.mapped(
                    canWrite: participant.role == .owner || participant.permission == .readWrite,
                    isShareOwner: participant.role == .owner,
                    isAccepted: participant.acceptanceStatus == .accepted
                )
            )
        })
    }

    private func statuses(
        for members: Set<Member>,
        allBeing status: CloudParticipantStatus
    ) -> [NSManagedObjectID: CloudParticipantStatus] {
        Dictionary(uniqueKeysWithValues: members.map { ($0.objectID, status) })
    }

    private func share(for group: LedgerGroup) throws -> CKShare? {
        try persistence.existingShare(for: group.objectID)
    }

    private func currentCloudParticipant(in group: LedgerGroup) throws -> CKShare.Participant {
        guard let share = try share(for: group),
              let participant = share.currentUserParticipant
        else { throw GroupError.missingCloudParticipant }
        return participant
    }

    /// The accepted participant for this device, or `nil` when the share metadata
    /// is not available yet. Used by the claim/join paths, which must not fail just
    /// because CloudKit has not synced.
    private func availableCloudParticipant(in group: LedgerGroup) -> CKShare.Participant? {
        guard let participant = try? currentCloudParticipant(in: group),
              participant.acceptanceStatus == .accepted
        else { return nil }
        return participant
    }

    private func bindCloudParticipant(
        _ participant: CKShare.Participant,
        to member: Member,
        in group: LedgerGroup
    ) throws {
        guard member.group == group else { throw GroupError.crossGroupMember }
        try validateCloudParticipant(participant, for: member, in: group)
        member.cloudParticipantID = participant.participantID
    }

    private func validateCloudParticipant(
        _ participant: CKShare.Participant,
        for member: Member,
        in group: LedgerGroup
    ) throws {
        guard participant.acceptanceStatus == .accepted else {
            throw GroupError.cloudParticipantNotAccepted
        }
        if let existingID = member.cloudParticipantID,
           existingID != participant.participantID {
            throw GroupError.cloudParticipantMismatch
        }
        if let existingMember = memberLinked(
            to: participant.participantID,
            in: group,
            excluding: member
        ) {
            if existingMember.archivedAt != nil {
                throw GroupError.removedMemberCannotRejoin
            }
            throw GroupError.cloudParticipantAlreadyLinked
        }

        // A read-only participant is allowed to claim a member/administrator seat.
        // CloudKit permission is the ceiling, not a claim precondition, so the App
        // role is clamped down to viewer at every write instead of blocking the
        // claim outright and leaving the person with no identity at all.
        // `EffectivePermissionRepository` applies that clamp.
        // Claiming the owner seat is only allowed for the share owner: on this path
        // nothing else vouches for who the participant is. A seat that moved through
        // `transferOwnership(to:in:)` is a different matter — that check runs on an
        // already-mapped participant — so this is a rule about claiming, not an
        // invariant that the App owner is always the CKShare owner.
        if role(of: member) == .owner, participant.role != .owner {
            throw GroupError.cloudParticipantRoleMismatch
        }
    }

    private func validateCloudParticipantForNewMember(
        _ participant: CKShare.Participant,
        in group: LedgerGroup
    ) throws {
        guard participant.acceptanceStatus == .accepted else {
            throw GroupError.cloudParticipantNotAccepted
        }
        if let existingMember = memberLinked(to: participant.participantID, in: group) {
            if existingMember.archivedAt != nil {
                throw GroupError.removedMemberCannotRejoin
            }
            throw GroupError.cloudParticipantAlreadyLinked
        }
    }

    private func memberLinked(
        to participantID: String,
        in group: LedgerGroup,
        excluding excludedMember: Member? = nil
    ) -> Member? {
        let members = group.members as? Set<Member> ?? []
        return members.first {
            $0 != excludedMember && $0.cloudParticipantID == participantID
        }
    }

    private func currentActor(
        in group: LedgerGroup,
        requiringMemberManagement: Bool
    ) throws -> Member {
        guard let actor = CurrentMemberIdentityRepository(persistence: persistence)
            .currentMember(in: group),
              actor.archivedAt == nil,
              actor.invitationStatus == InvitationStatus.accepted.rawValue
        else { throw GroupError.missingCurrentMember }

        if requiringMemberManagement {
            // The App role alone is not enough: a read-only CloudKit participant
            // cannot push member changes, so the effective permission decides.
            try EffectivePermissionRepository(persistence: persistence)
                .requireMemberManagement(in: group)
        }
        return actor
    }

    private func role(of member: Member) -> MemberRole? {
        member.role.flatMap(MemberRole.init(rawValue:))
    }

    private func saveChanges() throws {
        let context = persistence.container.viewContext
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    private func insertIdentityAudit(for member: Member, in group: LedgerGroup, at date: Date) {
        insertAudit(
            action: "member.identity.confirmed",
            actorDisplayName: member.displayName ?? "共享成員",
            summary: "確認群組成員身分「\(member.displayName ?? "共享成員")」並對應 iCloud 共享參與者",
            in: group,
            at: date
        )
    }

    private func insertAudit(
        action: String,
        actorDisplayName: String,
        summary: String,
        in group: LedgerGroup,
        at date: Date
    ) {
        let context = persistence.container.viewContext
        let audit = AuditEvent(context: context)
        context.assign(audit, to: persistence.store(for: group))
        audit.id = UUID()
        audit.action = action
        audit.actorDisplayName = actorDisplayName
        audit.createdAt = date
        audit.summary = summary
        audit.group = group
    }

    enum GroupError: LocalizedError, Equatable {
        case invalidDraft
        case invalidDisplayName
        case invalidGroupName
        case identityOnlyForSharedGroup
        case invalidIdentityCandidate
        case removedMemberCannotRejoin
        case missingCurrentMember
        case crossGroupMember
        case invitationNotPending
        case inactiveMember
        case invalidMemberOperation
        case useLeaveGroupForCurrentMember
        case ownerMustTransferBeforeLeaving
        case onlyOwnerCanTransferOwnership
        case ownershipTransferRequiresCloudParticipantMapping
        case ownershipTransferRequiresWritableParticipant
        case missingCloudParticipant
        case cloudParticipantNotAccepted
        case cloudParticipantAlreadyLinked
        case cloudParticipantMismatch
        case cloudParticipantRoleMismatch

        var errorDescription: String? {
            switch self {
            case .invalidDraft:
                return "請輸入群組名稱與你的顯示名稱。"
            case .invalidDisplayName:
                return "請輸入你的顯示名稱。"
            case .invalidGroupName:
                return "請輸入有效的群組名稱。"
            case .identityOnlyForSharedGroup:
                return "只有接受共享邀請的群組需要確認成員身分。"
            case .invalidIdentityCandidate:
                return "這個待邀請成員無法作為目前使用者。"
            case .removedMemberCannotRejoin:
                return "你已離開或被移出這個群組。需要由管理者重新邀請後才能再次加入。"
            case .missingCurrentMember:
                return "無法確認你在這個群組中的成員身分。"
            case .crossGroupMember:
                return "不能管理其他群組的成員。"
            case .invitationNotPending:
                return "只有待邀請、已撤回或已離開的成員可以重新邀請。"
            case .inactiveMember:
                return "這位成員目前不是有效成員。"
            case .invalidMemberOperation:
                return "無法對這位成員執行此操作。"
            case .useLeaveGroupForCurrentMember:
                return "目前使用者請使用「退出群組」。"
            case .ownerMustTransferBeforeLeaving:
                return "群組擁有者不能直接退出或被移除，必須先完成擁有權移轉。"
            case .onlyOwnerCanTransferOwnership:
                return "只有目前的群組擁有者可以移轉擁有權。"
            case .ownershipTransferRequiresCloudParticipantMapping:
                return "這位成員還沒有與 iCloud 共享參與者建立可驗證的對應，因此不能接手群組擁有權。"
            case .ownershipTransferRequiresWritableParticipant:
                return "這位成員在 iCloud 共享中的權限是唯讀，請先在共享設定改為可編輯，再移轉群組擁有權。"
            case .missingCloudParticipant:
                return "找不到目前 Apple Account 在這個 iCloud 共享中的參與者身分，請確認共享已完成同步後再試。"
            case .cloudParticipantNotAccepted:
                return "目前 iCloud 共享邀請尚未完成接受，暫時不能確認 App 成員身分。"
            case .cloudParticipantAlreadyLinked:
                return "這個 iCloud 共享參與者已經對應到另一位 App 成員。"
            case .cloudParticipantMismatch:
                return "這位 App 成員已對應到不同的 iCloud 共享參與者，無法直接改綁。"
            case .cloudParticipantRoleMismatch:
                return "App 群組擁有者必須對應到 iCloud 共享的擁有者。"
            }
        }
    }
}

@MainActor
struct CurrentMemberIdentityRepository {
    private let persistence: PersistenceController

    init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    func currentMember(in group: LedgerGroup) -> Member? {
        if let mappedMember = mappedMember(in: group) {
            guard mappedMember.archivedAt == nil,
                  mappedMember.invitationStatus == InvitationStatus.accepted.rawValue
            else { return nil }
            return mappedMember
        }

        guard persistence.store(for: group) === persistence.privateStore else { return nil }
        let members = group.members as? Set<Member> ?? []
        let owners = members.filter {
            $0.archivedAt == nil
                && $0.role == MemberRole.owner.rawValue
                && $0.invitationStatus == InvitationStatus.accepted.rawValue
        }
        return owners.count == 1 ? owners.first : nil
    }

    func mappedMember(in group: LedgerGroup) -> Member? {
        guard let groupID = group.id,
              let identity = identities(for: groupID).first,
              let memberID = identity.memberID
        else { return nil }
        let members = group.members as? Set<Member> ?? []
        return members.first { $0.id == memberID }
    }

    func hasInactiveIdentity(in group: LedgerGroup) -> Bool {
        mappedMember(in: group)?.archivedAt != nil
    }

    func setCurrentMember(_ member: Member, in group: LedgerGroup) {
        guard let groupID = group.id,
              let memberID = member.id,
              member.group == group
        else { return }

        let context = persistence.container.viewContext
        let existing = identities(for: groupID)
        let identity = existing.first ?? LocalMemberIdentity(context: context)
        if identity.objectID.isTemporaryID {
            context.assign(identity, to: persistence.privateStore)
            identity.id = UUID()
            identity.createdAt = Date()
        }
        identity.groupID = groupID
        identity.memberID = memberID
        for duplicate in existing.dropFirst() {
            context.delete(duplicate)
        }
    }

    func clearCurrentMember(in group: LedgerGroup) {
        guard let groupID = group.id else { return }
        let context = persistence.container.viewContext
        for identity in identities(for: groupID) {
            context.delete(identity)
        }
    }

    func needsResolution(for group: LedgerGroup) -> Bool {
        persistence.store(for: group) === persistence.sharedStore
            && currentMember(in: group) == nil
            && !hasInactiveIdentity(in: group)
    }

    private func identities(for groupID: UUID) -> [LocalMemberIdentity] {
        let request = NSFetchRequest<LocalMemberIdentity>(entityName: "LocalMemberIdentity")
        request.predicate = NSPredicate(format: "groupID == %@", groupID as CVarArg)
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \LocalMemberIdentity.createdAt, ascending: true)
        ]
        request.affectedStores = [persistence.privateStore]
        return (try? persistence.container.viewContext.fetch(request)) ?? []
    }
}
