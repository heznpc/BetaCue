import Foundation

/// 결정론적 상태 판정. LLM을 호출하지 않는다. (명세 §2.1, §23)
///
/// 같은 입력에는 항상 같은 출력이 나와야 한다. 여기에 추론이 들어가면 설계 실패다.
enum RuleEngine {
    /// Apple이 실제로 주는 값만 인정한다. 목록에 없으면 UNKNOWN으로 떨어뜨린다. (명세 §29)
    private static let knownProcessingStates: Set<String> =
        ["PROCESSING", "FAILED", "INVALID", "VALID"]
    private static let knownInternalStates: Set<String> =
        ["PROCESSING", "PROCESSING_EXCEPTION", "MISSING_EXPORT_COMPLIANCE",
         "READY_FOR_BETA_TESTING", "IN_BETA_TESTING", "EXPIRED",
         "IN_EXPORT_COMPLIANCE_REVIEW"]
    private static let knownExternalStates: Set<String> =
        ["PROCESSING", "PROCESSING_EXCEPTION", "MISSING_EXPORT_COMPLIANCE",
         "READY_FOR_BETA_TESTING", "IN_BETA_TESTING", "EXPIRED",
         "READY_FOR_BETA_SUBMISSION", "IN_EXPORT_COMPLIANCE_REVIEW",
         "WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW", "BETA_REJECTED",
         "BETA_APPROVED"]

    static func resolve(groups: [GroupSnapshot], builds: [BuildSnapshot]) -> AppStatus {
        let testable = currentlyTestable(groups: groups, builds: builds)
        let state = latestUploadState(groups: groups, builds: builds)
        return AppStatus(state: state,
                         testable: testable,
                         audience: testable.map { describeAudience($0, among: groups) })
    }

    /// 지금 실제로 설치할 수 있는 빌드. 최신 빌드가 아닐 수 있다.
    ///
    /// 최신 빌드가 처리 중이어도 이전 빌드로 계속 테스트할 수 있다는 사실을 잃지 않기 위해
    /// 최신 판정과 분리해서 따로 찾는다.
    static func currentlyTestable(groups: [GroupSnapshot], builds: [BuildSnapshot])
        -> BuildSnapshot?
    {
        builds.first { $0.isValid && $0.isReachable(among: groups) }
    }

    private static func describeAudience(_ build: BuildSnapshot, among groups: [GroupSnapshot])
        -> String
    {
        var parts: [String] = []
        let reachable = build.reachableAudience(among: groups)
        let internalCount = reachable.filter(\.isInternal).reduce(0) { $0 + $1.testerCount }
        let externalCount = reachable.filter { !$0.isInternal }.reduce(0) { $0 + $1.testerCount }

        if internalCount > 0 { parts.append("내부 \(internalCount)명") }
        if externalCount > 0 { parts.append("외부 \(externalCount)명") }
        if build.individualTesterCount > 0 { parts.append("개별 \(build.individualTesterCount)명") }
        if reachable.contains(where: { $0.publicLinkEnabled }) { parts.append("공개 링크") }

        return parts.isEmpty ? "대상 없음" : parts.joined(separator: " · ")
    }

    // MARK: - 최신 업로드 판정

    private static func latestUploadState(groups: [GroupSnapshot], builds: [BuildSnapshot])
        -> AppStateDefinition
    {
        guard let latest = builds.first else { return .make(.noBuild) }

        var evidence: [String: String] = [
            "buildID": latest.id,
            "build": latest.number,
            "processingState": latest.processingState,
        ]
        if let s = latest.platform { evidence["platform"] = s }
        if let s = latest.internalState { evidence["internalBuildState"] = s }
        if let s = latest.externalState { evidence["externalBuildState"] = s }
        if let d = latest.uploadedAt {
            evidence["uploadedDate"] = ISO8601DateFormatter().string(from: d)
        }
        evidence["assignedGroups"] = String(latest.assignedGroupIDs.count)
        evidence["individualTesters"] = String(latest.individualTesterCount)

        // 모르는 값이 하나라도 있으면 추측하지 않는다.
        guard knownProcessingStates.contains(latest.processingState) else {
            return .make(.unknown, evidence: evidence)
        }
        if let s = latest.internalState, !knownInternalStates.contains(s) {
            return .make(.unknown, evidence: evidence)
        }
        if let s = latest.externalState, !knownExternalStates.contains(s) {
            return .make(.unknown, evidence: evidence)
        }

        switch latest.processingState {
        case "PROCESSING":
            return .make(.buildProcessing, evidence: evidence,
                         detail: processingDetail(since: latest.uploadedAt))
        case "FAILED", "INVALID":
            return .make(.buildInvalid, evidence: evidence, reason: "REJECTED_BY_APPLE",
                         detail: "Apple이 빌드 \(latest.number)을(를) 거부했습니다. 새 빌드를 올려야 합니다.")
        case "VALID":
            break
        default:
            return .make(.unknown, evidence: evidence)
        }

        // 수출 규정 미답변은 처리가 끝나도 배포를 막는다. 흔하고, 원인이 안 보이는 종류다.
        if latest.internalState == "MISSING_EXPORT_COMPLIANCE"
            || latest.externalState == "MISSING_EXPORT_COMPLIANCE"
        {
            return .make(.actionRequired, evidence: evidence, reason: "MISSING_EXPORT_COMPLIANCE",
                         detail: "수출 규정(암호화 사용 여부)에 답해야 배포가 진행됩니다. App Store Connect에서 한 번만 답하면 됩니다.")
        }

        if latest.isExpired || latest.internalState == "EXPIRED" {
            return .make(.actionRequired, evidence: evidence, reason: "EXPIRED",
                         detail: "이 빌드는 만료됐습니다. TestFlight 빌드는 업로드 후 90일이 지나면 설치할 수 없습니다.")
        }

        if latest.externalState == "BETA_REJECTED" {
            return .make(.actionRequired, evidence: evidence, reason: "BETA_REJECTED",
                         detail: "Apple이 외부 테스트를 반려했습니다. 사유는 App Store Connect에서 확인할 수 있습니다.")
        }

        // 여기가 조용히 실패하는 자리다 — 빌드는 멀쩡한데 받을 사람이 없다.
        //
        // 앱에 그룹이 있는지가 아니라 **이 빌드에 연결된 그룹 중 받을 사람이 있는지**를 본다.
        // 그룹이 하나도 없어도 개별 테스터가 붙어 있으면 배포된 것이다.
        if !latest.isReachable(among: groups) {
            return .make(.buildReadyNotDistributed, evidence: evidence,
                         reason: strandedReason(latest, among: groups),
                         detail: strandedDetail(latest, among: groups))
        }

        // 받을 사람은 있다. 외부가 어디까지 왔는지로 갈린다.
        switch latest.externalState {
        case "IN_BETA_TESTING", "BETA_APPROVED":
            return .make(.externalTestingReady, evidence: evidence)
        case "WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW":
            return .make(.externalReviewPending, evidence: evidence)
        case "READY_FOR_BETA_SUBMISSION":
            return .make(.externalReviewRequired, evidence: evidence)
        default:
            return .make(.internalTestingReady, evidence: evidence)
        }
    }

    private static func strandedReason(_ build: BuildSnapshot, among groups: [GroupSnapshot])
        -> String
    {
        if groups.isEmpty { return "NO_GROUPS" }
        if build.assignedGroupIDs.isEmpty { return "BUILD_NOT_ASSIGNED" }
        return "GROUPS_EMPTY"
    }

    private static func strandedDetail(_ build: BuildSnapshot, among groups: [GroupSnapshot])
        -> String
    {
        if groups.isEmpty {
            return "테스터 그룹이 없습니다."
        }
        if build.assignedGroupIDs.isEmpty {
            return "이 빌드가 어떤 그룹에도 연결되지 않았습니다."
        }
        return "연결된 그룹에 등록된 테스터가 없고 공개 링크도 꺼져 있습니다."
    }

    /// 처리가 평소보다 길어지면 그 사실을 말해준다. 사용자가 "아직?"이라고 묻지 않게. (명세 UC-02)
    private static func processingDetail(since: Date?) -> String? {
        guard let since else { return nil }
        let minutes = Int(Date().timeIntervalSince(since) / 60)
        guard minutes >= 1 else { return nil }
        let elapsed = minutes < 60 ? "\(minutes)분 전에 업로드됨" : "\(minutes / 60)시간 전에 업로드됨"
        if minutes >= 30 {
            return "\(elapsed). 평소보다 오래 걸리고 있으나 조치할 것은 없습니다."
        }
        return "\(elapsed). 완료되면 알림을 보냅니다."
    }
}
