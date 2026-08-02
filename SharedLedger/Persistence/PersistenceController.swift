import CoreData
import CloudKit

final class PersistenceController {
    /// The app target hosts the unit tests, so this is also constructed when the
    /// test bundle launches. A CloudKit-backed store cannot load on a simulator
    /// without a signed-in iCloud account, and the failure path trips
    /// `assertionFailure`, which traps before any test can run. Tests build their
    /// own `PersistenceController(inMemory: true)`, so the shared instance only has
    /// to launch cleanly here.
    static let shared = PersistenceController(inMemory: isRunningTests)

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
    /// 這個 App 的 CloudKit 容器。同步狀態監看也要問同一個容器的帳號狀態，
    /// 所以識別碼在這裡只保留一份。
    static let cloudKitContainerIdentifier = "iCloud.com.shaunchuang.SharedLedger"

    typealias ShareFetcher = (
        [NSManagedObjectID]
    ) throws -> [NSManagedObjectID: CKShare]
    typealias AccountStatusProvider = () async throws -> CKAccountStatus

    /// 以 `-initialize-cloudkit-schema` 啟動參數執行時，會把目前 Core Data 模型的
    /// record types 寫入 CloudKit Development schema；之後仍須在 CloudKit Console
    /// 手動將 Development schema 部署到 Production，正式版才能同步新 entity。
    /// Loaded once for the whole process.
    ///
    /// `NSPersistentCloudKitContainer(name:)` reads the `.momd` from the bundle on
    /// every instantiation, so each `PersistenceController` used to produce a fresh
    /// `NSManagedObjectModel` whose entities all claim the same generated subclasses.
    /// Core Data then logs `Multiple NSEntityDescriptions claim the NSManagedObject
    /// subclass …` and `+entity` stops being able to disambiguate — harmless here but
    /// loud enough to bury a real Core Data error in a test log. Sharing one model
    /// across coordinators is supported and removes the ambiguity.
    ///
    /// Tests that need the model the app actually runs on must use this rather than
    /// loading the `.momd` again: a model owned by a live coordinator is immutable,
    /// and a second copy would re-create the ambiguity this exists to avoid.
    static let managedObjectModel: NSManagedObjectModel = {
        guard let url = Bundle(for: PersistenceController.self)
            .url(forResource: "SharedLedger", withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: url)
        else {
            fatalError("Unable to load the SharedLedger managed object model")
        }
        return model
    }()

    static var shouldInitializeCloudKitSchema: Bool {
        #if DEBUG
        CommandLine.arguments.contains("-initialize-cloudkit-schema")
        #else
        false
        #endif
    }

    /// `-initialize-cloudkit-schema` 的前置檢查結果。
    ///
    /// `initializeCloudKitSchema(options:)` 需要 mirroring delegate 先初始化成功，
    /// 而 delegate 沒有 iCloud 帳號就無法初始化。少了這個檢查時，未登入 iCloud 的
    /// 裝置或模擬器只會拿到一層層包起來的
    /// `CKAccountStatusNoAccount` Core Data 錯誤，看起來像 App 壞掉，實際上只是還沒登入。
    enum SchemaInitializationReadiness: Equatable {
        case ready
        /// 不具備寫入 schema 的條件，附上可以照著做的說明。
        case blocked(String)
    }

    /// 把 iCloud 帳號狀態轉成可讀的前置檢查結果；`nil` 代表查詢逾時或失敗。
    static func schemaInitializationReadiness(
        for status: CKAccountStatus?
    ) -> SchemaInitializationReadiness {
        let undetermined = "目前無法確認 iCloud 帳號狀態，請確認網路與 iCloud 服務狀態後再重新執行。"
        guard let status else { return .blocked(undetermined) }

        switch status {
        case .available:
            return .ready
        case .noAccount:
            return .blocked(
                """
                此裝置尚未登入 iCloud，無法寫入 CloudKit Development schema。
                請先在「設定 → 登入 iPhone」（模擬器為 Settings → Sign in to your iPhone）登入 \
                Apple 帳號並開啟 iCloud Drive，再以 -initialize-cloudkit-schema 重新執行一次。
                """
            )
        case .restricted:
            return .blocked(
                "這個 Apple 帳號的 iCloud 功能受到限制（家長控制或裝置管理設定），無法寫入 CloudKit Development schema。"
            )
        case .couldNotDetermine, .temporarilyUnavailable:
            return .blocked(undetermined)
        @unknown default:
            return .blocked(
                "iCloud 帳號狀態為未知值，已略過 CloudKit schema 初始化。"
            )
        }
    }

    /// 只在 `-initialize-cloudkit-schema` 這個開發者維護模式下呼叫。
    ///
    /// 先確認 iCloud 帳號可用再寫入 schema，並且不論成功或失敗都只輸出說明、不中斷執行：
    /// 這條路徑沒有使用者要保護，把 App 停在 `assertionFailure` 只會讓「還沒登入 iCloud」
    /// 這種環境問題看起來像程式崩潰。寫入是否真的完成，仍要照 `Docs/ARCHITECTURE.md`
    /// 的步驟到 CloudKit Console 確認後才能部署到 Production。
    private static func initializeCloudKitSchemaIfPossible(on container: NSPersistentCloudKitContainer) {
        if case let .blocked(reason) = schemaInitializationReadiness(for: currentAccountStatus()) {
            report(schema: "已略過 CloudKit schema 初始化。\n\(reason)")
            return
        }

        do {
            try container.initializeCloudKitSchema(options: [])
            report(
                schema: """
                CloudKit Development schema 已寫入。
                接著到 CloudKit Console 確認 CD_ 開頭的 record types 與欄位齊全，再執行 Deploy Schema Changes…；
                完成後請移除 -initialize-cloudkit-schema 啟動參數再正常執行 App。
                """
            )
        } catch {
            report(
                schema: """
                CloudKit schema 初始化失敗，App 會繼續以未更新的 schema 執行。
                \(error)
                """
            )
        }
    }

    /// 同步取得 iCloud 帳號狀態。這是啟動時的一次性維護檢查，`initializeCloudKitSchema`
    /// 本身也是同步阻塞呼叫，所以在這裡等待不會比原本多擋住什麼；逾時或查詢失敗回傳 `nil`。
    private static func currentAccountStatus(timeout: TimeInterval = 15) -> CKAccountStatus? {
        let semaphore = DispatchSemaphore(value: 0)
        var resolved: CKAccountStatus?
        CKContainer(identifier: cloudKitContainerIdentifier).accountStatus { status, error in
            if error == nil {
                resolved = status
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return resolved
    }

    private static func report(schema message: String) {
        print("[CloudKit schema] \(message)")
    }

    let container: NSPersistentCloudKitContainer
    private(set) var privateStore: NSPersistentStore!
    private(set) var sharedStore: NSPersistentStore!
    private let shareFetcher: ShareFetcher?
    /// Device-local cache of the last resolved CloudKit write permission per group,
    /// held here so tests can isolate it from the shared user defaults.
    let cloudPermissionCache: CloudPermissionCache
    private let accountStatusProvider: AccountStatusProvider?
    private var remoteChangeObserver: NSObjectProtocol?
    private var isRepairingData = false
    private var shouldRepeatDataRepair = false

    init(
        inMemory: Bool = false,
        shareFetcher: ShareFetcher? = nil,
        accountStatusProvider: AccountStatusProvider? = nil,
        inMemoryConfigurations: [String]? = nil,
        cloudPermissionCache: CloudPermissionCache = .standard
    ) {
        self.shareFetcher = shareFetcher
        self.accountStatusProvider = accountStatusProvider
        self.cloudPermissionCache = cloudPermissionCache
        container = NSPersistentCloudKitContainer(
            name: "SharedLedger",
            managedObjectModel: Self.managedObjectModel
        )

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
            // schema 初始化要對已載入的 private store 進行。這些 description 沒有開
            // shouldAddStoreAsynchronously，載入完成前 loadPersistentStores 不會返回，
            // 所以這個 wait 目前是立即通過的；寫出來是為了讓「先載入完 store 再初始化
            // schema」這個相依關係留在程式碼裡，而不是依賴預設值。
            storeLoadGroup.wait()
            sharedStore = privateStore
            Self.initializeCloudKitSchemaIfPossible(on: container)
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        storeLoadGroup.notify(queue: .main) { [weak self] in
            guard let self else { return }
            // 背景資料修復會在 main actor 上非同步改動 Core Data，並在失敗時觸發
            // assertionFailure。跑測試時這等於有一條隨機時機的執行緒在改共用狀態，
            // 崩潰還會算到當下剛好在執行的測試頭上。測試都各自明確驅動需要的
            // migration，所以這裡直接不啟動。
            if !Self.isRunningTests {
                self.scheduleDataRepair()
            }
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
        let shareTitle = group.name ?? LedgerStringKey.groupShareDefaultTitle.string()
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

        let existingShare = try existingShare(for: objectID)

        if let existingShare {
            existingShare[CKShare.SystemFieldKey.title] = shareTitle
            try bindCurrentParticipantIfAvailable(from: existingShare, to: group)
            return (existingShare, cloudContainer)
        }

        let result: (CKShare, CKContainer) = try await withCheckedThrowingContinuation { continuation in
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
        try bindCurrentParticipantIfAvailable(from: result.0, to: group)
        return result
    }

    func store(for object: NSManagedObject) -> NSPersistentStore {
        object.objectID.persistentStore ?? privateStore
    }

    /// The locally cached `CKShare` for an object, honouring an injected
    /// `ShareFetcher` so permission logic stays testable without CloudKit.
    func existingShare(for objectID: NSManagedObjectID) throws -> CKShare? {
        guard !objectID.isTemporaryID else { return nil }
        if let shareFetcher {
            return try shareFetcher([objectID])[objectID]
        }
        return try container.fetchShares(matching: [objectID])[objectID]
    }

    /// 接受其他成員送出的 CloudKit 共享邀請，並把記錄匯入 shared store。
    /// AppDelegate 與 SceneDelegate 都會呼叫這個方法，確保無論系統
    /// 走哪一條 callback，接受流程都一致。
    func acceptShare(
        metadata: CKShare.Metadata,
        completion: ((Error?) -> Void)? = nil
    ) {
        container.acceptShareInvitations(
            from: [metadata],
            into: sharedStore
        ) { _, error in
            if let error {
                assertionFailure("Unable to accept CloudKit share: \(error.localizedDescription)")
            }
            completion?(error)
        }
    }

    @MainActor
    private func bindCurrentParticipantIfAvailable(from share: CKShare, to group: LedgerGroup) throws {
        guard let participant = share.currentUserParticipant,
              let member = CurrentMemberIdentityRepository(persistence: self).currentMember(in: group)
        else { return }

        if let existingParticipantID = member.cloudParticipantID,
           existingParticipantID != participant.participantID {
            throw SharingError.participantIdentityMismatch
        }
        guard member.role != MemberRole.owner.rawValue || participant.role == .owner else {
            throw SharingError.participantIdentityMismatch
        }

        member.cloudParticipantID = participant.participantID
        if container.viewContext.hasChanges {
            do {
                try container.viewContext.save()
            } catch {
                container.viewContext.rollback()
                throw error
            }
        }
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
                let writableGroupIDs = self.repairableGroupIDs()
                do {
                    try await BookRepository(persistence: self)
                        .backfillMissingBookRelationships(in: writableGroupIDs)
                    try await CategoryRepository(persistence: self)
                        .repairLegacyCategoryAssignments(in: writableGroupIDs)
                    try await AccountRepository(persistence: self)
                        .migrateLegacyBalanceAdjustments(in: writableGroupIDs)
                    try await EntryRepository(persistence: self)
                        .migrateLegacyPayments(in: writableGroupIDs)
                } catch {
                    assertionFailure("Unable to repair migrated ledger data: \(error.localizedDescription)")
                }

                // A CloudKit import posts remote-change notifications in bursts, and
                // every one of them sets `shouldRepeatDataRepair`. Without this pause
                // the loop runs a whole pass — a group fetch plus a share lookup per
                // group, then four full-table scans — back to back for as long as the
                // sync lasts, and because it all runs on the main actor the UI never
                // gets a turn: tapping a tab does nothing until the sync settles.
                // Waiting lets the rest of the burst collapse into the single pass
                // that follows.
                if self.shouldRepeatDataRepair {
                    try? await Task.sleep(nanoseconds: NSEC_PER_SEC)
                }
            } while self.shouldRepeatDataRepair
        }
    }

    /// Groups this device may actually write to.
    ///
    /// The repairs create real synced objects — payments, adjustments, category
    /// assignments — and payments in particular are the source of truth for
    /// settlement. Running them for a group the current user cannot write to would
    /// produce local rows CloudKit then refuses to export, so the device would
    /// silently compute different settlements from the owner. Reads stay unaffected:
    /// a group left out here is simply not repaired, and the owner's own device
    /// repairs it.
    @MainActor
    private func repairableGroupIDs() -> Set<UUID> {
        let request = NSFetchRequest<LedgerGroup>(entityName: "LedgerGroup")
        guard let groups = try? container.viewContext.fetch(request) else { return [] }
        let permissions = EffectivePermissionRepository(persistence: self)
        return Set(
            groups.compactMap { group -> UUID? in
                guard let id = group.id,
                      permissions.permission(in: group).canEditTransactions
                else { return nil }
                return id
            }
        )
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
        case participantIdentityMismatch

        var errorDescription: String? {
            switch self {
            case .missingShare:
                return LedgerStringKey.errorShareMissingShare.string()
            case .noICloudAccount:
                return LedgerStringKey.errorShareNotSignedIn.string()
            case .restrictedAccount:
                return LedgerStringKey.errorShareAccountRestricted.string()
            case .iCloudUnavailable:
                return LedgerStringKey.errorShareUnavailable.string()
            case .participantIdentityMismatch:
                return LedgerStringKey.errorShareMismatchedParticipant.string()
            }
        }
    }
}
