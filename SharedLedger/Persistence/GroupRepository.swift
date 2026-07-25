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
        guard role(of: actor)?.canManageLedgerSettings == true else {
            throw GroupError.permissionDenied
        }
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
        guard member.invitationStatus == InvitationStatus.pending.rawValue
                || member.invitationStatus == InvitationStatus.revoked.rawValue
        else { throw GroupError.invitationNotPending }

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

        let context = persistence.container.viewContext
        let store = persistence.store(for: group)
        let now = Date()
        let member = Member(context: context)
        context.assign(member, to: store)
        member.id = UUID()
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

    private func currentActor(
        in group: LedgerGroup,
        requiringMemberManagement: Bool
    ) throws -> Member {
        guard let actor = CurrentMemberIdentityRepository(persistence: persistence)
            .currentMember(in: group),
              actor.archivedAt == nil,
              actor.invitationStatus == InvitationStatus.accepted.rawValue
        else { throw GroupError.missingCurrentMember }

        if requiringMemberManagement, role(of: actor)?.canManageMembers != true {
            throw GroupError.permissionDenied
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
            summary: "確認群組成員身分「\(member.displayName ?? "共享成員")」",
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

    enum GroupError: LocalizedError {
        case invalidDraft
        case invalidDisplayName
        case invalidGroupName
        case identityOnlyForSharedGroup
        case invalidIdentityCandidate
        case removedMemberCannotRejoin
        case missingCurrentMember
        case permissionDenied
        case crossGroupMember
        case invitationNotPending
        case inactiveMember
        case invalidMemberOperation
        case useLeaveGroupForCurrentMember
        case ownerMustTransferBeforeLeaving
        case ownershipTransferRequiresCloudParticipantMapping

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
            case .permissionDenied:
                return "你的角色沒有管理這個群組成員的權限。"
            case .crossGroupMember:
                return "不能管理其他群組的成員。"
            case .invitationNotPending:
                return "只有待邀請或已撤回的成員可以重新邀請。"
            case .inactiveMember:
                return "這位成員目前不是有效成員。"
            case .invalidMemberOperation:
                return "無法對這位成員執行此操作。"
            case .useLeaveGroupForCurrentMember:
                return "目前使用者請使用「退出群組」。"
            case .ownerMustTransferBeforeLeaving:
                return "群組擁有者不能直接退出或被移除，必須先完成擁有權移轉。"
            case .ownershipTransferRequiresCloudParticipantMapping:
                return "目前尚未建立 App 成員與 iCloud 共享參與者的安全對應，因此暫時不能移轉群組擁有權。"
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
