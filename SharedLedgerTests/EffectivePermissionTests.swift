import CloudKit
import CoreData
import XCTest
@testable import SharedLedger

/// CloudKit is the only server-enforced boundary, so the App role is clamped by the
/// share participant's permission: it can be reduced but never raised. These tests
/// pin that rule, the offline fallback, and the fail-closed default.
@MainActor
final class EffectivePermissionTests: XCTestCase {
    func testPrivateGroupThatWasNeverSharedUsesTheAppRoleDirectly() throws {
        let fixture = try makePrivateFixture()

        let permission = EffectivePermissionRepository(
            persistence: fixture.persistence,
            cache: fixture.cache,
            shareResolver: { _ in nil }
        ).permission(in: fixture.group)

        XCTAssertEqual(permission.source, .localOnly)
        XCTAssertEqual(permission.role, .owner)
        XCTAssertFalse(permission.isClampedByCloud)
        XCTAssertTrue(permission.canEditTransactions)
        XCTAssertTrue(permission.canManageMembers)
    }

    func testAppRoleStillLimitsAPrivateGroup() throws {
        let fixture = try makePrivateFixture()
        fixture.owner.role = MemberRole.viewer.rawValue

        let repository = EffectivePermissionRepository(
            persistence: fixture.persistence,
            cache: fixture.cache,
            shareResolver: { _ in nil }
        )
        let permission = repository.permission(in: fixture.group)

        XCTAssertEqual(permission.role, .viewer)
        XCTAssertFalse(permission.canEditTransactions)
        // A viewer in an unshared group is an App role decision, not a CloudKit one,
        // and the error has to say so.
        XCTAssertThrowsError(try repository.requireTransactionWrite(in: fixture.group)) { error in
            XCTAssertEqual(error as? PermissionError, .insufficientRole(.viewer))
        }
    }

    func testUnresolvedSharePermissionRefusesWritesAndRemembersNothing() throws {
        let fixture = try makeSharedFixture()

        let repository = EffectivePermissionRepository(
            persistence: fixture.persistence,
            cache: fixture.cache,
            shareResolver: { _ in nil }
        )
        let permission = repository.permission(in: fixture.group)

        XCTAssertEqual(permission.source, .cloudPermissionUnknown)
        XCTAssertNil(permission.role)
        XCTAssertFalse(permission.canEditTransactions)
        XCTAssertThrowsError(try repository.requireTransactionWrite(in: fixture.group)) { error in
            XCTAssertEqual(error as? PermissionError, .cloudPermissionUnknown)
        }
        XCTAssertNil(fixture.cache.lastKnownWritePermission(for: fixture.group))
    }

    func testAFailingShareLookupFallsBackToTheLastKnownPermission() throws {
        let fixture = try makeSharedFixture()
        fixture.cache.store(true, for: fixture.group)

        let permission = EffectivePermissionRepository(
            persistence: fixture.persistence,
            cache: fixture.cache,
            shareResolver: { _ in throw CocoaError(.fileReadUnknown) }
        ).permission(in: fixture.group)

        XCTAssertEqual(permission.source, .cachedCloudParticipant)
        XCTAssertEqual(permission.role, .member)
        XCTAssertTrue(permission.canEditTransactions)
    }

    func testACachedReadOnlyPermissionKeepsClampingWhileOffline() throws {
        let fixture = try makeSharedFixture()
        fixture.cache.store(false, for: fixture.group)

        let repository = EffectivePermissionRepository(
            persistence: fixture.persistence,
            cache: fixture.cache,
            shareResolver: { _ in nil }
        )
        let permission = repository.permission(in: fixture.group)

        XCTAssertEqual(permission.source, .cachedCloudParticipant)
        XCTAssertEqual(permission.role, .viewer)
        XCTAssertTrue(permission.isClampedByCloud)
        // The App role is member, so the reason has to be the CloudKit clamp.
        XCTAssertThrowsError(try repository.requireTransactionWrite(in: fixture.group)) { error in
            XCTAssertEqual(error as? PermissionError, .cloudReadOnly)
        }
    }

    func testResharingAPrivateGroupDoesNotInheritAStaleCachedPermission() throws {
        let fixture = try makePrivateFixture()
        fixture.cache.store(false, for: fixture.group)

        let permission = EffectivePermissionRepository(
            persistence: fixture.persistence,
            cache: fixture.cache,
            shareResolver: { _ in nil }
        ).permission(in: fixture.group)

        XCTAssertEqual(permission.source, .localOnly)
        XCTAssertEqual(permission.role, .owner)
        XCTAssertNil(fixture.cache.lastKnownWritePermission(for: fixture.group))
    }

    func testWithoutAConfirmedMemberEveryMutationIsRefused() throws {
        let fixture = try makeSharedFixture()
        fixture.member.invitationStatus = InvitationStatus.pending.rawValue
        fixture.cache.store(true, for: fixture.group)

        let repository = EffectivePermissionRepository(
            persistence: fixture.persistence,
            cache: fixture.cache,
            shareResolver: { _ in nil }
        )

        XCTAssertEqual(repository.permission(in: fixture.group).source, .missingIdentity)
        XCTAssertThrowsError(try repository.requireTransactionWrite(in: fixture.group)) { error in
            XCTAssertEqual(error as? PermissionError, .missingCurrentMember)
        }
    }

    // MARK: - Repository enforcement

    func testTransactionAndSettingMutationsAreRefusedWhenThePermissionIsUnknown() throws {
        let fixture = try makeSharedFixture()

        XCTAssertThrowsError(
            try BookRepository(persistence: fixture.persistence)
                .createBook(from: BookDraft(name: "旅行"), in: fixture.group)
        ) { error in
            XCTAssertEqual(error as? PermissionError, .cloudPermissionUnknown)
        }

        XCTAssertThrowsError(
            try AccountRepository(persistence: fixture.persistence)
                .createAccount(from: makeAccountDraft(), in: fixture.group)
        ) { error in
            XCTAssertEqual(error as? PermissionError, .cloudPermissionUnknown)
        }

        XCTAssertThrowsError(
            try CategoryRepository(persistence: fixture.persistence)
                .createCategory(from: CategoryDraft(name: "餐飲"), in: fixture.group, parent: nil)
        ) { error in
            XCTAssertEqual(error as? PermissionError, .cloudPermissionUnknown)
        }

        XCTAssertThrowsError(
            try GroupRepository(persistence: fixture.persistence)
                .renameGroup(fixture.group, to: "改名")
        ) { error in
            XCTAssertEqual(error as? PermissionError, .cloudPermissionUnknown)
        }
    }

    func testAViewerCannotEditTransactionsInAnUnsharedGroup() throws {
        let fixture = try makePrivateFixture()
        let book = try XCTUnwrap(
            BookRepository(persistence: fixture.persistence).defaultBook(in: fixture.group)
        )
        fixture.owner.role = MemberRole.viewer.rawValue
        try fixture.persistence.container.viewContext.save()

        XCTAssertThrowsError(
            try BookRepository(persistence: fixture.persistence)
                .renameBook(book, using: BookDraft(name: "新名字"))
        ) { error in
            XCTAssertEqual(error as? PermissionError, .insufficientRole(.viewer))
        }
    }

    /// Resolving a permission makes a synchronous `fetchShares` call for a shared
    /// group, so the management screen resolves it once and derives every restriction
    /// from that one value. This pins that the derived answer is the same one the
    /// group-resolving helpers give, in both the allowed and the refused case.
    func testARestrictionDerivedFromAResolvedPermissionMatchesResolvingItPerQuestion() throws {
        let fixture = try makePrivateFixture()
        let repository = EffectivePermissionRepository(
            persistence: fixture.persistence,
            cache: fixture.cache,
            shareResolver: { _ in nil }
        )

        let ownerPermission = repository.permission(in: fixture.group)
        XCTAssertNil(repository.restriction(.memberManagement, for: ownerPermission))
        XCTAssertNil(repository.restriction(.ledgerSettings, for: ownerPermission))
        XCTAssertNil(repository.restriction(.transactionWrite, for: ownerPermission))
        XCTAssertNil(repository.memberManagementRestriction(in: fixture.group))

        fixture.owner.role = MemberRole.viewer.rawValue
        let viewerPermission = repository.permission(in: fixture.group)

        XCTAssertEqual(
            repository.restriction(.memberManagement, for: viewerPermission),
            repository.memberManagementRestriction(in: fixture.group)
        )
        XCTAssertEqual(
            repository.restriction(.memberManagement, for: viewerPermission),
            .insufficientRole(.viewer)
        )
        XCTAssertEqual(
            repository.restriction(.transactionWrite, for: viewerPermission),
            repository.transactionWriteRestriction(in: fixture.group)
        )
        XCTAssertEqual(
            repository.restriction(.ledgerSettings, for: viewerPermission),
            repository.ledgerSettingsRestriction(in: fixture.group)
        )
    }

    // MARK: - Participant mapping status

    func testAnUnsharedGroupReportsNoParticipantMapping() throws {
        let fixture = try makePrivateFixture()

        let statuses = GroupRepository(persistence: fixture.persistence)
            .cloudParticipantStatuses(in: fixture.group)

        XCTAssertEqual(statuses[fixture.owner.objectID], .notShared)
        XCTAssertNil(CloudParticipantStatus.notShared.badgeText)
    }

    func testAnUnreachableShareReportsShareUnavailableForEveryMember() throws {
        let fixture = try makeSharedFixture(shareFetcher: { _ in
            throw CocoaError(.fileReadUnknown)
        })

        let statuses = GroupRepository(persistence: fixture.persistence)
            .cloudParticipantStatuses(in: fixture.group)

        XCTAssertEqual(statuses[fixture.member.objectID], .shareUnavailable)
        XCTAssertEqual(CloudParticipantStatus.shareUnavailable.badgeText, "共享未同步")
    }

    func testAMemberWithoutAParticipantIDIsReportedAsUnmapped() throws {
        let share = CKShare(recordZoneID: CKRecordZone.ID(zoneName: "EffectivePermissionTests"))
        let fixture = try makeSharedFixture(shareFetcher: { objectIDs in
            Dictionary(uniqueKeysWithValues: objectIDs.map { ($0, share) })
        })

        let statuses = GroupRepository(persistence: fixture.persistence)
            .cloudParticipantStatuses(in: fixture.group)

        XCTAssertEqual(statuses[fixture.member.objectID], .unmapped)
        XCTAssertEqual(CloudParticipantStatus.unmapped.badgeText, "未對應")
    }

    /// A participant that left or was removed from the share must not silently look
    /// like a healthy mapping.
    func testAMemberBoundToAnAbsentParticipantIsReportedAsMissing() throws {
        let share = CKShare(recordZoneID: CKRecordZone.ID(zoneName: "EffectivePermissionTests"))
        let fixture = try makeSharedFixture(shareFetcher: { objectIDs in
            Dictionary(uniqueKeysWithValues: objectIDs.map { ($0, share) })
        })
        fixture.member.cloudParticipantID = "a-participant-that-is-not-in-the-share"
        try fixture.persistence.container.viewContext.save()

        let statuses = GroupRepository(persistence: fixture.persistence)
            .cloudParticipantStatuses(in: fixture.group)

        XCTAssertEqual(statuses[fixture.member.objectID], .participantMissing)
        XCTAssertEqual(CloudParticipantStatus.participantMissing.badgeText, "參與者已不存在")
    }

    func testMappedBadgesDistinguishOwnerWriteAndReadOnly() {
        XCTAssertEqual(
            CloudParticipantStatus.mapped(canWrite: true, isShareOwner: true, isAccepted: true).badgeText,
            "共享擁有者"
        )
        XCTAssertEqual(
            CloudParticipantStatus.mapped(canWrite: true, isShareOwner: false, isAccepted: true).badgeText,
            "可編輯"
        )
        XCTAssertEqual(
            CloudParticipantStatus.mapped(canWrite: false, isShareOwner: false, isAccepted: true).badgeText,
            "唯讀"
        )
        // An unaccepted invitation outranks the permission: there is nobody there yet.
        XCTAssertEqual(
            CloudParticipantStatus.mapped(canWrite: true, isShareOwner: false, isAccepted: false).badgeText,
            "邀請未接受"
        )
        XCTAssertTrue(
            CloudParticipantStatus.mapped(canWrite: false, isShareOwner: false, isAccepted: true).isMapped
        )
        XCTAssertFalse(CloudParticipantStatus.unmapped.isMapped)
    }

    // MARK: - Fixtures

    private struct PrivateFixture {
        let persistence: PersistenceController
        let cache: CloudPermissionCache
        let group: LedgerGroup
        let owner: Member
    }

    private struct SharedFixture {
        let persistence: PersistenceController
        let cache: CloudPermissionCache
        let group: LedgerGroup
        let member: Member
    }

    private func makePrivateFixture() throws -> PrivateFixture {
        let cache = try makeIsolatedPermissionCache()
        let persistence = PersistenceController(inMemory: true, cloudPermissionCache: cache)
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(name: "家庭", ownerDisplayName: "小明")
        )
        let owner = try XCTUnwrap(
            CurrentMemberIdentityRepository(persistence: persistence).currentMember(in: group)
        )
        return PrivateFixture(
            persistence: persistence,
            cache: cache,
            group: group,
            owner: owner
        )
    }

    private func makeSharedFixture(
        shareFetcher: PersistenceController.ShareFetcher? = nil
    ) throws -> SharedFixture {
        let cache = try makeIsolatedPermissionCache()
        let persistence = PersistenceController(
            inMemory: true,
            shareFetcher: shareFetcher,
            inMemoryConfigurations: ["Private", "Shared"],
            cloudPermissionCache: cache
        )
        let context = persistence.container.viewContext
        let group = LedgerGroup(context: context)
        context.assign(group, to: persistence.sharedStore)
        group.id = UUID()
        group.name = "共享旅行"
        group.currencyCode = "TWD"
        group.createdAt = Date()
        group.updatedAt = group.createdAt

        let member = Member(context: context)
        context.assign(member, to: persistence.sharedStore)
        member.id = UUID()
        member.displayName = "小華"
        member.role = MemberRole.member.rawValue
        member.invitationStatus = InvitationStatus.accepted.rawValue
        member.group = group
        try context.save()

        CurrentMemberIdentityRepository(persistence: persistence)
            .setCurrentMember(member, in: group)
        try context.save()

        return SharedFixture(
            persistence: persistence,
            cache: cache,
            group: group,
            member: member
        )
    }

    private func makeAccountDraft() -> AccountDraft {
        var draft = AccountDraft()
        draft.name = "現金"
        draft.openingBalanceText = "0"
        return draft
    }
}

extension XCTestCase {
    /// A permission cache backed by a throwaway suite so tests never read or write
    /// the real user defaults.
    func makeIsolatedPermissionCache() throws -> CloudPermissionCache {
        let suiteName = "CloudPermissionCache-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return CloudPermissionCache(defaults: defaults)
    }
}
