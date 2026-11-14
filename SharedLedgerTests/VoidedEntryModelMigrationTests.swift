import CoreData
import XCTest
@testable import SharedLedger

/// V10 把兩件本來只能從稽核紀錄推導的事，變成交易與稽核事件自己的欄位。
///
/// 這兩個欄位都要先部署到 CloudKit Production schema，帶著 V10 的版本才能同步；
/// 因此這裡同時守住遷移路徑與這次 schema 變更的確切範圍。
final class VoidedEntryModelMigrationTests: XCTestCase {
    func testV9ToV10LightweightMappingCanBeInferred() throws {
        XCTAssertNoThrow(
            try NSMappingModel.inferredMappingModel(
                forSourceModel: try loadVersionedModel(named: "SharedLedgerV9"),
                destinationModel: try loadVersionedModel(named: "SharedLedgerV10")
            )
        )
    }

    func testV10AddsOptionalAttributesWithoutDefaults() throws {
        let v10 = try loadVersionedModel(named: "SharedLedgerV10")

        for (entity, attributeName, type) in [
            ("LedgerEntry", "voidedAt", NSAttributeType.dateAttributeType),
            ("AuditEvent", "actorMemberID", NSAttributeType.UUIDAttributeType)
        ] {
            let attribute = try XCTUnwrap(
                v10.entitiesByName[entity]?.attributesByName[attributeName],
                "\(entity).\(attributeName) 不存在"
            )
            XCTAssertEqual(attribute.attributeType, type, entity)
            // CloudKit 不接受沒有預設值的必填欄位，而這兩個欄位都沒有合理的預設值：
            // 升級前的資料就是沒有，那個 `nil` 本身就是答案。
            XCTAssertTrue(attribute.isOptional, entity)
            XCTAssertNil(attribute.defaultValue, entity)
        }
    }

    func testV10ChangesNothingElseComparedToV9() throws {
        let v9 = try loadVersionedModel(named: "SharedLedgerV9")
        let v10 = try loadVersionedModel(named: "SharedLedgerV10")

        XCTAssertEqual(Set(v9.entitiesByName.keys), Set(v10.entitiesByName.keys))

        let added = [
            "LedgerEntry": "voidedAt",
            "AuditEvent": "actorMemberID"
        ]
        for (name, v9Entity) in v9.entitiesByName {
            let v10Entity = try XCTUnwrap(v10.entitiesByName[name])
            let expectedAttributes = added[name].map {
                Set(v9Entity.attributesByName.keys).union([$0])
            } ?? Set(v9Entity.attributesByName.keys)

            XCTAssertEqual(
                Set(v10Entity.attributesByName.keys),
                expectedAttributes,
                "\(name) 的欄位超出這次預期的 V10 變更"
            )
            XCTAssertEqual(
                Set(v10Entity.relationshipsByName.keys),
                Set(v9Entity.relationshipsByName.keys),
                "\(name) 的關聯超出這次預期的 V10 變更"
            )
        }
    }

    func testV10IsTheModelTheAppLoads() {
        XCTAssertNotNil(
            loadCurrentModel().entitiesByName["LedgerEntry"]?.attributesByName["voidedAt"],
            "編出來的模型必須是 V10，否則作廢狀態又要回去掃稽核紀錄"
        )
    }

    /// 升級本身不回填。回填由 `EntryRepository.backfillVoidedEntries(in:)` 負責，
    /// 那條路徑同時也要處理混合版本，所以不能只在 migration 做一次。
    func testExistingRowsMigrateWithoutTheNewAttributes() throws {
        let storeURL = try makeTemporaryStoreURL()
        defer { removeStore(at: storeURL) }

        try writeV9Store(at: storeURL) { context in
            let entry = NSEntityDescription.insertNewObject(
                forEntityName: "LedgerEntry",
                into: context
            )
            entry.setValue(UUID(), forKey: "id")
            entry.setValue(NSDecimalNumber.zero, forKey: "amount")
            entry.setValue(EntryKind.expense.rawValue, forKey: "kind")
            entry.setValue("", forKey: "note")
            entry.setValue(SplitMode.equal.rawValue, forKey: "splitMode")

            let audit = NSEntityDescription.insertNewObject(
                forEntityName: "AuditEvent",
                into: context
            )
            audit.setValue(UUID(), forKey: "id")
            audit.setValue("transaction.voided", forKey: "action")
            audit.setValue("小明", forKey: "actorDisplayName")
            audit.setValue("作廢交易", forKey: "summary")
            audit.setValue(Date(), forKey: "createdAt")
        }

        let migrated = try openMigratedV10Store(at: storeURL)
        defer { migrated.close() }

        let entry = try XCTUnwrap(
            try migrated.context
                .fetch(NSFetchRequest<NSManagedObject>(entityName: "LedgerEntry")).first
        )
        let audit = try XCTUnwrap(
            try migrated.context
                .fetch(NSFetchRequest<NSManagedObject>(entityName: "AuditEvent")).first
        )

        XCTAssertNil(entry.value(forKey: "voidedAt"))
        XCTAssertNil(audit.value(forKey: "actorMemberID"))
        // 既有欄位一個都不能掉，特別是作廢當下寫進 summary 的那份快照——回填要靠它。
        XCTAssertEqual(audit.value(forKey: "action") as? String, "transaction.voided")
        XCTAssertEqual(audit.value(forKey: "actorDisplayName") as? String, "小明")
        XCTAssertEqual(audit.value(forKey: "summary") as? String, "作廢交易")
    }

    // MARK: - Helpers

    private func makeTemporaryStoreURL() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SharedLedgerVoidedMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("SharedLedger.sqlite")
    }

    private func removeStore(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func writeV9Store(
        at url: URL,
        populate: (NSManagedObjectContext) throws -> Void
    ) throws {
        let coordinator = NSPersistentStoreCoordinator(
            managedObjectModel: try loadVersionedModel(named: "SharedLedgerV9")
        )
        let store = try coordinator.addPersistentStore(
            type: .sqlite,
            configuration: nil,
            at: url
        )

        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        try populate(context)
        try context.save()

        try coordinator.remove(store)
    }

    /// coordinator 要和 context 一起活著，SQLite 檔案才能在下一次開啟前被釋放。
    private struct OpenStore {
        let coordinator: NSPersistentStoreCoordinator
        let store: NSPersistentStore
        let context: NSManagedObjectContext

        func close() {
            try? coordinator.remove(store)
        }
    }

    private func openMigratedV10Store(at url: URL) throws -> OpenStore {
        let coordinator = NSPersistentStoreCoordinator(
            managedObjectModel: try loadVersionedModel(named: "SharedLedgerV10")
        )
        let store = try coordinator.addPersistentStore(
            type: .sqlite,
            configuration: nil,
            at: url,
            options: [
                NSMigratePersistentStoresAutomaticallyOption: true,
                NSInferMappingModelAutomaticallyOption: true
            ]
        )

        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return OpenStore(coordinator: coordinator, store: store, context: context)
    }
}

/// 作廢狀態從稽核紀錄補回 `LedgerEntry.voidedAt`。
///
/// 這條路徑不只服務升級：還沒更新的裝置作廢一筆交易時，一樣只寫得出稽核事件，
/// 同步過來就是「有作廢稽核、`voidedAt` 是 `nil`」的交易。測試以「把 `voidedAt`
/// 清掉、只留稽核事件」重現這個狀態，兩種來源在這台裝置上看起來完全一樣。
@MainActor
final class VoidedEntryBackfillTests: XCTestCase {
    func testBackfillMarksEntriesVoidedFromTheAuditEventAlone() async throws {
        let fixture = try makeFixture()
        let groupIDs: Set<UUID> = [try XCTUnwrap(fixture.group.id)]
        let entry = try fixture.makeEntry(note: "舊裝置作廢的")
        try fixture.repository.voidEntry(entry)
        let voidedAt = try XCTUnwrap(entry.voidedAt)

        try fixture.simulateVoidWrittenByOlderVersion(entry)
        XCTAssertFalse(fixture.repository.isVoided(entry))

        try await fixture.repository.backfillVoidedEntries(in: groupIDs)

        XCTAssertTrue(fixture.repository.isVoided(entry))
        // 作廢時間取自稽核事件，不是修復當下的時間：作廢發生的時刻不該被升級改寫。
        XCTAssertEqual(entry.voidedAt, voidedAt)
    }

    func testBackfillIsIdempotentAndLeavesLiveEntriesAlone() async throws {
        let fixture = try makeFixture()
        let groupIDs: Set<UUID> = [try XCTUnwrap(fixture.group.id)]
        let voided = try fixture.makeEntry(note: "作廢")
        let live = try fixture.makeEntry(note: "還在")
        try fixture.repository.voidEntry(voided)
        try fixture.simulateVoidWrittenByOlderVersion(voided)

        try await fixture.repository.backfillVoidedEntries(in: groupIDs)
        let firstPass = try XCTUnwrap(voided.voidedAt)
        try await fixture.repository.backfillVoidedEntries(in: groupIDs)

        XCTAssertEqual(voided.voidedAt, firstPass, "重跑修復不該把作廢時間往後推")
        XCTAssertNil(live.voidedAt, "沒有作廢稽核的交易不該被標記")
    }

    /// 修復會建立會同步出去的變更，所以和其他幾個修復一樣只跑可寫入的群組。
    func testBackfillSkipsGroupsThisDeviceCannotWrite() async throws {
        let fixture = try makeFixture()
        let entry = try fixture.makeEntry(note: "作廢")
        try fixture.repository.voidEntry(entry)
        try fixture.simulateVoidWrittenByOlderVersion(entry)

        try await fixture.repository.backfillVoidedEntries(in: [])

        XCTAssertNil(entry.voidedAt)
    }

    // MARK: - Helpers

    private func makeFixture() throws -> Fixture {
        let persistence = PersistenceController(inMemory: true)
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(name: "家庭", ownerDisplayName: "小明", currencyCode: "TWD")
        )
        let owner = try XCTUnwrap((group.members as? Set<Member>)?.first)
        let book = try XCTUnwrap(BookRepository(persistence: persistence).defaultBook(in: group))
        let account = try AccountRepository(persistence: persistence).createAccount(
            from: AccountDraft(name: "現金"),
            in: group
        )
        try persistence.container.viewContext.save()
        return Fixture(
            persistence: persistence,
            group: group,
            book: book,
            account: account,
            owner: owner,
            repository: EntryRepository(persistence: persistence)
        )
    }

    @MainActor
    private struct Fixture {
        let persistence: PersistenceController
        let group: LedgerGroup
        let book: LedgerBook
        let account: LedgerAccount
        let owner: Member
        let repository: EntryRepository

        func makeEntry(note: String) throws -> LedgerEntry {
            let ownerID = try XCTUnwrap(owner.id)
            return try repository.createEntry(
                from: TransactionDraft(
                    kind: .expense,
                    amountText: "300",
                    note: note,
                    sourceAccountID: account.id,
                    payerMemberID: ownerID,
                    splitMemberIDs: [ownerID]
                ),
                in: book,
                accounts: [account],
                categories: [],
                members: [owner]
            )
        }

        /// V9 的作廢只寫得出稽核事件與歸零的金額，寫不出 `voidedAt`。
        func simulateVoidWrittenByOlderVersion(_ entry: LedgerEntry) throws {
            entry.voidedAt = nil
            try persistence.container.viewContext.save()
        }
    }
}
