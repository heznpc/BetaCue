import XCTest
@testable import BetaCue

/// The rule engine is the product. Same input, same output, always. (spec §2.1)
///
/// Testing determinism alone passes even when badly collected data is consistently misjudged,
/// so these cases check the **meaning** of each decision too.
final class RuleEngineTests: XCTestCase {

    // MARK: - Fixtures

    private func build(
        id: String = "build-1",
        number: String = "1",
        processing: String = "VALID",
        internalState: String? = "IN_BETA_TESTING",
        externalState: String? = nil,
        expired: Bool = false,
        uploaded: Date? = nil,
        assignedGroups: [String] = ["g-internal"],
        individualTesters: Int = 0
    ) -> BuildSnapshot {
        BuildSnapshot(
            id: id, number: number, marketingVersion: "1.0.0", platform: "IOS",
            processingState: processing, internalState: internalState,
            externalState: externalState, uploadedAt: uploaded, expiresAt: nil,
            isExpired: expired, assignedGroupIDs: assignedGroups,
            individualTesterCount: individualTesters)
    }

    private func group(
        id: String = "g-internal",
        name: String = "Internal Testers",
        testers: Int = 1,
        isInternal: Bool = true,
        publicLink: Bool = false
    ) -> GroupSnapshot {
        GroupSnapshot(id: id, name: name, isInternal: isInternal, testerCount: testers,
                      autoDistributes: true, publicLinkEnabled: publicLink, publicLink: nil)
    }

    // MARK: - Basic resolution

    func testNoBuildsMeansNeverShipped() {
        let status = RuleEngine.resolve(groups: [], builds: [])
        XCTAssertEqual(status.state.id, .noBuild)
        XCTAssertNil(status.testable)
    }

    func testProcessingReportsNoWorkForUser() {
        let status = RuleEngine.resolve(groups: [group()], builds: [build(processing: "PROCESSING")])
        XCTAssertEqual(status.state.id, .buildProcessing)
        XCTAssertNil(status.state.nextAction, "nothing for the user to do while processing")
        XCTAssertEqual(status.state.notificationPolicy, .notifyWhenLeaving)
    }

    func testInternalTestingReady() {
        let status = RuleEngine.resolve(groups: [group()], builds: [build()])
        XCTAssertEqual(status.state.id, .internalTestingReady)
        XCTAssertEqual(status.state.severity, .success)
        XCTAssertNotNil(status.testable)
    }

    func testRejectedBuild() {
        let status = RuleEngine.resolve(groups: [group()], builds: [build(processing: "INVALID")])
        XCTAssertEqual(status.state.id, .buildInvalid)
        XCTAssertEqual(status.state.reason, "REJECTED_BY_APPLE")
    }

    func testExpiredBuildNeedsAction() {
        let status = RuleEngine.resolve(groups: [group()], builds: [build(expired: true)])
        XCTAssertEqual(status.state.id, .actionRequired)
        XCTAssertEqual(status.state.reason, "EXPIRED")
    }

    func testMissingExportComplianceBlocksDistribution() {
        let status = RuleEngine.resolve(
            groups: [group()], builds: [build(internalState: "MISSING_EXPORT_COMPLIANCE")])
        XCTAssertEqual(status.state.id, .actionRequired)
        XCTAssertEqual(status.state.reason, "MISSING_EXPORT_COMPLIANCE")
    }

    // MARK: - Audience resolution — a group existing is not a build being attached

    /// The reason this repository exists: a healthy build reaching nobody, failing silently.
    func testValidBuildWithNoGroupIsStranded() {
        let status = RuleEngine.resolve(groups: [], builds: [build(assignedGroups: [])])
        XCTAssertEqual(status.state.id, .buildReadyNotDistributed)
        XCTAssertEqual(status.state.reason, "NO_GROUPS")
        XCTAssertEqual(status.state.nextAction, .assignBuildToGroup)
        XCTAssertNil(status.testable)
    }

    /// Groups existing without this build attached is not distribution.
    func testGroupExistsButBuildNotAssigned() {
        let status = RuleEngine.resolve(
            groups: [group(testers: 5)], builds: [build(assignedGroups: [])])
        XCTAssertEqual(status.state.id, .buildReadyNotDistributed)
        XCTAssertEqual(status.state.reason, "BUILD_NOT_ASSIGNED")
    }

    func testAssignedGroupWithNoTesterIsStranded() {
        let status = RuleEngine.resolve(groups: [group(testers: 0)], builds: [build()])
        XCTAssertEqual(status.state.id, .buildReadyNotDistributed)
        XCTAssertEqual(status.state.reason, "GROUPS_EMPTY")
    }

    /// Individual testers count as distribution even with no groups at all.
    func testIndividualTesterCountsAsDistribution() {
        let status = RuleEngine.resolve(
            groups: [], builds: [build(assignedGroups: [], individualTesters: 2)])
        XCTAssertNotEqual(status.state.id, .buildReadyNotDistributed,
                          "an individually invited tester means this is distributed")
        XCTAssertNotNil(status.testable)
    }

    /// A public link can reach people even with zero enrolled testers.
    func testPublicLinkCountsAsReachable() {
        let external = group(id: "g-public", name: "Public", testers: 0,
                             isInternal: false, publicLink: true)
        let status = RuleEngine.resolve(
            groups: [external],
            builds: [build(externalState: "IN_BETA_TESTING", assignedGroups: ["g-public"])])
        XCTAssertNotEqual(status.state.id, .buildReadyNotDistributed)
        XCTAssertEqual(status.state.id, .externalTestingReady)
    }

    /// Only the attached group counts.
    func testOnlyAssignedGroupCounts() {
        let g1 = group(id: "g1", name: "QA", testers: 3)
        let g2 = group(id: "g2", name: "Friends", testers: 9, isInternal: false)
        let status = RuleEngine.resolve(groups: [g1, g2], builds: [build(assignedGroups: ["g1"])])
        XCTAssertEqual(status.state.id, .internalTestingReady)
        XCTAssertEqual(status.audience?.internalTesters, 3,
                       "the 9 testers in the unattached g2 must not be counted")
        XCTAssertEqual(status.audience?.externalTesters, 0)
    }

    // MARK: - Two axes — latest upload versus currently testable

    /// A processing build must not erase the fact that an older one still installs.
    func testProcessingBuildKeepsOlderBuildTestable() {
        let newer = build(id: "b43", number: "43", processing: "PROCESSING",
                          internalState: nil, assignedGroups: [])
        let older = build(id: "b42", number: "42")
        let status = RuleEngine.resolve(groups: [group()], builds: [newer, older])

        XCTAssertEqual(status.state.id, .buildProcessing, "latest-upload state is processing")
        XCTAssertEqual(status.testable?.id, "b42", "the previous build must stay installable")
        XCTAssertTrue(status.hasOlderTestableBuild)
    }

    /// When the newest build is the one serving, no "previous version" hint should appear.
    func testLatestBuildIsTheTestableOne() {
        let status = RuleEngine.resolve(groups: [group()], builds: [build(id: "b1")])
        XCTAssertEqual(status.testable?.id, "b1")
        XCTAssertFalse(status.hasOlderTestableBuild)
    }

    /// A rejected newest build leaves the previous one alive.
    func testRejectedLatestKeepsOlderAlive() {
        let bad = build(id: "b2", number: "2", processing: "INVALID",
                        internalState: nil, assignedGroups: [])
        let good = build(id: "b1")
        let status = RuleEngine.resolve(groups: [group()], builds: [bad, good])
        XCTAssertEqual(status.state.id, .buildInvalid)
        XCTAssertEqual(status.testable?.id, "b1")
    }

    // MARK: - Unrecognized values (spec §29)

    func testUnknownAppleValueDoesNotGuess() {
        let status = RuleEngine.resolve(
            groups: [group()], builds: [build(processing: "SOMETHING_NEW")])
        XCTAssertEqual(status.state.id, .unknown)
        XCTAssertEqual(status.state.rawEvidence["processingState"], "SOMETHING_NEW",
                       "the evidence behind the decision must be preserved verbatim")
    }

    func testUnknownInternalStateDoesNotGuess() {
        let status = RuleEngine.resolve(
            groups: [group()], builds: [build(internalState: "FUTURE_STATE")])
        XCTAssertEqual(status.state.id, .unknown)
    }

    // MARK: - Fingerprints

    /// Same ACTION_REQUIRED, different cause, must count as a new transition or nothing notifies.
    func testSameStateDifferentReasonIsADifferentFingerprint() {
        let expired = RuleEngine.resolve(groups: [group()], builds: [build(expired: true)]).state
        let rejected = RuleEngine.resolve(
            groups: [group()], builds: [build(externalState: "BETA_REJECTED")]).state
        XCTAssertEqual(expired.id, rejected.id)
        XCTAssertNotEqual(expired.fingerprint, rejected.fingerprint)
        XCTAssertNotEqual(expired, rejected)
    }

    /// A different build is a new transition even in the same state.
    func testDifferentBuildIsADifferentFingerprint() {
        let first = RuleEngine.resolve(groups: [group()], builds: [build(id: "b1")]).state
        let second = RuleEngine.resolve(groups: [group()], builds: [build(id: "b2")]).state
        XCTAssertEqual(first.id, second.id)
        XCTAssertNotEqual(first.fingerprint, second.fingerprint)
    }

    // MARK: - Determinism

    func testResolutionIsDeterministic() {
        let groups = [group()], builds = [build(externalState: "WAITING_FOR_BETA_REVIEW")]
        let first = RuleEngine.resolve(groups: groups, builds: builds).state
        for _ in 0..<50 {
            XCTAssertEqual(RuleEngine.resolve(groups: groups, builds: builds).state.fingerprint,
                           first.fingerprint)
        }
    }
}

final class RuntimeHelperTests: XCTestCase {
    func testRelativeTimeUsesSuppliedClock() {
        let now = Date(timeIntervalSince1970: 10_000)

        // Assert the bucket, not the rendered string — the rendering is localized.
        XCTAssertEqual(RelativeTime.bucket(nil, relativeTo: now), .never)
        XCTAssertEqual(RelativeTime.bucket(now.addingTimeInterval(-9), relativeTo: now), .justNow)
        XCTAssertEqual(RelativeTime.bucket(now.addingTimeInterval(-42), relativeTo: now), .seconds(42))
        XCTAssertEqual(RelativeTime.bucket(now.addingTimeInterval(-125), relativeTo: now), .minutes(2))
        XCTAssertEqual(RelativeTime.bucket(now.addingTimeInterval(-7_300), relativeTo: now), .hours(2))
        XCTAssertEqual(RelativeTime.bucket(now.addingTimeInterval(-172_800), relativeTo: now), .days(2))
    }

    func testNotificationSettingsURLTargetsTheApp() {
        XCTAssertEqual(
            Notifier.settingsURL(for: "app.betacue")?.absoluteString,
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=app.betacue")
    }
}
