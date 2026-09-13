import Combine
import CoreData
import Foundation
import WidgetKit

@MainActor
final class LedgerWidgetCoordinator: ObservableObject {
    static let shared = LedgerWidgetCoordinator(persistence: .shared)
    private let persistence: PersistenceController
    private let store: LedgerWidgetStore
    private var changes: AnyCancellable?

    init(persistence: PersistenceController, store: LedgerWidgetStore = .shared) {
        self.persistence = persistence
        self.store = store
    }

    func start() {
        guard store.isAvailable else { return }
        if changes == nil {
            let context = persistence.container.viewContext
            changes = Publishers.Merge3(
                NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave, object: context),
                NotificationCenter.default.publisher(for: .NSManagedObjectContextDidMergeChangesObjectIDs, object: context),
                NotificationCenter.default.publisher(for: NSNotification.Name.NSSystemTimeZoneDidChange)
            )
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
        refresh()
    }

    func refresh() {
        // Never publish an unsaved form or a half-completed repository operation.
        guard store.isAvailable, !persistence.container.viewContext.hasChanges else { return }
        do {
            let snapshot = try store.selectedBookID.flatMap {
                try LedgerWidgetSnapshotService(persistence: persistence).snapshot(bookID: $0)
            }
            try store.save(snapshot)
            WidgetCenter.shared.reloadTimelines(ofKind: LedgerWidgetStore.widgetKind)
        } catch {
            // Keep the timestamped last successful snapshot on transient failures.
            // Missing/archived books return nil and remove the snapshot above.
        }
    }
}
