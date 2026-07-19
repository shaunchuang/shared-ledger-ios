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
        owner.isCurrentUser = true
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

        do {
            try context.save()
            return group
        } catch {
            context.rollback()
            throw error
        }
    }

    enum GroupError: LocalizedError {
        case invalidDraft

        var errorDescription: String? {
            "請輸入群組名稱與你的顯示名稱。"
        }
    }
}
