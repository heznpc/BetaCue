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
        individualTesterCount: Int? = 0
    ) -> BuildSnapshot {
        BuildSnapshot(
            id: "b1", number: "1", marketingVersion: "1.0.0", platform: "IOS",
            processingState: processing, internalState: internalState,
            externalState: externalState, betaStateIsKnown: betaStateIsKnown,
            uploadedAt: nil, expiresAt: nil, isExpired: false,
            assignedGroupIDs: assignedGroupIDs, individualTesterCount: individualTesterCount)
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
        XCTAssertEqual(status.state.reason, "BETA_STATE_UNREAD")
        XCTAssertNil(status.testable, "an unread beta state cannot be called installable")
    }

    /// P0-1. A failed attachment fetch used to look like "attached to nothing".
    func testUnreadAttachmentsResolveToUnknown() {
        let status = RuleEngine.resolve(
            groups: [group()], builds: [build(assignedGroupIDs: nil)])
        XCTAssertEqual(status.state.id, .unknown)
        XCTAssertEqual(status.state.reason, "AUDIENCE_UNREAD")
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
        XCTAssertEqual(status.state.reason, "PROCESSING_EXCEPTION")
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
    func testAttachedButNotYetLiveIsNotReady() {
        let status = RuleEngine.resolve(
            groups: [group()], builds: [build(internalState: "READY_FOR_BETA_TESTING")])
        XCTAssertEqual(status.state.id, .buildReadyNotDistributed)
        XCTAssertEqual(status.state.reason, "NOT_YET_LIVE")
        XCTAssertNil(status.testable)
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
