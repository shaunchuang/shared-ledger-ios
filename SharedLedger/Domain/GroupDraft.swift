import Foundation

struct InviteeContact: Identifiable, Equatable, Sendable {
    let contactIdentifier: String
    let displayName: String

    var id: String { contactIdentifier }
}

struct GroupDraft: Equatable, Sendable {
    var name = ""
    var ownerDisplayName = "我"
    var invitees: [InviteeContact] = []

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedOwnerDisplayName: String {
        ownerDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canCreate: Bool {
        !trimmedName.isEmpty && !trimmedOwnerDisplayName.isEmpty
    }

    mutating func addInvitees(_ contacts: [InviteeContact]) {
        let existingIdentifiers = Set(invitees.map(\.contactIdentifier))
        invitees.append(contentsOf: contacts.filter {
            !existingIdentifiers.contains($0.contactIdentifier)
        })
    }
}

