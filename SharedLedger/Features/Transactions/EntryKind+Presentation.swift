import SwiftUI

extension EntryKind {
    var systemImage: String {
        switch self {
        case .income: return "arrow.down.circle.fill"
        case .expense: return "arrow.up.circle.fill"
        case .transfer: return "arrow.left.arrow.right.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .income: return LedgerTheme.primary
        case .expense: return LedgerTheme.coral
        case .transfer: return LedgerTheme.amber
        }
    }
}
