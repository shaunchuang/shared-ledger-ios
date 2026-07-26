import CloudKit
import CoreData
import XCTest
@testable import SharedLedger

/// Ownership transfer is the one member operation that hands over control of the
/// group, so it may only reach a member the App can actually identify: an accepted
/// `CKShare` participant with write access. These tests pin that gate, the demotion
/// of the previous owner, and the leave path the transfer exists to unblock.
@MainActor
final class GroupOwnershipTransferTests: XCTestCase {
    func testTransferMovesTheSeatAndDemotesThePreviousOwner() throws {
        let fixture = try makePrivateFixture()

        try GroupRepository(persistence: fixture.persistence)
            .transferOwnership(to: fixture.other, in: fixture.group)

        XCTAssertEqual(fixture.other.role, MemberRole.owner.rawValue)
        XCTAssertEqual(fixture.owner.role, MemberRole.administrator.rawValue)
        // The previous owner keeps managing members, which is what still lets that
        // Apple Account run the iCloud share it continues to hold.
        XCTAssertTrue(
            EffectivePermissionRepository(
                persistence: fixture.persistence,
                cache: fixture.cache,
                shareResolver: { _ in nil }
            ).permission(in: fixture.group).canManageMembers
        )
    }

    /// Without an explicit identity the private-store fallback resolves the current
    /// user through the group's single accepted owner — which the transfer just made
    /// somebody else.
    func testThePreviousOwnerKeepsTheirIdentityAfterTheTransfer() throws {
        let fixture = try makePrivateFixture()

        try GroupRepository(persistence: fixture.persistence)
            .transferOwnership(to: fixture.other, in: fixture.group)

        XCTAssertEqual(
            CurrentMemberIdentityRepository(persistence: fixture.persistence)
                .currentMember(in: fixture.group),
            fixture.owner
        )
    }

    func testTheTransferIsRecordedInTheAuditTrail() throws {
        let fixture = try makePrivateFixture()

        try GroupRepository(persistence: fixture.persistence)
            .transferOwnership(to: fixture.other, in: fixture.group)

        let events = fixture.group.auditEvents as? Set<AuditEvent> ?? []
        let transfer = events.first { $0.action == "group.ownership.transferred" }
        XCTAssertNotNil(transfer)
        XCTAssertEqual(transfer?.actorDisplayName, "小明")
        XCTAssertEqual(transfer?.summary?.contains("小華"), true)
    }

    /// The whole point of the transfer: an owner cannot leave, an administrator can.
    func testThePreviousOwnerCanLeaveOnceTheSeatHasMoved() throws {
        let fixture = try makePrivateFixture()
        let repository = GroupRepository(persistence: fixture.persistence)

        XCTAssertThrowsError(try repository.leaveGroup(fixture.group)) { error in
            XCTAssertEqual(
                error as? GroupRepository.GroupError,
                .ownerMustTransferBeforeLeaving
            )
        }

        try repository.transferOwnership(to: fixture.other, in: fixture.group)
        try repository.leaveGroup(fixture.group)

        XCTAssertNotNil(fixture.owner.archivedAt)
    }

    func testOnlyTheOwnerCanTransferOwnership() throws {
        let fixture = try makePrivateFixture()
        fixture.owner.role = MemberRole.administrator.rawValue
        try fixture.persistence.container.viewContext.save()

        XCTAssertThrowsError(
            try GroupRepository(persistence: fixture.persistence)
                .transferOwnership(to: fixture.other, in: fixture.group)
        ) { error in
            XCTAssertEqual(
                error as? GroupRepository.GroupError,
                .onlyOwnerCanTransferOwnership
            )
        }
        XCTAssertEqual(fixture.other.role, MemberRole.member.rawValue)
    }

    func testAnInactiveMemberCannotReceiveTheOwnerSeat() throws {
        let fixture = try makePrivateFixture()
        fixture.other.archivedAt = Date()
        try fixture.persistence.container.viewContext.save()

        XCTAssertThrowsError(
            try GroupRepository(persistence: fixture.persistence)
                .transferOwnership(to: fixture.other, in: fixture.group)
        ) { error in
            XCTAssertEqual(error as? GroupRepository.GroupError, .inactiveMember)
        }
    }

    func testAPendingMemberCannotReceiveTheOwnerSeat() throws {
        let fixture = try makePrivateFixture()
        fixture.other.invitationStatus = InvitationStatus.pending.rawValue
        try fixture.persistence.container.viewContext.save()

        let repository = GroupRepository(persistence: fixture.persistence)
        XCTAssertFalse(repository.isOwnershipTransferCandidate(fixture.other, in: fixture.group))
        XCTAssertThrowsError(
            try repository.transferOwnership(to: fixture.other, in: fixture.group)
        ) { error in
            XCTAssertEqual(error as? GroupRepository.GroupError, .inactiveMember)
        }
    }

    // MARK: - CloudKit participant mapping

    /// A shared group whose members carry no participant ID is exactly the state the
    /// feature was blocked on: the `Member` row is a display name, not a person.
    func testASharedGroupRefusesTheTransferWhileTheMemberIsUnmapped() throws {
        let share = CKShare(recordZoneID: CKRecordZone.ID(zoneName: "OwnershipTransferTests"))
        let fixture = try makeSharedFixture(shareFetcher: { objectIDs in
            Dictionary(uniqueKeysWithValues: objectIDs.map { ($0, share) })
        })

        let repository = GroupRepository(persistence: fixture.persistence)
        XCTAssertEqual(
            repository.ownershipTransferRestriction(to: fixture.other, in: fixture.group),
            .ownershipTransferRequiresCloudParticipantMapping
        )
        XCTAssertThrowsError(
            try repository.transferOwnership(to: fixture.other, in: fixture.group)
        ) { error in
            XCTAssertEqual(
                error as? GroupRepository.GroupError,
                .ownershipTransferRequiresCloudParticipantMapping
            )
        }
        XCTAssertEqual(fixture.other.role, MemberRole.member.rawValue)
    }

    /// Share metadata that has not synced yet is not evidence of anything, so it must
    /// not be read as a healthy mapping.
    func testAnUnreachableShareRefusesTheTransfer() throws {
        let fixture = try makeSharedFixture(shareFetcher: { _ in
            throw CocoaError(.fileReadUnknown)
        })

        XCTAssertEqual(
            GroupRepository(persistence: fixture.persistence)
                .ownershipTransferRestriction(to: fixture.other, in: fixture.group),
            .ownershipTransferRequiresCloudParticipantMapping
        )
    }

    /// A shared group whose share record has not been mirrored yet must not read as
    /// "never shared", or the participant gate would be skipped entirely for members
    /// this device cannot verify.
    func testASharedGroupWithoutShareMetadataRefusesTheTransfer() throws {
        let fixture = try makeSharedFixture(shareFetcher: { _ in [:] })

        let repository = GroupRepository(persistence: fixture.persistence)
        XCTAssertEqual(
            repository.cloudParticipantStatuses(in: fixture.group)[fixture.other.objectID],
            .shareUnavailable
        )
        XCTAssertThrowsError(
            try repository.transferOwnership(to: fixture.other, in: fixture.group)
        ) { error in
            XCTAssertEqual(
                error as? GroupRepository.GroupError,
                .ownershipTransferRequiresCloudParticipantMapping
            )
        }
        XCTAssertEqual(fixture.other.role, MemberRole.member.rawValue)
    }

    func testAMappedWritableParticipantClearsTheTransfer() throws {
        let fixture = try makePrivateFixture()

        XCTAssertNil(
            GroupRepository(persistence: fixture.persistence).ownershipTransferRestriction(
                to: fixture.other,
                in: fixture.group,
                participantStatus: .mapped(canWrite: true, isShareOwner: false, isAccepted: true)
            )
        )
    }

    /// A read-only participant promoted to owner would be clamped straight back to
    /// viewer, leaving the group with an owner who cannot act as one.
    func testAReadOnlyParticipantCannotReceiveTheOwnerSeat() throws {
        let fixture = try makePrivateFixture()

        XCTAssertEqual(
            GroupRepository(persistence: fixture.persistence).ownershipTransferRestriction(
                to: fixture.other,
                in: fixture.group,
                participantStatus: .mapped(canWrite: false, isShareOwner: false, isAccepted: true)
            ),
            .ownershipTransferRequiresWritableParticipant
        )
    }

    func testAnUnacceptedInvitationCannotReceiveTheOwnerSeat() throws {
        let fixture = try makePrivateFixture()

        XCTAssertEqual(
            GroupRepository(persistence: fixture.persistence).ownershipTransferRestriction(
                to: fixture.other,
                in: fixture.group,
                participantStatus: .mapped(canWrite: true, isShareOwner: false, isAccepted: false)
            ),
            .ownershipTransferRequiresCloudParticipantMapping
        )
    }

    func testAMemberOfAnotherGroupCannotReceiveTheOwnerSeat() throws {
        let fixture = try makePrivateFixture()
        let otherGroup = try GroupRepository(persistence: fixture.persistence).createGroup(
            from: GroupDraft(name: "旅行", ownerDisplayName: "小美")
        )
        let outsider = try XCTUnwrap(
            CurrentMemberIdentityRepository(persistence: fixture.persistence)
                .currentMember(in: otherGroup)
        )

        XCTAssertEqual(
            GroupRepository(persistence: fixture.persistence)
                .ownershipTransferRestriction(to: outsider, in: fixture.group),
            .crossGroupMember
        )
    }

    // MARK: - Fixtures

    private struct Fixture {
        let persistence: PersistenceController
        let cache: CloudPermissionCache
        let group: LedgerGroup
        let owner: Member
        let other: Member
    }

    /// A private group with a second accepted member. `.notShared` leaves nothing for
    /// the participant check to correlate, so these cover the App-side rules.
    private func makePrivateFixture() throws -> Fixture {
        let cache = try makeIsolatedPermissionCache()
        let persistence = PersistenceController(inMemory: true, cloudPermissionCache: cache)
        let group = try GroupRepository(persistence: persistence).createGroup(
            from: GroupDraft(name: "家庭", ownerDisplayName: "小明")
        )
        let owner = try XCTUnwrap(
            CurrentMemberIdentityRepository(persistence: persistence).currentMember(in: group)
        )
        let other = makeMember(
            named: "小華",
            in: group,
            store: persistence.privateStore,
            persistence: persistence
        )
        try persistence.container.viewContext.save()

        return Fixture(
            persistence: persistence,
            cache: cache,
            group: group,
            owner: owner,
            other: other
        )
    }

    /// A shared group whose current user is the App owner. The share carries no
    /// participants, so the cached permission stands in for the CloudKit clamp and the
    /// members stay unmapped.
    private func makeSharedFixture(
        shareFetcher: PersistenceController.ShareFetcher?
    ) throws -> Fixture {
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

        let owner = makeMember(
            named: "小明",
            in: group,
            store: persistence.sharedStore,
            persistence: persistence
        )
        owner.role = MemberRole.owner.rawValue
        let other = makeMember(
            named: "小華",
            in: group,
            store: persistence.sharedStore,
            persistence: persistence
        )
        try context.save()

        CurrentMemberIdentityRepository(persistence: persistence)
            .setCurrentMember(owner, in: group)
        try context.save()
        cache.store(true, for: group)

        return Fixture(
            persistence: persistence,
            cache: cache,
            group: group,
            owner: owner,
            other: other
        )
    }

    private func makeMember(
        named displayName: String,
        in group: LedgerGroup,
        store: NSPersistentStore,
        persistence: PersistenceController
    ) -> Member {
        let context = persistence.container.viewContext
        let member = Member(context: context)
        context.assign(member, to: store)
        member.id = UUID()
        member.displayName = displayName
        member.role = MemberRole.member.rawValue
        member.invitationStatus = InvitationStatus.accepted.rawValue
        member.joinedAt = Date()
        member.group = group
        return member
    }
}
