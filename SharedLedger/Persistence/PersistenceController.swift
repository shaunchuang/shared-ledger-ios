import CoreData
import CloudKit

final class PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentCloudKitContainer
    private(set) var privateStore: NSPersistentStore!
    private(set) var sharedStore: NSPersistentStore!
    private var remoteChangeObserver: NSObjectProtocol?
    private var isRepairingData = false
    private var shouldRepeatDataRepair = false

    init(inMemory: Bool = false) {
        container = NSPersistentCloudKitContainer(name: "SharedLedger")

        if inMemory {
            let description = NSPersistentStoreDescription(url: URL(fileURLWithPath: "/dev/null"))
            description.type = NSInMemoryStoreType
            container.persistentStoreDescriptions = [description]
        } else {
            let storeDirectory = NSPersistentContainer.defaultDirectoryURL()
            let privateDescription = Self.storeDescription(
                url: storeDirectory.appendingPathComponent("SharedLedger-private.sqlite"),
                configuration: "Private",
                databaseScope: .private
            )
            let sharedDescription = Self.storeDescription(
                url: storeDirectory.appendingPathComponent("SharedLedger-shared.sqlite"),
                configuration: "Shared",
                databaseScope: .shared
            )
            container.persistentStoreDescriptions = [privateDescription, sharedDescription]
        }

        container.persistentStoreDescriptions.forEach { description in
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        }

        let storeLoadGroup = DispatchGroup()
        for _ in container.persistentStoreDescriptions {
            storeLoadGroup.enter()
        }

        container.loadPersistentStores { description, error in
            defer { storeLoadGroup.leave() }
            if let error {
                assertionFailure("Persistent store failed to load: \(error.localizedDescription)")
                return
            }

            guard let url = description.url,
                  let loadedStore = self.container.persistentStoreCoordinator.persistentStore(for: url)
            else { return }

            switch description.cloudKitContainerOptions?.databaseScope {
            case .shared:
                self.sharedStore = loadedStore
            default:
                self.privateStore = loadedStore
            }
        }

        if inMemory {
            privateStore = container.persistentStoreCoordinator.persistentStores.first
            sharedStore = privateStore
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        storeLoadGroup.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.scheduleDataRepair()
            if !inMemory {
                self.remoteChangeObserver = NotificationCenter.default.addObserver(
                    forName: .NSPersistentStoreRemoteChange,
                    object: self.container.persistentStoreCoordinator,
                    queue: .main
                ) { [weak self] _ in
                    self?.scheduleDataRepair()
                }
            }
        }
    }

    deinit {
        if let remoteChangeObserver {
            NotificationCenter.default.removeObserver(remoteChangeObserver)
        }
    }
    
    @MainActor
    func prepareShare(for group: LedgerGroup) async throws -> (CKShare, CKContainer) {
        let shareTitle = group.name ?? "Shared Ledger 群組"

        return try await withCheckedThrowingContinuation { continuation in
            container.share([group], to: nil) { _, share, cloudContainer, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let share, let cloudContainer {
                    share[CKShare.SystemFieldKey.title] = shareTitle
                    continuation.resume(returning: (share, cloudContainer))
                } else {
                    continuation.resume(throwing: SharingError.missingShare)
                }
            }
        }
    }

    func store(for object: NSManagedObject) -> NSPersistentStore {
        object.objectID.persistentStore ?? privateStore
    }

    private func scheduleDataRepair() {
        if isRepairingData {
            shouldRepeatDataRepair = true
            return
        }
        isRepairingData = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isRepairingData = false }
            repeat {
                self.shouldRepeatDataRepair = false
                do {
                    try await BookRepository(persistence: self).backfillMissingBookRelationships()
                    try await AccountRepository(persistence: self).migrateLegacyBalanceAdjustments()
                } catch {
                    assertionFailure("Unable to repair migrated ledger data: \(error.localizedDescription)")
                }
            } while self.shouldRepeatDataRepair
        }
    }

    private static func storeDescription(
        url: URL,
        configuration: String,
        databaseScope: CKDatabase.Scope
    ) -> NSPersistentStoreDescription {
        let description = NSPersistentStoreDescription(url: url)
        description.configuration = configuration
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        let options = NSPersistentCloudKitContainerOptions(
            containerIdentifier: "iCloud.com.shaunchuang.SharedLedger"
        )
        options.databaseScope = databaseScope
        description.cloudKitContainerOptions = options
        return description
    }

    private enum SharingError: LocalizedError {
        case missingShare

        var errorDescription: String? {
            "CloudKit did not return a share."
        }
    }
}
