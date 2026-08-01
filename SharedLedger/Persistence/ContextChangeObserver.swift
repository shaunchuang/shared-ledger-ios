import CoreData
import Foundation

/// Whether a Core Data change notification touched any object the caller cares about.
///
/// Screens that cache derived state in `@State` refresh it from
/// `NSManagedObjectContextObjectsDidChange` instead of recomputing it inside `body`.
/// A `TabView` keeps every tab's views alive while another tab is on screen, and a
/// `NavigationStack` keeps every pushed screen alive behind the top one, so an
/// unfiltered subscription re-derives state for writes the screen does not depend on.
///
/// Only the object's type is inspected, never its properties, so invalidated objects
/// are safe to test here.
func contextChange(
    _ notification: Notification,
    touches isRelevant: (NSManagedObject) -> Bool
) -> Bool {
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
        return objects.contains(where: isRelevant)
    }
}

/// The group, its members, and the private `LocalMemberIdentity` that maps this
/// device's Apple Account onto one of them: everything an effective permission — and
/// the CloudKit participant mapping shown beside it — is resolved from.
func affectsGroupPermissions(_ object: NSManagedObject) -> Bool {
    object is LedgerGroup || object is Member || object is LocalMemberIdentity
}

/// Voided transactions are derived from the group's audit events.
func affectsAuditDerivedState(_ object: NSManagedObject) -> Bool {
    object is AuditEvent
}

/// Everything an account balance is summed from: the account's own opening balance,
/// its manual adjustments, and the entries that move money in or out of it.
func affectsAccountBalances(_ object: NSManagedObject) -> Bool {
    object is LedgerAccount || object is AccountAdjustment || object is LedgerEntry
}
