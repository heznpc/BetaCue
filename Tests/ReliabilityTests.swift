import XCTest
@testable import BetaCue

/// The cases that let three P0 defects survive: what happens when a fetch **fails**.
///
/// The product's stated principle is "never guess". Every test here asserts that an unread
/// fact stays unread instead of collapsing into a confident verdict.
final class ReliabilityTests: XCTestCase {

    private func build(
        processing: String = "VALID",
        internalState: String? = "IN_BETA_TESTING",
        externalState: String? = nil,
        betaStateIsKnown: Bool = true,
        assignedGroupIDs: [String]? = ["g"],
        individualTesterCount: Int? = 0,
        audienceType: String? = nil
    ) -> BuildSnapshot {
        BuildSnapshot(
            id: "b1", number: "1", marketingVersion: "1.0.0", platform: "IOS",
            processingState: processing, internalState: internalState,
            externalState: externalState, betaStateIsKnown: betaStateIsKnown,
            uploadedAt: nil, expiresAt: nil, isExpired: false,
            assignedGroupIDs: assignedGroupIDs, individualTesterCount: individualTesterCount,
            audienceType: audienceType)
    }

    private func group(
        id: String = "g", testers: Int? = 1, isInternal: Bool = true, publicLink: Bool = false
    ) -> GroupSnapshot {
        GroupSnapshot(id: id, name: "Group \(id)", isInternal: isInternal, testerCount: testers,
                      autoDistributes: true, publicLinkEnabled: publicLink, publicLink: nil)
    }

    // MARK: - Unread data must not become a verdict

    /// P0-1. A failed buildBetaDetail fetch used to fall through to "Ready to test".
    func testUnreadBetaStateResolvesToUnknown() {
        let status = RuleEngine.resolve(
            groups: [group()],
            builds: [build(internalState: nil, externalState: nil, betaStateIsKnown: false)])
        XCTAssertEqual(status.state.id, .unknown)
        XCTAssertEqual(status.state.reason, .betaStateUnread)
        XCTAssertNil(status.testable, "an unread beta state cannot be called installable")
    }

    /// P0-1. A failed attachment fetch used to look like "attached to nothing".
    func testUnreadAttachmentsResolveToUnknown() {
        let status = RuleEngine.resolve(
            groups: [group()], builds: [build(assignedGroupIDs: nil)])
        XCTAssertEqual(status.state.id, .unknown)
        XCTAssertEqual(status.state.reason, .audienceUnread)
    }

    /// P0-1. A failed tester fetch used to count as zero testers.
    func testUnreadTesterCountIsNotZero() {
        XCTAssertEqual(group(testers: nil).reachability, .unknown)
        XCTAssertEqual(group(testers: 0).reachability, .unreachable)
        XCTAssertEqual(group(testers: 3).reachability, .reachable)

        let status = RuleEngine.resolve(groups: [group(testers: nil)], builds: [build()])
        XCTAssertEqual(status.state.id, .unknown,
                       "an unreadable tester list must not read as an empty group")
    }

    /// A group with a public link reaches people regardless of the enrolled count.
    func testPublicLinkIsReachableEvenWithUnreadCount() {
        XCTAssertEqual(group(testers: nil, publicLink: true).reachability, .reachable)
    }

    // MARK: - Attachment is not installability

    /// P0-2. processingState VALID alone used to mean "install it now".
    func testProcessingInternalStateIsNotInstallable() {
        let status = RuleEngine.resolve(
            groups: [group()], builds: [build(internalState: "PROCESSING")])
        XCTAssertNil(status.testable, "Apple is still working; nobody can install this")
        XCTAssertEqual(status.state.id, .buildProcessing)
    }

    func testExportComplianceReviewIsNotInstallable() {
        let status = RuleEngine.resolve(
            groups: [group()], builds: [build(internalState: "IN_EXPORT_COMPLIANCE_REVIEW")])
        XCTAssertNil(status.testable)
        XCTAssertEqual(status.state.id, .buildProcessing)
    }

    func testProcessingExceptionNeedsAttention() {
        let status = RuleEngine.resolve(
            groups: [group()], builds: [build(internalState: "PROCESSING_EXCEPTION")])
        XCTAssertEqual(status.state.id, .actionRequired)
        XCTAssertEqual(status.state.reason, .processingException)
        XCTAssertNil(status.testable)
    }

    /// P0-2. An external group waiting on review reaches nobody today, so it must not be counted.
    func testExternalTestersUnderReviewAreNotCounted() {
        let external = group(id: "ext", testers: 100, isInternal: false)
        let internalGroup = group(id: "g", testers: 2)
        let status = RuleEngine.resolve(
            groups: [internalGroup, external],
            builds: [build(externalState: "IN_BETA_REVIEW",
                           assignedGroupIDs: ["g", "ext"])])

        XCTAssertEqual(status.state.id, .externalReviewPending)
        XCTAssertEqual(status.audience?.internalTesters, 2)
        XCTAssertEqual(status.audience?.externalTesters, 0,
                       "100 external testers behind an unfinished review can install nothing")
    }

    func testApprovedExternalTestersAreCounted() {
        let external = group(id: "ext", testers: 100, isInternal: false)
        let status = RuleEngine.resolve(
            groups: [group(), external],
            builds: [build(externalState: "IN_BETA_TESTING", assignedGroupIDs: ["g", "ext"])])
        XCTAssertEqual(status.state.id, .externalTestingReady)
        XCTAssertEqual(status.audience?.externalTesters, 100)
    }

    /// Attached and reachable, but Apple has not released it — not "ready to test".
    ///
    /// P1-2. Nor "reaches nobody": this branch is only reached once the audience is confirmed
    /// reachable, so the old headline contradicted the check that led to it, and the
    /// "distribute to testers" button it carried invited a redundant write.
    func testAttachedButNotYetLiveIsNotReady() {
        let status = RuleEngine.resolve(
            groups: [group()], builds: [build(internalState: "READY_FOR_BETA_TESTING")])
        XCTAssertEqual(status.state.id, .awaitingRelease)
        XCTAssertEqual(status.state.reason, .notYetLive)
        XCTAssertNil(status.testable)
        XCTAssertNil(status.state.nextAction, "there is nothing to press; Apple is the one acting")
        XCTAssertNil(status.state.blocker, "the audience is attached; nothing is blocking")
    }

    /// The same applies on the external side while the build still awaits submission.
    func testAwaitingSubmissionWithoutInternalReleaseIsNotStranded() {
        let status = RuleEngine.resolve(
            groups: [group()],
            builds: [build(internalState: "READY_FOR_BETA_TESTING",
                           externalState: "READY_FOR_BETA_SUBMISSION")])
        XCTAssertEqual(status.state.id, .awaitingRelease)
        XCTAssertNotEqual(status.state.severity, .warning,
                          "waiting on Apple is not something the user did wrong")
    }

    /// Leaving it has to produce actual wording, or `notifyWhenLeaving` fires into nothing.
    func testAwaitingReleaseNotifiesOnTheWayOut() {
        XCTAssertEqual(AppStateDefinition.make(.awaitingRelease).notificationPolicy,
                       .notifyWhenLeaving)
    }

    /// P0-2. One channel answering settles attachment. Requiring both to be readable sent
    /// apps with a perfectly readable group into UNKNOWN whenever the other fetch failed.
    func testAReadableChannelSurvivesAnUnreadableOne() {
        let readableGroup = build(individualTesterCount: nil)
        XCTAssertEqual(readableGroup.hasAssignedAudience(among: [group(testers: 3)]), .reachable,
                       "a group with three testers is an audience regardless of the other fetch")

        let readableIndividuals = build(assignedGroupIDs: nil, individualTesterCount: 2)
        XCTAssertEqual(readableIndividuals.hasAssignedAudience(among: []), .reachable,
                       "two direct invitees are an audience regardless of the other fetch")
    }

    /// With nothing positive found, the unread part is the difference between "none" and
    /// "can't tell" — and that difference is what decides whether anything notifies.
    func testNothingFoundPlusAnUnreadChannelIsUnknown() {
        XCTAssertEqual(build(assignedGroupIDs: [], individualTesterCount: nil)
                        .hasAssignedAudience(among: []), .unknown)
        XCTAssertEqual(build(assignedGroupIDs: nil, individualTesterCount: 0)
                        .hasAssignedAudience(among: []), .unknown)
        XCTAssertEqual(build(assignedGroupIDs: [], individualTesterCount: 0)
                        .hasAssignedAudience(among: []), .unreachable,
                       "everything was read and there is nobody; that is an answer")
    }

    // MARK: - Individual testers have no readable channel

    /// P0-1. Apple admits both internal and external testers as individual invitees and returns
    /// `BetaTester.state` as null, so with only the internal channel open nobody can say whether
    /// those two people can install. Counting them as internal was the confident wrong answer.
    func testIndividualTestersAreNotAssumedInternal() {
        let status = RuleEngine.resolve(
            groups: [],
            builds: [build(externalState: "IN_BETA_REVIEW",
                           assignedGroupIDs: [], individualTesterCount: 2)])

        XCTAssertNotEqual(status.state.id, .buildReadyNotDistributed,
                          "two people are invited to this build; it is not stranded")
        XCTAssertNil(status.testable,
                     "with external review unfinished, two testers of unknown kind are not proof "
                     + "that anyone can install")
    }

    /// `INTERNAL_ONLY` rules out external individual testers, which settles the question.
    func testInternalOnlyBuildSettlesTheIndividualChannel() {
        let status = RuleEngine.resolve(
            groups: [],
            builds: [build(assignedGroupIDs: [], individualTesterCount: 2,
                           audienceType: "INTERNAL_ONLY")])
        XCTAssertEqual(status.testable?.id, "b1")
        XCTAssertEqual(status.audience?.individualTesters, 2)
        XCTAssertEqual(status.audience?.undeterminedIndividualTesters, 0)
    }

    /// An `APP_STORE_ELIGIBLE` build may carry external individual testers, so the internal
    /// channel being open proves nothing about them.
    func testAppStoreEligibleBuildLeavesTheIndividualChannelUnknown() {
        let status = RuleEngine.resolve(
            groups: [],
            builds: [build(assignedGroupIDs: [], individualTesterCount: 2,
                           audienceType: "APP_STORE_ELIGIBLE")])
        XCTAssertNil(status.testable)
        let audience = build(assignedGroupIDs: [], individualTesterCount: 2,
                             audienceType: "APP_STORE_ELIGIBLE").installableAudience(among: [])
        XCTAssertEqual(audience?.undeterminedIndividualTesters, 2)
        XCTAssertEqual(audience?.individualTesters, 0)
        XCTAssertFalse(audience?.reachesSomeone ?? true)
    }

    /// With both channels open the kind of tester stops mattering.
    func testBothChannelsOpenMakeIndividualTestersCountable() {
        let status = RuleEngine.resolve(
            groups: [],
            builds: [build(externalState: "IN_BETA_TESTING",
                           assignedGroupIDs: [], individualTesterCount: 3,
                           audienceType: "APP_STORE_ELIGIBLE")])
        XCTAssertEqual(status.audience?.individualTesters, 3)
        XCTAssertNotNil(status.testable)
    }

    /// A readable group audience still decides on its own; the undetermined channel only adds.
    func testUndeterminedIndividualsDoNotHideARealAudience() {
        let status = RuleEngine.resolve(
            groups: [group(testers: 2)],
            builds: [build(externalState: "IN_BETA_REVIEW", individualTesterCount: 2,
                           audienceType: "APP_STORE_ELIGIBLE")])
        XCTAssertEqual(status.audience?.internalTesters, 2)
        XCTAssertEqual(status.audience?.undeterminedIndividualTesters, 2)
        XCTAssertEqual(status.testable?.id, "b1")
    }

    // MARK: - Determinism

    /// `now` is injected, so the same input really does give the same output.
    func testResolutionDoesNotReadTheClock() {
        let groups = [group()]
        let builds = [BuildSnapshot(
            id: "b", number: "9", marketingVersion: "1.0", platform: "IOS",
            processingState: "PROCESSING", internalState: nil, externalState: nil,
            betaStateIsKnown: true, uploadedAt: Date(timeIntervalSince1970: 1_000_000),
            expiresAt: nil, isExpired: false, assignedGroupIDs: ["g"], individualTesterCount: 0)]

        let early = RuleEngine.resolve(groups: groups, builds: builds,
                                       now: Date(timeIntervalSince1970: 1_000_600))
        let late = RuleEngine.resolve(groups: groups, builds: builds,
                                      now: Date(timeIntervalSince1970: 1_004_000))
        XCTAssertEqual(early.state.id, late.state.id)
        XCTAssertNotEqual(early.state.description, late.state.description,
                          "elapsed time should still be reflected in the wording")

        let repeated = RuleEngine.resolve(groups: groups, builds: builds,
                                          now: Date(timeIntervalSince1970: 1_000_600))
        XCTAssertEqual(early.state.description, repeated.state.description)
    }

    // MARK: - Installable build search

    /// The newest build being stuck must not hide an older one that still installs.
    func testFindsOlderInstallableBuildBeyondTheNewest() {
        let stuck = (1...5).map { i in
            BuildSnapshot(id: "s\(i)", number: "\(100 + i)", marketingVersion: "2.0",
                          platform: "IOS", processingState: "PROCESSING",
                          internalState: nil, externalState: nil, betaStateIsKnown: true,
                          uploadedAt: nil, expiresAt: nil, isExpired: false,
                          assignedGroupIDs: [], individualTesterCount: 0)
        }
        let alive = build()
        let status = RuleEngine.resolve(groups: [group()], builds: stuck + [alive])
        XCTAssertEqual(status.testable?.id, alive.id)
        XCTAssertTrue(status.hasOlderTestableBuild)
    }
}
