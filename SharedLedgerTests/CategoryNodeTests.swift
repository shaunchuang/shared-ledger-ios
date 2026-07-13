import XCTest
@testable import SharedLedger

final class CategoryNodeTests: XCTestCase {
    func testDepthIncludesDeepestDescendant() {
        let tree = CategoryNode(
            name: "交通",
            children: [
                CategoryNode(
                    name: "汽車",
                    children: [CategoryNode(name: "加油")]
                ),
                CategoryNode(name: "大眾運輸")
            ]
        )

        XCTAssertEqual(tree.depth, 3)
    }

    func testContainsFindsNestedCategory() {
        let target = CategoryNode(name: "捷運")
        let tree = CategoryNode(
            name: "交通",
            children: [CategoryNode(name: "大眾運輸", children: [target])]
        )

        XCTAssertTrue(tree.contains(id: target.id))
        XCTAssertFalse(tree.contains(id: UUID()))
    }
}

final class GroupDraftTests: XCTestCase {
    func testRequiresGroupAndOwnerNames() {
        XCTAssertFalse(GroupDraft().canCreate)

        let valid = GroupDraft(name: "家庭", ownerDisplayName: "小明")
        XCTAssertTrue(valid.canCreate)
    }

    func testAddingInviteesIgnoresExistingContact() {
        let contact = InviteeContact(contactIdentifier: "contact-1", displayName: "小美")
        var draft = GroupDraft(name: "家庭", invitees: [contact])

        draft.addInvitees([contact])

        XCTAssertEqual(draft.invitees, [contact])
    }

    func testAddingInviteesDeduplicatesWithinSameBatch() {
        let contact = InviteeContact(contactIdentifier: "contact-1", displayName: "小美")
        var draft = GroupDraft(name: "家庭")

        draft.addInvitees([contact, contact])

        XCTAssertEqual(draft.invitees, [contact])
    }
}
