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

    var displayName: String {
        switch self {
        case .owner: "群組擁有者"
        case .administrator: "管理員"
        case .member: "成員"
        case .viewer: "唯讀成員"
        }
    }
}

enum InvitationStatus: String, CaseIterable, Codable, Sendable {
    case accepted
    case pending
    case revoked
}
