import CoreData
import XCTest
@testable import SharedLedger

/// V9 讓付款與分攤明細記住自己屬於哪一次交易寫入。
///
/// 這三個欄位要先部署到 CloudKit Production schema，帶著 V9 的版本才能同步；
/// 因此這裡同時守住遷移路徑與這次 schema 變更的確切範圍。
final class EntryRevisionModelMigrationTests: XCTestCase {
    func testV8ToV9LightweightMappingCanBeInferred() throws {
        XCTAssertNoThrow(
            try NSMappingModel.inferredMappingModel(
                forSourceModel: try loadVersionedModel(named: "SharedLedgerV8"),
                destinationModel: try loadVersionedModel(named: "SharedLedgerV9")
            )
        )
    }

    func testV9AddsOptionalRevisionIdentifiersWithoutDefaults() throws {
        let v9 = try loadVersionedModel(named: "SharedLedgerV9")

        for (entity, attributeName) in [
            ("LedgerEntry", "revisionID"),
            ("EntryPayment", "entryRevisionID"),
            ("EntrySplit", "entryRevisionID")
        ] {
            let attribute = try XCTUnwrap(
                v9.entitiesByName[entity]?.attributesByName[attributeName],
                "\(entity).\(attributeName) 不存在"
            )
            XCTAssertEqual(attribute.attributeType, .UUIDAttributeType, entity)
            // CloudKit 不接受沒有預設值的必填欄位，而「屬於哪一次寫入」沒有合理的預設值：
            // 升級前的資料就是沒有，那個 `nil` 本身就是答案。
            XCTAssertTrue(attribute.isOptional, entity)
            XCTAssertNil(attribute.defaultValue, entity)
        }
    }

    func testV9ChangesNothingElseComparedToV8() throws {
        let v8 = try loadVersionedModel(named: "SharedLedgerV8")
        let v9 = try loadVersionedModel(named: "SharedLedgerV9")

        XCTAssertEqual(Set(v8.entitiesByName.keys), Set(v9.entitiesByName.keys))

        let added = [
            "LedgerEntry": "revisionID",
            "EntryPayment": "entryRevisionID",
            "EntrySplit": "entryRevisionID"
        ]
        for (name, v8Entity) in v8.entitiesByName {
            let v9Entity = try XCTUnwrap(v9.entitiesByName[name])
            let expectedAttributes = added[name].map {
                Set(v8Entity.attributesByName.keys).union([$0])
            } ?? Set(v8Entity.attributesByName.keys)

            XCTAssertEqual(
                Set(v9Entity.attributesByName.keys),
                expectedAttributes,
                "\(name) 的欄位超出這次預期的 V9 變更"
            )
            XCTAssertEqual(
                Set(v9Entity.relationshipsByName.keys),
                Set(v8Entity.relationshipsByName.keys),
                "\(name) 的關聯超出這次預期的 V9 變更"
            )
        }
    }

    func testV9IsTheModelTheAppLoads() {
        XCTAssertNotNil(
            loadCurrentModel().entitiesByName["EntrySplit"]?
                .attributesByName["entryRevisionID"],
            "編出來的模型必須是 V9，否則明細記不住自己屬於哪一次寫入"
        )
    }

    func testExistingRowsMigrateWithoutARevisionAndStayLive() throws {
        let storeURL = try makeTemporaryStoreURL()
        defer { removeStore(at: storeURL) }

        try writeV8Store(at: storeURL) { context in
            let entry = NSEntityDescription.insertNewObject(
                forEntityName: "LedgerEntry",
                into: context
            )
            entry.setValue(UUID(), forKey: "id")
            entry.setValue(NSDecimalNumber(value: 1000), forKey: "amount")
            entry.setValue(EntryKind.expense.rawValue, forKey: "kind")
            entry.setValue("", forKey: "note")
            entry.setValue(SplitMode.equal.rawValue, forKey: "splitMode")

            let split = NSEntityDescription.insertNewObject(
                forEntityName: "EntrySplit",
                into: context
            )
            split.setValue(UUID(), forKey: "id")
            split.setValue(NSDecimalNumber(value: 1000), forKey: "amount")
            split.setValue(entry, forKey: "entry")
        }

        let migrated = try openMigratedV9Store(at: storeURL)
        defer { migrated.close() }

        let entry = try XCTUnwrap(
            try migrated.context
                .fetch(NSFetchRequest<NSManagedObject>(entityName: "LedgerEntry")).first
        )
        let split = try XCTUnwrap(
            try migrated.context
                .fetch(NSFetchRequest<NSManagedObject>(entityName: "EntrySplit")).first
        )

        // 舊資料不做回填：交易與明細都留在 `nil`，而 `nil == nil` 代表這筆分攤仍然
        // 屬於交易目前這一版，升級不會讓既有帳務憑空少一筆分攤。
        XCTAssertNil(entry.value(forKey: "revisionID"))
        XCTAssertNil(split.value(forKey: "entryRevisionID"))
        XCTAssertEqual(
            EntryRevision.live(
                [split],
                of: entry.value(forKey: "revisionID") as? UUID,
                revision: { $0.value(forKey: "entryRevisionID") as? UUID }
            ).count,
            1
        )
    }

    // MARK: - Helpers

    private func makeTemporaryStoreURL() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SharedLedgerRevisionMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("SharedLedger.sqlite")
    }

    private func removeStore(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func writeV8Store(
        at url: URL,
        populate: (NSManagedObjectContext) throws -> Void
    ) throws {
        let coordinator = NSPersistentStoreCoordinator(
            managedObjectModel: try loadVersionedModel(named: "SharedLedgerV8")
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

    private func openMigratedV9Store(at url: URL) throws -> OpenStore {
        let coordinator = NSPersistentStoreCoordinator(
            managedObjectModel: try loadVersionedModel(named: "SharedLedgerV9")
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
