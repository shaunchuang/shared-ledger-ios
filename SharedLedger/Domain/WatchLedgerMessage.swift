import Foundation

struct WatchLedgerChoice: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
}

struct WatchLedgerContext: Codable {
    var version = 1
    var generatedAt = Date()
    var snapshot: LedgerWidgetSnapshot?
    var groupID: UUID?
    var accounts: [WatchLedgerChoice] = []
    var categories: [WatchLedgerChoice] = []
    var payer: WatchLedgerChoice?
    var members: [WatchLedgerChoice] = []
    var restriction: String?

    var canCreate: Bool {
        version == 1 && snapshot != nil && groupID != nil && payer != nil
            && !accounts.isEmpty && !members.isEmpty && restriction == nil
    }
}

struct WatchLedgerState: Codable {
    var context: WatchLedgerContext?
    var pending: WatchLedgerRequest?

    mutating func receive(_ reply: WatchLedgerReply) {
        guard reply.version == 1 else { return }
        if let incoming = reply.context, incoming.version == 1,
           incoming.generatedAt >= (context?.generatedAt ?? .distantPast) {
            context = incoming
        }
        if let id = pending?.id, reply.savedID == id || reply.rejectedID == id {
            pending = nil
        }
    }
}

/// This ID is kept until the phone acknowledges the transaction. The phone uses
/// it as LedgerEntry.id in the same save as the entry, splits, payments and audit.
struct WatchLedgerRequest: Codable, Equatable {
    var version = 1
    let id: UUID
    let groupID: UUID
    let bookID: UUID
    let currencyCode: String
    let kind: EntryKind
    let amount: Decimal
    let date: Date
    let accountID: UUID
    let categoryID: UUID?
    let payerID: UUID
    let memberIDs: [UUID]

    var isValid: Bool {
        version == 1 && (kind == .expense || kind == .income)
            && !amount.isNaN && amount > 0 && amount <= 999_999_999_999
            && LedgerCurrency.normalizedCode(currencyCode) == currencyCode
            && LedgerCurrency.isValidAmount(amount, currencyCode: currencyCode)
            && !memberIDs.isEmpty && Set(memberIDs).count == memberIDs.count
    }
}

struct WatchLedgerMessage: Codable {
    var version = 1
    /// nil requests a fresh context; a non-nil request asks for an explicit save.
    var request: WatchLedgerRequest?
}

struct WatchLedgerReply: Codable {
    var version = 1
    var context: WatchLedgerContext?
    var savedID: UUID?
    /// A definitive rejection allows editing. Transport errors do not: the save
    /// may already have committed while its reply was lost.
    var rejectedID: UUID?
    var error: String?
}

enum WatchLedgerError: LocalizedError {
    case invalid, changed, busy, setup
    var errorDescription: String? {
        switch self {
        case .invalid: return LedgerStringKey.watchInvalid.string()
        case .changed: return LedgerStringKey.watchChanged.string()
        case .busy: return LedgerStringKey.watchBusy.string()
        case .setup: return LedgerStringKey.watchSetup.string()
        }
    }
}
