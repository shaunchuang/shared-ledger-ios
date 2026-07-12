import Foundation

struct CategoryNode: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var children: [CategoryNode]

    init(id: UUID = UUID(), name: String, children: [CategoryNode] = []) {
        self.id = id
        self.name = name
        self.children = children
    }

    var depth: Int {
        guard let deepestChild = children.map(\.depth).max() else { return 1 }
        return deepestChild + 1
    }

    func contains(id targetID: UUID) -> Bool {
        id == targetID || children.contains { $0.contains(id: targetID) }
    }
}

