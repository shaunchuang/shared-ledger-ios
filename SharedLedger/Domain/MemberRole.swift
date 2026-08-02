import Foundation

enum MemberRole: String, CaseIterable, Codable, Sendable {
    case owner
    case administrator
    case member
    case viewer

    var canEditTransactions: Bool {
        self != .viewer
    }

    var canManageMembers: Bool {
        self == .owner || self == .administrator
    }

    var canManageLedgerSettings: Bool {
        self == .owner || self == .administrator
    }

    var displayNameKey: LedgerStringKey {
        switch self {
        case .owner: .memberRoleOwner
        case .administrator: .memberRoleAdministrator
        case .member: .memberRoleMember
        case .viewer: .memberRoleViewer
        }
    }

    var displayName: String { displayNameKey.string() }
}

enum InvitationStatus: String, CaseIterable, Codable, Sendable {
    case accepted
    case pending
    case revoked
}
