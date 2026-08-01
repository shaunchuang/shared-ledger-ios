import CoreData
import Foundation

/// Tests a Core Data change notification against the object types a screen's cached
/// state is derived from.
///
/// Screens that cache derived state in `@State` refresh it from
/// `NSManagedObjectContextObjectsDidChange` instead of recomputing it inside `body`.
/// A `TabView` keeps every tab's views alive while another tab is on screen, and a
/// `NavigationStack` keeps every pushed screen alive behind the top one, so an
/// unfiltered subscription re-derives state for writes the screen does not depend on.
enum ContextChangeObserver {
    /// What a screen's cached state is derived from.
    enum Scope {
        /// The group, its members, and the private `LocalMemberIdentity` that maps
        /// this device's Apple Account onto one of them: everything an effective
        /// permission — and the CloudKit participant mapping shown beside it — is
        /// resolved from.
        case groupPermissions
        /// Voided transactions are derived from the group's audit events.
        case auditLog
        /// Everything an account balance is summed from: the account's own opening
        /// balance, its manual adjustments, and the entries that move money in or
        /// out of it.
        case accountBalances

        /// Only the object's type is inspected, never its properties, so invalidated
        /// objects are safe to test here.
        func matches(_ object: NSManagedObject) -> Bool {
            switch self {
            case .groupPermissions:
                return object is LedgerGroup || object is Member || object is LocalMemberIdentity
            case .auditLog:
                return object is AuditEvent
            case .accountBalances:
                return object is LedgerAccount || object is AccountAdjustment || object is LedgerEntry
            }
        }
    }

    /// Whether the notification touched an object in any of the given scopes.
    static func touches(_ notification: Notification, _ scopes: Scope...) -> Bool {
        // A context reset reports `NSInvalidatedAllObjectsKey` instead of listing the
        // objects, so there is nothing to match against and it has to count as a hit.
        if notification.userInfo?[NSInvalidatedAllObjectsKey] != nil { return true }

        let changeKeys = [
            NSInsertedObjectsKey,
            NSUpdatedObjectsKey,
            NSDeletedObjectsKey,
            NSRefreshedObjectsKey,
            NSInvalidatedObjectsKey
        ]
        return changeKeys.contains { key in
            guard let objects = notification.userInfo?[key] as? Set<NSManagedObject> else {
                return false
            }
            return objects.contains { object in
                scopes.contains { $0.matches(object) }
            }
        }
    }
}
