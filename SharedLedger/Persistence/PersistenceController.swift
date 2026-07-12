import CoreData
import CloudKit

final class PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentCloudKitContainer
    private(set) var privateStore: NSPersistentStore!
    private(set) var sharedStore: NSPersistentStore!

    init(inMemory: Bool = false) {
        container = NSPersistentCloudKitContainer(name: "SharedLedger")

        if inMemory {
            let description = NSPersistentStoreDescription()
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

        container.loadPersistentStores { description, error in
            if let error {
                assertionFailure("Persistent store failed to load: \(error.localizedDescription)")
                return
            }

            guard let loadedStore = container.persistentStoreCoordinator.persistentStore(
                for: description.url!
            ) else { return }

            switch description.cloudKitContainerOptions?.databaseScope {
            case .shared:
                sharedStore = loadedStore
            default:
                privateStore = loadedStore
            }
        }

        if inMemory {
            privateStore = container.persistentStoreCoordinator.persistentStores.first
            sharedStore = privateStore
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    func prepareShare(for group: LedgerGroup) async throws -> (CKShare, CKContainer) {
        try await withCheckedThrowingContinuation { continuation in
            container.share([group], to: nil) { _, share, cloudContainer, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let share, let cloudContainer {
                    share[CKShare.SystemFieldKey.title] = group.name
                    continuation.resume(returning: (share, cloudContainer))
                } else {
                    continuation.resume(throwing: SharingError.missingShare)
                }
            }
        }
    }

    private static func storeDescription(
        url: URL,
        configuration: String,
        databaseScope: CKDatabase.Scope
    ) -> NSPersistentStoreDescription {
        let description = NSPersistentStoreDescription(url: url)
        description.configuration = configuration
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
