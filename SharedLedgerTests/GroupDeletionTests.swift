import CoreData
import XCTest
@testable import SharedLedger

@MainActor
final class GroupDeletionTests: XCTestCase {
    func testDeletingAGroupRemovesEverythingUnderIt() throws {
        let fixture = try makeFixture()
        let category = try fixture.makeCategory(named: "餐飲")
        try fixture.addExpense(100, category: category, in: fixture.book)

        XCTAssertEqual(try fixture.count(of: "LedgerEntry"), 1)
        XCTAssertEqual(try fixture.count(of: "LedgerBook"), 1)

        try GroupRepository(persistence: fixture.persistence).deleteGroup(fixture.group)

        // 每個 to-many 關聯都是 cascade，所以整個物件圖都要跟著消失，
        // 不能只剩下一堆沒有群組的孤兒資料。
        XCTAssertEqual(try fixture.count(of: "LedgerGroup"), 0)
        XCTAssertEqual(try fixture.count(of: "LedgerBook"), 0)
        XCTAssertEqual(try fixture.count(of: "LedgerEntry"), 0)
        XCTAssertEqual(try fixture.count(of: "EntrySplit"), 0)
        XCTAssertEqual(try fixture.count(of: "EntryPayment"), 0)
        XCTAssertEqual(try fixture.count(of: "LedgerAccount"), 0)
        XCTAssertEqual(try fixture.count(of: "LedgerCategory"), 0)
        XCTAssertEqual(try fixture.count(of: "Member"), 0)
        XCTAssertEqual(try fixture.count(of: "AuditEvent"), 0)
    }

    func testDeletingAGroupClearsItsLocalIdentityMapping() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(try fixture.count(of: "LocalMemberIdentity"), 1)

        try GroupRepository(persistence: fixture.persistence).deleteGroup(fixture.group)

        // 身分對應存在沒有關聯的私有 entity 上，cascade 到不了；留著就會指向
        // 一個已經不存在的群組成員。
        XCTAssertEqual(try fixture.count(of: "LocalMemberIdentity"), 0)
    }

    func testDeletingOneGroupLeavesTheOthersIntact() throws {
        let fixture = try makeFixture()
        let other = try GroupRepository(persistence: fixture.persistence).createGroup(
            from: GroupDraft(name: "旅行", ownerDisplayName: "小明", currencyCode: "TWD")
        )
        try fixture.persistence.container.viewContext.save()
        try fixture.addExpense(100, in: fixture.book)

        try GroupRepository(persistence: fixture.persistence).deleteGroup(fixture.group)

        XCTAssertEqual(try fixture.count(of: "LedgerGroup"), 1)
        XCTAssertFalse(other.isDeleted)
        XCTAssertEqual(other.name, "旅行")
        XCTAssertEqual(try fixture.count(of: "LedgerEntry"), 0)
    }

    func testOwnerOfAPrivateGroupMayDelete() throws {
        let fixture = try makeFixture()

        XCTAssertNil(
            GroupRepository(persistence: fixture.persistence)
                .deletionRestriction(for: fixture.group)
        )
    }

    func testANonOwnerMayNotDelete() throws {
        let fixture = try makeFixture()
        let member = try fixture.makeMember(named: "小美")
        CurrentMemberIdentityRepository(persistence: fixture.persistence)
            .setCurrentMember(member, in: fixture.group)
        try fixture.persistence.container.viewContext.save()

        let repository = GroupRepository(persistence: fixture.persistence)
        XCTAssertEqual(
            repository.deletionRestriction(for: fixture.group),
            .onlyOwnerCanDeleteGroup
        )
        XCTAssertThrowsError(try repository.deleteGroup(fixture.group)) { error in
            XCTAssertEqual(error as? GroupRepository.GroupError, .onlyOwnerCanDeleteGroup)
        }
        // 被拒絕的刪除不能留下半套結果。
        XCTAssertEqual(try fixture.count(of: "LedgerGroup"), 1)
    }

    func testAPrivateGroupWithoutAnIdentityMappingStillResolvesItsOwner() throws {
        let fixture = try makeFixture()
        CurrentMemberIdentityRepository(persistence: fixture.persistence)
            .clearCurrentMember(in: fixture.group)
        try fixture.persistence.container.viewContext.save()

        // 私有群組屬於這個 Apple Account，唯一的已接受 owner 就是目前使用者。
        // 少了本機對應不該把擁有者鎖在自己的群組外面。
        XCTAssertNil(
            GroupRepository(persistence: fixture.persistence)
                .deletionRestriction(for: fixture.group)
        )
    }

    func testAGroupWithNoAcceptedOwnerMayNotDelete() throws {
        let fixture = try makeFixture()
        CurrentMemberIdentityRepository(persistence: fixture.persistence)
            .clearCurrentMember(in: fixture.group)
        // 沒有已接受的 owner，就沒有可以推導的目前使用者，owner 的後備路徑也失效。
        fixture.owner.invitationStatus = InvitationStatus.pending.rawValue
        try fixture.persistence.container.viewContext.save()

        XCTAssertEqual(
            GroupRepository(persistence: fixture.persistence)
                .deletionRestriction(for: fixture.group),
            .missingCurrentMember
        )
    }

    private func makeFixture() throws -> DeletionFixture {
        let persistence = PersistenceController(inMemory: true)
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(name: "家庭", ownerDisplayName: "小明", currencyCode: "TWD")
        )
        let owner = try XCTUnwrap((group.members as? Set<Member>)?.first)
        let book = try XCTUnwrap(BookRepository(persistence: persistence).defaultBook(in: group))
        let account = try AccountRepository(persistence: persistence).createAccount(
            from: AccountDraft(name: "現金"),
            in: group
        )
        CurrentMemberIdentityRepository(persistence: persistence)
            .setCurrentMember(owner, in: group)
        try persistence.container.viewContext.save()

        return DeletionFixture(
            persistence: persistence,
            group: group,
            book: book,
            account: account,
            owner: owner
        )
    }
}

@MainActor
private struct DeletionFixture {
    let persistence: PersistenceController
    let group: LedgerGroup
    let book: LedgerBook
    let account: LedgerAccount
    let owner: Member

    func count(of entityName: String) throws -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        return try persistence.container.viewContext.count(for: request)
    }

    func makeCategory(named name: String) throws -> LedgerCategory {
        try CategoryRepository(persistence: persistence).createCategory(
            from: CategoryDraft(name: name),
            in: group,
            parent: nil
        )
    }

    func makeMember(named name: String) throws -> Member {
        let context = persistence.container.viewContext
        let member = Member(context: context)
        context.assign(member, to: persistence.privateStore)
        member.id = UUID()
        member.displayName = name
        member.role = MemberRole.member.rawValue
        member.invitationStatus = InvitationStatus.accepted.rawValue
        member.joinedAt = Date()
        member.group = group
        try context.save()
        return member
    }

    @discardableResult
    func addExpense(
        _ amount: Int,
        category: LedgerCategory? = nil,
        in book: LedgerBook
    ) throws -> LedgerEntry {
        let ownerID = try XCTUnwrap(owner.id)
        return try EntryRepository(persistence: persistence).createEntry(
            from: TransactionDraft(
                kind: .expense,
                amountText: "\(amount)",
                date: Date(),
                categoryID: category?.id,
                sourceAccountID: account.id,
                payerMemberID: ownerID,
                splitMemberIDs: [ownerID]
            ),
            in: book,
            accounts: Array(group.accounts as? Set<LedgerAccount> ?? []),
            categories: Array(group.categories as? Set<LedgerCategory> ?? []),
            members: Array(group.members as? Set<Member> ?? [])
        )
    }
}
