import Foundation

struct AccountDraft: Equatable, Sendable {
    var name = ""
    var type: AccountType = .cash

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canCreate: Bool {
        !trimmedName.isEmpty
    }
}
