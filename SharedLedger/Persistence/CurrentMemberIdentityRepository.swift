import CoreData
import Foundation

/// 解析目前 Apple Account 在各群組對應的 App 內 `Member`。
///
/// private 群組以「唯一已接受的 owner」推導；shared 群組改用 private store 的
/// `LocalMemberIdentity`，把 shared `LedgerGroup.id` 對應到 shared `Member.id`。
/// 這個對應只存在 private configuration，不跨 store 建立 relationship，也不會分享
/// 給其他參與者，因此不取代 CloudKit participant 的資料存取權限。
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
