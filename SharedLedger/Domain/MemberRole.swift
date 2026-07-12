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
}

