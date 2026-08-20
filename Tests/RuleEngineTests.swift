import XCTest
@testable import BetaCue

/// 규칙 엔진은 이 제품의 전부다. 같은 입력에 항상 같은 출력이 나와야 한다. (명세 §2.1)
final class RuleEngineTests: XCTestCase {

    private func build(
        number: String = "1",
        processing: String = "VALID",
        internalState: String? = "IN_BETA_TESTING",
        externalState: String? = nil,
        expired: Bool = false,
        uploaded: Date? = nil
    ) -> BuildSnapshot {
        BuildSnapshot(
            id: "b-\(number)", number: number, marketingVersion: "1.0.0",
            processingState: processing, internalState: internalState,
            externalState: externalState, uploadedAt: uploaded,
            expiresAt: nil, isExpired: expired)
    }

    private func group(testers: Int = 1, isInternal: Bool = true) -> GroupSnapshot {
        GroupSnapshot(id: "g", name: "Internal Testers", isInternal: isInternal,
                      testerCount: testers, autoDistributes: true, publicLink: nil)
    }

    func testNoBuildsMeansNeverShipped() {
        let state = RuleEngine.resolve(groups: [], builds: [])
        XCTAssertEqual(state.id, .noBuild)
        XCTAssertNil(state.blocker)
    }

    func testProcessingReportsNoWorkForUser() {
        let state = RuleEngine.resolve(groups: [group()], builds: [build(processing: "PROCESSING")])
        XCTAssertEqual(state.id, .buildProcessing)
        XCTAssertNil(state.nextAction, "처리 중에는 사용자가 할 일이 없어야 한다")
        XCTAssertEqual(state.notificationPolicy, .notifyWhenLeaving)
    }

    /// 이 저장소가 만들어진 계기. 빌드는 멀쩡한데 받을 그룹이 없어 조용히 실패하던 상태다.
    func testValidBuildWithNoGroupIsStranded() {
        let state = RuleEngine.resolve(groups: [], builds: [build()])
        XCTAssertEqual(state.id, .buildReadyNotDistributed)
        XCTAssertNotNil(state.blocker)
        XCTAssertEqual(state.nextAction, .assignBuildToGroup)
        XCTAssertEqual(state.severity, .warning)
    }

    func testGroupWithNoTesterIsAlsoStranded() {
        let state = RuleEngine.resolve(groups: [group(testers: 0)], builds: [build()])
        XCTAssertEqual(state.id, .buildReadyNotDistributed)
    }

    /// 빌드가 그룹에 연결되지 않으면 그룹·테스터가 있어도 배포된 게 아니다.
    func testBuildNotAttachedToGroupIsStranded() {
        let state = RuleEngine.resolve(
            groups: [group()], builds: [build(internalState: "READY_FOR_BETA_TESTING")])
        XCTAssertEqual(state.id, .buildReadyNotDistributed)
    }

    func testInternalTestingReady() {
        let state = RuleEngine.resolve(groups: [group()], builds: [build()])
        XCTAssertEqual(state.id, .internalTestingReady)
        XCTAssertEqual(state.severity, .success)
        XCTAssertNil(state.nextAction)
    }

    func testExternalReviewPending() {
        let state = RuleEngine.resolve(
            groups: [group()], builds: [build(externalState: "IN_BETA_REVIEW")])
        XCTAssertEqual(state.id, .externalReviewPending)
        XCTAssertNil(state.nextAction, "심사 중에는 기다리는 것 말고 할 일이 없다")
    }

    func testExternalTestingReady() {
        let state = RuleEngine.resolve(
            groups: [group()], builds: [build(externalState: "IN_BETA_TESTING")])
        XCTAssertEqual(state.id, .externalTestingReady)
    }

    func testMissingExportComplianceBlocksDistribution() {
        let state = RuleEngine.resolve(
            groups: [group()], builds: [build(internalState: "MISSING_EXPORT_COMPLIANCE")])
        XCTAssertEqual(state.id, .actionRequired)
        XCTAssertNotNil(state.blocker)
    }

    func testRejectedBuild() {
        let state = RuleEngine.resolve(groups: [group()], builds: [build(processing: "INVALID")])
        XCTAssertEqual(state.id, .buildInvalid)
        XCTAssertEqual(state.severity, .warning)
    }

    func testExpiredBuildNeedsAction() {
        let state = RuleEngine.resolve(groups: [group()], builds: [build(expired: true)])
        XCTAssertEqual(state.id, .actionRequired)
    }

    /// 명세 §29 — 모르는 값이 오면 추측하지 않고 원본을 그대로 보여준다.
    func testUnknownAppleValueDoesNotGuess() {
        let state = RuleEngine.resolve(
            groups: [group()], builds: [build(processing: "SOMETHING_NEW")])
        XCTAssertEqual(state.id, .unknown)
        XCTAssertEqual(state.rawEvidence["processingState"], "SOMETHING_NEW",
                       "판정 근거가 그대로 보존돼야 한다")
    }

    func testUnknownInternalStateDoesNotGuess() {
        let state = RuleEngine.resolve(
            groups: [group()], builds: [build(internalState: "FUTURE_STATE")])
        XCTAssertEqual(state.id, .unknown)
    }

    /// 결정론 확인 — 같은 입력을 반복해도 결과가 흔들리지 않아야 한다.
    func testResolutionIsDeterministic() {
        let groups = [group()], builds = [build(externalState: "WAITING_FOR_BETA_REVIEW")]
        let first = RuleEngine.resolve(groups: groups, builds: builds)
        for _ in 0..<50 {
            XCTAssertEqual(RuleEngine.resolve(groups: groups, builds: builds).id, first.id)
        }
    }

    func testLatestBuildDecidesState() {
        // 최신 빌드가 처리 중이면 이전 빌드가 배포돼 있어도 처리 중이 우선이다.
        let builds = [build(number: "2", processing: "PROCESSING"), build(number: "1")]
        XCTAssertEqual(RuleEngine.resolve(groups: [group()], builds: builds).id, .buildProcessing)
    }
}
