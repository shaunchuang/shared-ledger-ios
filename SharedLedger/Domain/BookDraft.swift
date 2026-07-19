import Foundation

struct BookDraft: Equatable, Sendable {
    static let defaultName = "主要帳本"

    var name = ""

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canCreate: Bool {
        !trimmedName.isEmpty
    }
}
