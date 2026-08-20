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

    static func resolve(groups: [GroupSnapshot], builds: [BuildSnapshot]) -> AppStateDefinition {
        guard let latest = builds.first else {
            return .make(.noBuild)
        }

        var evidence: [String: String] = [
            "build": latest.number,
            "processingState": latest.processingState,
        ]
        if let s = latest.internalState { evidence["internalBuildState"] = s }
        if let s = latest.externalState { evidence["externalBuildState"] = s }
        if let d = latest.uploadedAt {
            evidence["uploadedDate"] = ISO8601DateFormatter().string(from: d)
        }

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
            return .make(.buildInvalid, evidence: evidence,
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
            return .make(.actionRequired, evidence: evidence,
                         detail: "수출 규정(암호화 사용 여부)에 답해야 배포가 진행됩니다. App Store Connect에서 한 번만 답하면 됩니다.")
        }

        if latest.isExpired || latest.internalState == "EXPIRED" {
            return .make(.actionRequired, evidence: evidence,
                         detail: "이 빌드는 만료됐습니다. TestFlight 빌드는 업로드 후 90일이 지나면 설치할 수 없습니다.")
        }

        if latest.externalState == "BETA_REJECTED" {
            return .make(.actionRequired, evidence: evidence,
                         detail: "Apple이 외부 테스트를 반려했습니다. 사유는 App Store Connect에서 확인할 수 있습니다.")
        }

        // 여기가 조용히 실패하는 자리다 — 빌드는 멀쩡한데 받을 대상이 없다.
        // 이 저장소가 만들어진 계기이므로 판정 순서에서 뒤로 밀지 않는다.
        if groups.isEmpty {
            return .make(.buildReadyNotDistributed, evidence: evidence,
                         detail: "테스터 그룹이 없습니다.")
        }
        if groups.allSatisfy({ $0.testerCount == 0 }) {
            return .make(.buildReadyNotDistributed, evidence: evidence,
                         detail: "그룹은 있으나 등록된 테스터가 없습니다.")
        }
        guard latest.internalState == "IN_BETA_TESTING" else {
            return .make(.buildReadyNotDistributed, evidence: evidence,
                         detail: "이 빌드가 어떤 그룹에도 연결되지 않았습니다.")
        }

        // 내부는 열렸다. 외부가 어디까지 왔는지로 갈린다.
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
