import XCTest
@testable import BetaCue

/// 규칙 엔진은 이 제품의 전부다. 같은 입력에 항상 같은 출력이 나와야 한다. (명세 §2.1)
///
/// 결정론만 검사하면 "잘못 수집한 데이터를 일관되게 잘못 판정"해도 전부 통과한다.
/// 그래서 판정의 **의미**를 검사하는 케이스를 함께 둔다.
final class RuleEngineTests: XCTestCase {

    // MARK: - 픽스처

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

    // MARK: - 기본 판정

    func testNoBuildsMeansNeverShipped() {
        let status = RuleEngine.resolve(groups: [], builds: [])
        XCTAssertEqual(status.state.id, .noBuild)
        XCTAssertNil(status.testable)
    }

    func testProcessingReportsNoWorkForUser() {
        let status = RuleEngine.resolve(groups: [group()], builds: [build(processing: "PROCESSING")])
        XCTAssertEqual(status.state.id, .buildProcessing)
        XCTAssertNil(status.state.nextAction, "처리 중에는 사용자가 할 일이 없어야 한다")
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

    // MARK: - 배포 대상 판정 — 그룹 존재와 빌드 연결은 다른 사실이다

    /// 이 저장소가 만들어진 계기. 빌드는 멀쩡한데 받을 대상이 없어 조용히 실패하던 상태다.
    func testValidBuildWithNoGroupIsStranded() {
        let status = RuleEngine.resolve(groups: [], builds: [build(assignedGroups: [])])
        XCTAssertEqual(status.state.id, .buildReadyNotDistributed)
        XCTAssertEqual(status.state.reason, "NO_GROUPS")
        XCTAssertEqual(status.state.nextAction, .assignBuildToGroup)
        XCTAssertNil(status.testable)
    }

    /// 그룹은 있는데 이 빌드가 그 그룹에 안 붙어 있으면 배포된 게 아니다.
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

    /// 그룹이 하나도 없어도 개별 테스터가 붙어 있으면 배포된 것이다.
    func testIndividualTesterCountsAsDistribution() {
        let status = RuleEngine.resolve(
            groups: [], builds: [build(assignedGroups: [], individualTesters: 2)])
        XCTAssertNotEqual(status.state.id, .buildReadyNotDistributed,
                          "개별 초대된 테스터가 있으면 배포 대상 없음이 아니다")
        XCTAssertNotNil(status.testable)
    }

    /// 공개 링크가 켜져 있으면 등록 인원이 0명이어도 받을 사람이 생길 수 있다.
    func testPublicLinkCountsAsReachable() {
        let external = group(id: "g-public", name: "Public", testers: 0,
                             isInternal: false, publicLink: true)
        let status = RuleEngine.resolve(
            groups: [external],
            builds: [build(externalState: "IN_BETA_TESTING", assignedGroups: ["g-public"])])
        XCTAssertNotEqual(status.state.id, .buildReadyNotDistributed)
        XCTAssertEqual(status.state.id, .externalTestingReady)
    }

    /// 두 그룹 중 연결된 쪽만 대상이다.
    func testOnlyAssignedGroupCounts() {
        let g1 = group(id: "g1", name: "QA", testers: 3)
        let g2 = group(id: "g2", name: "Friends", testers: 9, isInternal: false)
        let status = RuleEngine.resolve(groups: [g1, g2], builds: [build(assignedGroups: ["g1"])])
        XCTAssertEqual(status.state.id, .internalTestingReady)
        XCTAssertEqual(status.audience, "내부 3명", "연결 안 된 g2의 9명은 세면 안 된다")
    }

    // MARK: - 두 축 — 최신 업로드와 현재 테스트 가능

    /// 최신 빌드가 처리 중이어도 이전 빌드로 계속 테스트할 수 있다는 사실을 잃으면 안 된다.
    func testProcessingBuildKeepsOlderBuildTestable() {
        let newer = build(id: "b43", number: "43", processing: "PROCESSING",
                          internalState: nil, assignedGroups: [])
        let older = build(id: "b42", number: "42")
        let status = RuleEngine.resolve(groups: [group()], builds: [newer, older])

        XCTAssertEqual(status.state.id, .buildProcessing, "최신 빌드 기준 상태는 처리 중")
        XCTAssertEqual(status.testable?.id, "b42", "이전 빌드는 계속 설치 가능해야 한다")
        XCTAssertTrue(status.hasOlderTestableBuild)
    }

    /// 최신 빌드가 곧 배포 중인 빌드면 "이전 버전" 안내가 뜨면 안 된다.
    func testLatestBuildIsTheTestableOne() {
        let status = RuleEngine.resolve(groups: [group()], builds: [build(id: "b1")])
        XCTAssertEqual(status.testable?.id, "b1")
        XCTAssertFalse(status.hasOlderTestableBuild)
    }

    /// 최신 빌드가 거부돼도 이전 배포본은 살아 있다.
    func testRejectedLatestKeepsOlderAlive() {
        let bad = build(id: "b2", number: "2", processing: "INVALID",
                        internalState: nil, assignedGroups: [])
        let good = build(id: "b1")
        let status = RuleEngine.resolve(groups: [group()], builds: [bad, good])
        XCTAssertEqual(status.state.id, .buildInvalid)
        XCTAssertEqual(status.testable?.id, "b1")
    }

    // MARK: - 모르는 값 (명세 §29)

    func testUnknownAppleValueDoesNotGuess() {
        let status = RuleEngine.resolve(
            groups: [group()], builds: [build(processing: "SOMETHING_NEW")])
        XCTAssertEqual(status.state.id, .unknown)
        XCTAssertEqual(status.state.rawEvidence["processingState"], "SOMETHING_NEW",
                       "판정 근거가 그대로 보존돼야 한다")
    }

    func testUnknownInternalStateDoesNotGuess() {
        let status = RuleEngine.resolve(
            groups: [group()], builds: [build(internalState: "FUTURE_STATE")])
        XCTAssertEqual(status.state.id, .unknown)
    }

    // MARK: - 지문

    /// 같은 ACTION_REQUIRED라도 원인이 바뀌면 새 전이로 봐야 알림이 나간다.
    func testSameStateDifferentReasonIsADifferentFingerprint() {
        let expired = RuleEngine.resolve(groups: [group()], builds: [build(expired: true)]).state
        let rejected = RuleEngine.resolve(
            groups: [group()], builds: [build(externalState: "BETA_REJECTED")]).state
        XCTAssertEqual(expired.id, rejected.id)
        XCTAssertNotEqual(expired.fingerprint, rejected.fingerprint)
        XCTAssertNotEqual(expired, rejected)
    }

    /// 빌드가 바뀌면 같은 상태라도 새 전이다.
    func testDifferentBuildIsADifferentFingerprint() {
        let first = RuleEngine.resolve(groups: [group()], builds: [build(id: "b1")]).state
        let second = RuleEngine.resolve(groups: [group()], builds: [build(id: "b2")]).state
        XCTAssertEqual(first.id, second.id)
        XCTAssertNotEqual(first.fingerprint, second.fingerprint)
    }

    // MARK: - 결정론

    func testResolutionIsDeterministic() {
        let groups = [group()], builds = [build(externalState: "WAITING_FOR_BETA_REVIEW")]
        let first = RuleEngine.resolve(groups: groups, builds: builds).state
        for _ in 0..<50 {
            XCTAssertEqual(RuleEngine.resolve(groups: groups, builds: builds).state.fingerprint,
                           first.fingerprint)
        }
    }
}
