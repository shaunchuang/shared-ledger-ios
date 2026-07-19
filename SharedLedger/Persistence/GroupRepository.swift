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
            member.isCurrentUser = false
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

        let audit = AuditEvent(context: context)
        audit.id = UUID()
        audit.action = "group.created"
        audit.actorDisplayName = draft.trimmedOwnerDisplayName
        audit.createdAt = now
        audit.summary = "建立群組「\(draft.trimmedName)」"
        audit.group = group
        context.assign(audit, to: persistence.privateStore)

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

    @discardableResult
    func claimCurrentMember(_ member: Member, in group: LedgerGroup) throws -> Member {
        guard persistence.store(for: group) === persistence.sharedStore else {
            throw GroupError.identityOnlyForSharedGroup
        }
        guard member.group == group,
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
        CurrentMemberIdentityRepository(persistence: persistence)
            .setCurrentMember(member, in: group)
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
        CurrentMemberIdentityRepository(persistence: persistence)
            .setCurrentMember(member, in: group)
        insertIdentityAudit(for: member, in: group, at: now)

        do {
            try context.save()
            return member
        } catch {
            context.rollback()
            throw error
        }
    }

    private func insertIdentityAudit(for member: Member, in group: LedgerGroup, at date: Date) {
        let context = persistence.container.viewContext
        let audit = AuditEvent(context: context)
        context.assign(audit, to: persistence.store(for: group))
        audit.id = UUID()
        audit.action = "member.identity.confirmed"
        audit.actorDisplayName = member.displayName ?? "共享成員"
        audit.createdAt = date
        audit.summary = "確認群組成員身分「\(member.displayName ?? "共享成員")」"
        audit.group = group
    }

    enum GroupError: LocalizedError {
        case invalidDraft
        case invalidDisplayName
        case identityOnlyForSharedGroup
        case invalidIdentityCandidate

        var errorDescription: String? {
            switch self {
            case .invalidDraft:
                return "請輸入群組名稱與你的顯示名稱。"
            case .invalidDisplayName:
                return "請輸入你的顯示名稱。"
            case .identityOnlyForSharedGroup:
                return "只有接受共享邀請的群組需要確認成員身分。"
            case .invalidIdentityCandidate:
                return "這個待邀請成員無法作為目前使用者。"
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
        let members = group.members as? Set<Member> ?? []

        if persistence.store(for: group) === persistence.privateStore {
            let owners = members.filter {
                $0.role == MemberRole.owner.rawValue
                    && $0.invitationStatus == InvitationStatus.accepted.rawValue
            }
            return owners.count == 1 ? owners.first : nil
        }

        guard let groupID = group.id,
              let identity = identities(for: groupID).first,
              let memberID = identity.memberID
        else { return nil }

        return members.first {
            $0.id == memberID
                && $0.invitationStatus == InvitationStatus.accepted.rawValue
        }
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
