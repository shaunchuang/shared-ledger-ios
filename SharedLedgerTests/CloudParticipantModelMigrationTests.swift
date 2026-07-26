import CoreData
import XCTest
@testable import SharedLedger

/// V8 adds `Member.cloudParticipantID` so an App member can be correlated with a
/// stable `CKShare.Participant`. The CloudKit schema for that attribute has to be
/// deployed to Production before a build carrying V8 ships, so these tests guard
/// both the migration path and the exact shape of the schema change.
final class CloudParticipantModelMigrationTests: XCTestCase {
    func testV7ToV8LightweightMappingCanBeInferred() throws {
        let source = try model(named: "SharedLedgerV7")
        let destination = try model(named: "SharedLedgerV8")

        XCTAssertNoThrow(
            try NSMappingModel.inferredMappingModel(
                forSourceModel: source,
                destinationModel: destination
            )
        )
    }

    func testV8AddsAnOptionalCloudParticipantIDToMember() throws {
        let v7 = try model(named: "SharedLedgerV7")
        let v8 = try model(named: "SharedLedgerV8")

        XCTAssertNil(v7.entitiesByName["Member"]?.attributesByName["cloudParticipantID"])

        let attribute = try XCTUnwrap(
            v8.entitiesByName["Member"]?.attributesByName["cloudParticipantID"]
        )
        XCTAssertEqual(attribute.attributeType, .stringAttributeType)
        // CloudKit rejects non-optional attributes without a default value, and a
        // participant identifier has no meaningful default.
        XCTAssertTrue(attribute.isOptional)
        XCTAssertNil(attribute.defaultValue)
    }

    /// The CloudKit Development schema is generated from the current model, so any
    /// unnoticed extra change here becomes an extra Production deployment step.
    func testV8ChangesNothingElseComparedToV7() throws {
        let v7 = try model(named: "SharedLedgerV7")
        let v8 = try model(named: "SharedLedgerV8")

        XCTAssertEqual(
            Set(v7.entitiesByName.keys),
            Set(v8.entitiesByName.keys)
        )

        for (name, v7Entity) in v7.entitiesByName {
            let v8Entity = try XCTUnwrap(v8.entitiesByName[name])
            let expectedAttributes = name == "Member"
                ? Set(v7Entity.attributesByName.keys).union(["cloudParticipantID"])
                : Set(v7Entity.attributesByName.keys)

            XCTAssertEqual(
                Set(v8Entity.attributesByName.keys),
                expectedAttributes,
                "\(name) attributes drifted beyond the intended V8 change"
            )
            XCTAssertEqual(
                Set(v8Entity.relationshipsByName.keys),
                Set(v7Entity.relationshipsByName.keys),
                "\(name) relationships drifted beyond the intended V8 change"
            )
        }
    }

    func testV8IsTheModelTheAppLoads() throws {
        let current = try currentModel()

        XCTAssertNotNil(
            current.entitiesByName["Member"]?.attributesByName["cloudParticipantID"],
            "The compiled current model must be V8 or the participant mapping cannot be persisted"
        )
    }

    /// `LocalMemberIdentity` maps the current Apple Account to an App member and must
    /// never reach the shared store; the share-local participant ID is what crosses
    /// the share boundary instead.
    func testLocalMemberIdentityStaysPrivateOnlyInV8() throws {
        let v8 = try model(named: "SharedLedgerV8")

        let privateEntities = Set((v8.entities(forConfigurationName: "Private") ?? []).compactMap(\.name))
        let sharedEntities = Set((v8.entities(forConfigurationName: "Shared") ?? []).compactMap(\.name))

        XCTAssertTrue(privateEntities.contains("LocalMemberIdentity"))
        XCTAssertFalse(sharedEntities.contains("LocalMemberIdentity"))
        XCTAssertTrue(sharedEntities.contains("Member"))
    }

    func testExistingV7StoreMigratesAndKeepsMembersWithoutAParticipantID() throws {
        let storeURL = try makeTemporaryStoreURL()
        defer { removeStore(at: storeURL) }

        let memberID = UUID()
        let groupID = UUID()

        try writeV7Store(at: storeURL) { context in
            let group = NSEntityDescription.insertNewObject(
                forEntityName: "LedgerGroup",
                into: context
            )
            group.setValue(groupID, forKey: "id")
            group.setValue("家庭帳本", forKey: "name")
            group.setValue("TWD", forKey: "currencyCode")

            let member = NSEntityDescription.insertNewObject(
                forEntityName: "Member",
                into: context
            )
            member.setValue(memberID, forKey: "id")
            member.setValue("小美", forKey: "displayName")
            member.setValue(MemberRole.member.rawValue, forKey: "role")
            member.setValue(InvitationStatus.accepted.rawValue, forKey: "invitationStatus")
            member.setValue(group, forKey: "group")
        }

        let migrated = try openMigratedV8Store(at: storeURL)
        defer { migrated.close() }

        let request = NSFetchRequest<NSManagedObject>(entityName: "Member")
        let members = try migrated.context.fetch(request)

        XCTAssertEqual(members.count, 1)
        let member = try XCTUnwrap(members.first)
        XCTAssertEqual(member.value(forKey: "id") as? UUID, memberID)
        XCTAssertEqual(member.value(forKey: "displayName") as? String, "小美")
        XCTAssertEqual(
            member.value(forKey: "invitationStatus") as? String,
            InvitationStatus.accepted.rawValue
        )
        // An already-accepted V7 member has no participant identity yet; it is bound
        // the next time that member is claimed against a live CKShare.
        XCTAssertNil(member.value(forKey: "cloudParticipantID"))
        XCTAssertEqual(
            (member.value(forKey: "group") as? NSManagedObject)?.value(forKey: "id") as? UUID,
            groupID
        )
    }

    func testMigratedStoreCanPersistAParticipantID() throws {
        let storeURL = try makeTemporaryStoreURL()
        defer { removeStore(at: storeURL) }

        try writeV7Store(at: storeURL) { context in
            let member = NSEntityDescription.insertNewObject(
                forEntityName: "Member",
                into: context
            )
            member.setValue(UUID(), forKey: "id")
            member.setValue("小美", forKey: "displayName")
        }

        let migrated = try openMigratedV8Store(at: storeURL)
        let member = try XCTUnwrap(
            try migrated.context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Member")).first
        )

        member.setValue("participant-1", forKey: "cloudParticipantID")
        try migrated.context.save()
        migrated.close()

        let reopened = try openMigratedV8Store(at: storeURL)
        defer { reopened.close() }
        let persisted = try XCTUnwrap(
            try reopened.context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Member")).first
        )
        XCTAssertEqual(persisted.value(forKey: "cloudParticipantID") as? String, "participant-1")
    }

    // MARK: - Helpers

    private func model(named name: String) throws -> NSManagedObjectModel {
        try loadVersionedModel(named: name)
    }

    private func currentModel() throws -> NSManagedObjectModel {
        try loadCurrentModel()
    }

    private func makeTemporaryStoreURL() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SharedLedgerMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("SharedLedger.sqlite")
    }

    private func removeStore(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func writeV7Store(
        at url: URL,
        populate: (NSManagedObjectContext) throws -> Void
    ) throws {
        let coordinator = NSPersistentStoreCoordinator(
            managedObjectModel: try model(named: "SharedLedgerV7")
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

    /// Keeps the coordinator alive alongside the context so the SQLite file can be
    /// released before the same URL is opened again.
    private struct OpenStore {
        let coordinator: NSPersistentStoreCoordinator
        let store: NSPersistentStore
        let context: NSManagedObjectContext

        func close() {
            try? coordinator.remove(store)
        }
    }

    private func openMigratedV8Store(at url: URL) throws -> OpenStore {
        let coordinator = NSPersistentStoreCoordinator(
            managedObjectModel: try model(named: "SharedLedgerV8")
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

extension XCTestCase {
    func managedObjectModelDirectory() throws -> URL {
        try XCTUnwrap(
            Bundle(for: PersistenceController.self)
                .url(forResource: "SharedLedger", withExtension: "momd")
        )
    }

    /// Loads a specific `.mom` for inspection.
    ///
    /// The entities are detached from their generated subclasses first: a model
    /// loaded here is only ever read or driven through KVC, and leaving the class
    /// names in place makes these entities compete with the running app's model for
    /// `+entity`, which floods every later test with `Multiple NSEntityDescriptions
    /// claim the NSManagedObject subclass …`.
    func loadVersionedModel(named name: String) throws -> NSManagedObjectModel {
        let model = try XCTUnwrap(
            NSManagedObjectModel(
                contentsOf: try managedObjectModelDirectory()
                    .appendingPathComponent("\(name).mom")
            )
        )
        return detachedFromGeneratedClasses(model)
    }

    func loadCurrentModel() throws -> NSManagedObjectModel {
        let model = try XCTUnwrap(
            NSManagedObjectModel(contentsOf: try managedObjectModelDirectory())
        )
        return detachedFromGeneratedClasses(model)
    }

    private func detachedFromGeneratedClasses(
        _ model: NSManagedObjectModel
    ) -> NSManagedObjectModel {
        for entity in model.entities {
            entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        }
        return model
    }
}
