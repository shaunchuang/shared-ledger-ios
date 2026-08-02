import Foundation

struct InviteeContact: Identifiable, Equatable, Sendable {
    let contactIdentifier: String
    let displayName: String

    var id: String { contactIdentifier }
}

struct GroupDraft: Equatable, Sendable {
    var name = ""
    var ownerDisplayName = "我"
    var currencyCode = LedgerCurrency.defaultCode
    var invitees: [InviteeContact] = []
    /// 建立群組時是否一併套用內建分類目錄。
    var usesDefaultCategories = true

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedOwnerDisplayName: String {
        ownerDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedCurrencyCode: String {
        LedgerCurrency.normalizedCode(currencyCode)
    }

    var canCreate: Bool {
        !trimmedName.isEmpty && !trimmedOwnerDisplayName.isEmpty
    }

    mutating func addInvitees(_ contacts: [InviteeContact]) {
        var identifiers = Set(invitees.map(\.contactIdentifier))
        for contact in contacts where identifiers.insert(contact.contactIdentifier).inserted {
            invitees.append(contact)
        }
    }
}
