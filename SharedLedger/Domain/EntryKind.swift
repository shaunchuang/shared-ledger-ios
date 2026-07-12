import Foundation

enum EntryKind: String, CaseIterable, Codable, Sendable {
    case income
    case expense
    case transfer
}

