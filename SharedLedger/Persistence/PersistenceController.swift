import CoreData
import CloudKit

final class PersistenceController {
    static let shared = PersistenceController()
    private static let cloudKitContainerIdentifier = "iCloud.com.shaunchuang.SharedLedger"

    typealias ShareFetcher = (
        [NSManagedObjectID]
    ) throws -> [NSManagedObjectID: CKShare]
    typealias AccountStatusProvider = () async throws -> CKAccountStatus

    /// 以 `-initialize-cloudkit-schema` 啟動參數執行時，會把目前 Core Data 模型的
    /// record types 寫入 CloudKit Development schema；之後仍須在 CloudKit Console
    /// 手動將 Development schema 部署到 Production，正式版才能同步新 entity。
    static var shouldInitializeCloudKitSchema: Bool {
        #if DEBUG
        CommandLine.arguments.contains("-initialize-cloudkit-schema")
        #else
        false
        #endif
    }

    let container: NSPersistentCloudKitContainer
    private(set) var privateStore: NSPersistentStore!
    private(set) var sharedStore: NSPersistentStore!
    private let shareFetcher: ShareFetcher?
    private let accountStatusProvider: AccountStatusProvider?
    private var remoteChangeObserver: NSObjectProtocol?
    private var isRepairingData = false
    private var shouldRepeatDataRepair = false

    init(
        inMemory: Bool = false,
        shareFetcher: ShareFetcher? = nil,
        accountStatusProvider: AccountStatusProvider? = nil,
        inMemoryConfigurations: [String]? = nil
    ) {
        self.shareFetcher = shareFetcher
        self.accountStatusProvider = accountStatusProvider
        container = NSPersistentCloudKitContainer(name: "SharedLedger")

        if let inMemoryConfigurations {
            container.persistentStoreDescriptions = inMemoryConfigurations.map { configuration in
                let description = NSPersistentStoreDescription(
                    url: URL(fileURLWithPath: "/dev/null-SharedLedger-\(configuration)-\(UUID().uuidString)")
                )
                description.type = NSInMemoryStoreType
                description.configuration = configuration
                return description
            }
        } else if inMemory {
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
            if Self.shouldInitializeCloudKitSchema {
                // initializeCloudKitSchema(options:) 不支援 .shared scope 的 store，
                // 初始化 schema 時只載入 private store。
                container.persistentStoreDescriptions = [privateDescription]
            } else {
                let sharedDescription = Self.storeDescription(
                    url: storeDirectory.appendingPathComponent("SharedLedger-shared.sqlite"),
                    configuration: "Shared",
                    databaseScope: .shared
                )
                container.persistentStoreDescriptions = [privateDescription, sharedDescription]
            }
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

            switch (description.configuration, description.cloudKitContainerOptions?.databaseScope) {
            case ("Shared", _), (_, .shared):
                self.sharedStore = loadedStore
            default:
                self.privateStore = loadedStore
            }
        }

        if inMemory || inMemoryConfigurations != nil {
            storeLoadGroup.wait()
        }

        if inMemory, inMemoryConfigurations == nil {
            privateStore = container.persistentStoreCoordinator.persistentStores.first
            sharedStore = privateStore
        } else if inMemoryConfigurations != nil {
            privateStore = container.persistentStoreCoordinator.persistentStores.first {
                $0.configurationName == "Private"
            }
            sharedStore = container.persistentStoreCoordinator.persistentStores.first {
                $0.configurationName == "Shared"
            }
        }

        if Self.shouldInitializeCloudKitSchema {
            sharedStore = privateStore
            do {
                try container.initializeCloudKitSchema(options: [])
            } catch {
                assertionFailure("CloudKit schema initialization failed: \(error)")
            }
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
        let objectID = group.objectID
        let cloudContainer = CKContainer(identifier: Self.cloudKitContainerIdentifier)

        switch try await accountStatus(for: cloudContainer) {
        case .available:
            break
        case .noAccount:
            throw SharingError.noICloudAccount
        case .restricted:
            throw SharingError.restrictedAccount
        case .couldNotDetermine, .temporarilyUnavailable:
            throw SharingError.iCloudUnavailable
        @unknown default:
            throw SharingError.iCloudUnavailable
        }

        let existingShare: CKShare?
        if objectID.isTemporaryID {
            existingShare = nil
        } else if let shareFetcher {
            existingShare = try shareFetcher([objectID])[objectID]
        } else {
            existingShare = try container.fetchShares(matching: [objectID])[objectID]
        }

        if let existingShare {
            existingShare[CKShare.SystemFieldKey.title] = shareTitle
            return (existingShare, cloudContainer)
        }

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

    private func accountStatus(for cloudContainer: CKContainer) async throws -> CKAccountStatus {
        if let accountStatusProvider {
            return try await accountStatusProvider()
        }

        return try await withCheckedThrowingContinuation { continuation in
            cloudContainer.accountStatus { status, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: status)
                }
            }
        }
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
                    try await CategoryRepository(persistence: self).repairLegacyCategoryAssignments()
                    try await AccountRepository(persistence: self).migrateLegacyBalanceAdjustments()
                    try await EntryRepository(persistence: self).migrateLegacyPayments()
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
            containerIdentifier: cloudKitContainerIdentifier
        )
        options.databaseScope = databaseScope
        description.cloudKitContainerOptions = options
        return description
    }

    enum SharingError: LocalizedError {
        case missingShare
        case noICloudAccount
        case restrictedAccount
        case iCloudUnavailable

        var errorDescription: String? {
            switch self {
            case .missingShare:
                return "CloudKit 未回傳共享邀請，請稍後再試。"
            case .noICloudAccount:
                return "此裝置尚未登入 iCloud，請先在「設定」登入 Apple 帳號後再邀請成員。"
            case .restrictedAccount:
                return "這個 Apple 帳號的 iCloud 功能受到限制，暫時無法建立共享邀請。"
            case .iCloudUnavailable:
                return "目前無法連線到 iCloud，請確認網路與 iCloud 狀態後再試。"
            }
        }
    }
}
