import Foundation

/// 정규화된 앱 상태. Apple 응답을 그대로 UI에 넘기지 않는다. (명세 §18, §19)
struct AppSnapshot: Identifiable, Sendable, Codable {
    var id: String
    var name: String
    var bundleID: String
    var groups: [GroupSnapshot]
    var builds: [BuildSnapshot]
    var stateID: AppStateID
    /// 조회 시각. "마지막 확인: 방금" 표시에 쓴다.
    var fetchedAt: Date

    /// 상태 정의는 저장하지 않고 필요할 때 다시 만든다 — 문구가 바뀌어도 DB를 안 건드린다.
    var state: AppStateDefinition {
        RuleEngine.resolve(groups: groups, builds: builds)
    }

    var latestBuild: BuildSnapshot? { builds.first }
    var testerCount: Int { groups.reduce(0) { $0 + $1.testerCount } }

    var appStoreConnectURL: URL? {
        URL(string: "https://appstoreconnect.apple.com/apps/\(id)/testflight/ios")
    }
}

struct GroupSnapshot: Identifiable, Sendable, Codable {
    var id: String
    var name: String
    var isInternal: Bool
    var testerCount: Int
    var autoDistributes: Bool
    var publicLink: String?
}

struct BuildSnapshot: Identifiable, Sendable, Codable {
    var id: String
    /// Apple이 "version"이라 부르는 값 — 실제로는 빌드 번호다.
    var number: String
    /// 마케팅 버전. preReleaseVersion에서 온다.
    var marketingVersion: String?
    var processingState: String
    var internalState: String?
    var externalState: String?
    var uploadedAt: Date?
    var expiresAt: Date?
    var isExpired: Bool

    var isValid: Bool { processingState == "VALID" && !isExpired }
    var isDistributedInternally: Bool { internalState == "IN_BETA_TESTING" }

    var daysUntilExpiry: Int? {
        guard let expiresAt else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: expiresAt).day
    }

    /// 히스토리 목록의 한 줄. 여기서도 Apple 용어를 그대로 쓰지 않는다.
    var humanState: String {
        if isExpired { return "만료됨" }
        switch processingState {
        case "PROCESSING": return "확인 중"
        case "FAILED", "INVALID": return "거부됨"
        case "VALID": return isDistributedInternally ? "테스트 가능" : "미배포"
        default: return processingState
        }
    }

    /// "1.3 (42)" 형태의 표시용 라벨.
    var displayVersion: String {
        guard let marketingVersion else { return "빌드 \(number)" }
        return "\(marketingVersion) (\(number))"
    }
}

struct CertificateSnapshot: Identifiable, Sendable, Codable {
    var id: String
    var name: String
    var type: String
    var expiresAt: Date?

    var daysLeft: Int? {
        guard let expiresAt else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: expiresAt).day
    }

    /// 60일 이내면 알림 대상. (명세 §12)
    var isExpiringSoon: Bool {
        guard let days = daysLeft else { return false }
        return days <= 60
    }
}
