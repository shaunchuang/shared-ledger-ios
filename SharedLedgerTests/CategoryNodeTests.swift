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

