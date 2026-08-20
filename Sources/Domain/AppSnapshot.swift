import Foundation

/// 정규화된 앱 상태. Apple 응답을 그대로 UI에 넘기지 않는다. (명세 §18, §19)
struct AppSnapshot: Identifiable, Sendable, Codable {
    var id: String
    var name: String
    var bundleID: String
    var groups: [GroupSnapshot]
    var builds: [BuildSnapshot]
    var fetchedAt: Date
    /// 이 앱을 읽는 도중 실패한 부수 조회. 하나 실패해도 나머지 앱은 갱신된다.
    var partialErrors: [String] = []

    /// 상태는 저장하지 않고 필요할 때 다시 계산한다 — 문구가 바뀌어도 DB를 안 건드린다.
    var status: AppStatus { RuleEngine.resolve(groups: groups, builds: builds) }

    var latestBuild: BuildSnapshot? { builds.first }
    var isPartial: Bool { !partialErrors.isEmpty }

    var appStoreConnectURL: URL? {
        URL(string: "https://appstoreconnect.apple.com/apps/\(id)/testflight/ios")
    }
}

/// 사용자가 실제로 묻는 두 가지가 서로 다른 질문이라 상태도 두 축이다.
///
///   "새 버전 됐나?"           → `state`  (최신 업로드 기준)
///   "지금 테스터가 받을 수 있나?" → `testable` (실제 배포 중인 빌드)
///
/// 최신 빌드가 처리 중이어도 이전 빌드로 계속 테스트할 수 있다. 하나로 합치면 그 사실을 잃는다.
struct AppStatus: Sendable {
    var state: AppStateDefinition
    /// 지금 설치 가능한 빌드. 최신 빌드와 같을 수도, 이전 빌드일 수도, 없을 수도 있다.
    var testable: BuildSnapshot?
    /// 그 빌드를 누가 받을 수 있는지에 대한 한 줄. 없으면 nil.
    var audience: String?

    /// 최신 빌드가 아직 못 나갔는데 이전 빌드가 서비스 중인 상황.
    var hasOlderTestableBuild: Bool {
        guard let testable, let latestID = state.rawEvidence["buildID"] else { return false }
        return testable.id != latestID
    }
}

struct GroupSnapshot: Identifiable, Sendable, Codable {
    var id: String
    var name: String
    var isInternal: Bool
    var testerCount: Int
    var autoDistributes: Bool
    var publicLinkEnabled: Bool
    var publicLink: String?
    /// limit에 잘려 테스터 수가 실제보다 적을 수 있는지.
    var testerCountIsExact: Bool = true

    /// 이 그룹을 통해 실제로 앱을 받을 사람이 존재하는가.
    ///
    /// 공개 링크가 켜져 있으면 등록된 테스터가 0명이어도 받을 사람이 생길 수 있다.
    var canReachSomeone: Bool { testerCount > 0 || publicLinkEnabled }
}

struct BuildSnapshot: Identifiable, Sendable, Codable {
    var id: String
    /// Apple이 "version"이라 부르는 값 — 실제로는 빌드 번호다.
    var number: String
    var marketingVersion: String?
    var platform: String?
    var processingState: String
    var internalState: String?
    var externalState: String?
    var uploadedAt: Date?
    var expiresAt: Date?
    var isExpired: Bool
    /// 이 빌드가 연결된 베타 그룹. 앱에 그룹이 있다는 것과 이 빌드가 그 그룹에 붙었다는 건 다르다.
    var assignedGroupIDs: [String] = []
    /// 그룹 없이 이 빌드에만 직접 초대된 테스터 수.
    var individualTesterCount: Int = 0

    var isValid: Bool { processingState == "VALID" && !isExpired }
    var isDistributedInternally: Bool { internalState == "IN_BETA_TESTING" }

    var daysUntilExpiry: Int? {
        guard let expiresAt else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: expiresAt).day
    }

    /// 이 빌드를 실제로 받을 수 있는 사람이 있는가.
    func reachableAudience(among groups: [GroupSnapshot]) -> [GroupSnapshot] {
        groups.filter { assignedGroupIDs.contains($0.id) && $0.canReachSomeone }
    }

    func isReachable(among groups: [GroupSnapshot]) -> Bool {
        individualTesterCount > 0 || !reachableAudience(among: groups).isEmpty
    }

    /// 히스토리 목록의 한 줄.
    var humanState: String {
        if isExpired { return "만료됨" }
        switch processingState {
        case "PROCESSING": return "확인 중"
        case "FAILED", "INVALID": return "거부됨"
        case "VALID": return isDistributedInternally ? "테스트 가능" : "미배포"
        default: return processingState
        }
    }

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
