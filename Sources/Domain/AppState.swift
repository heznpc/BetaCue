import Foundation

/// 내부 도메인 상태. Apple API 객체를 UI에 직접 매핑하지 않기 위한 중간 계층. (명세 §16)
///
/// 여기서 정의하는 문구가 제품의 본체다. Apple은 `processingState`,
/// `internalBuildState`, `externalBuildState`를 따로 주고 그 조합의 의미는 알려주지 않는다.
enum AppStateID: String, Codable, Sendable, CaseIterable {
    case noBuild = "NO_BUILD"
    case buildProcessing = "BUILD_PROCESSING"
    case buildInvalid = "BUILD_INVALID"
    case buildReadyNotDistributed = "BUILD_READY_NOT_DISTRIBUTED"
    case internalTestingReady = "INTERNAL_TESTING_READY"
    case externalReviewRequired = "EXTERNAL_REVIEW_REQUIRED"
    case externalReviewPending = "EXTERNAL_REVIEW_PENDING"
    case externalTestingReady = "EXTERNAL_TESTING_READY"
    case actionRequired = "ACTION_REQUIRED"
    case unknown = "UNKNOWN"
}

enum Severity: Int, Codable, Comparable, Sendable {
    case warning = 0, info = 1, success = 2, idle = 3

    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

    var symbol: String {
        switch self {
        case .warning: return "exclamationmark.triangle.fill"
        case .info:    return "clock.fill"
        case .success: return "checkmark.circle.fill"
        case .idle:    return "circle.dashed"
        }
    }

    /// 메뉴바 축약 표기. (명세 §14)
    var glyph: String {
        switch self {
        case .warning: return "⚠"
        case .info:    return "◷"
        case .success: return "●"
        case .idle:    return "○"
        }
    }
}

/// 알림을 언제 보낼지. (명세 §16, §12)
enum NotificationPolicy: String, Codable, Sendable {
    /// 이 상태를 벗어날 때 알린다. (예: 처리 중 → 준비 완료)
    case notifyWhenLeaving
    /// 이 상태에 들어올 때 알린다. (예: 배포 누락 발생)
    case notifyWhenEntering
    /// 알리지 않는다.
    case silent
}

/// 사용자가 실제로 누를 수 있는 행동. v0 범위는 두 개뿐이다. (명세 §26)
///
/// 업로드 파이프라인·테스터 CRUD·public link 설정은 §27에 따라 v0에서 제외한다.
enum NextAction: String, Codable, Sendable, Identifiable {
    case assignBuildToGroup = "ASSIGN_BUILD_TO_GROUP"
    case openInAppStoreConnect = "OPEN_IN_APP_STORE_CONNECT"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .assignBuildToGroup:    return "테스터에게 배포"
        case .openInAppStoreConnect: return "App Store Connect에서 열기"
        }
    }

    var symbol: String {
        switch self {
        case .assignBuildToGroup:    return "person.2.badge.plus"
        case .openInAppStoreConnect: return "arrow.up.forward.app"
        }
    }
}

/// 상태 하나의 완전한 정의. (명세 §16의 구조)
struct AppStateDefinition: Sendable, Equatable {
    var id: AppStateID
    var severity: Severity
    var headline: String
    var description: String
    /// 막힌 이유. 없으면 nil.
    var blocker: String?
    /// 지금 가장 적합한 행동 하나. 여러 개를 동시에 던지지 않는다. (명세 §11)
    var nextAction: NextAction?
    var notificationPolicy: NotificationPolicy
    /// 판정 근거가 된 Apple 원본 값. (명세 §15, §29)
    var rawEvidence: [String: String]

    /// 화면에 제목과 나란히 붙일 Apple 원어.
    ///
    /// 명세 §9가 금지하는 것은 원어를 **단독으로** 띄우는 것이지 원어 자체가 아니다.
    /// 해석한 문장 옆에 두면 Apple 문서 검색이나 외부 문의에 그대로 쓸 수 있다.
    var appleTerm: String? {
        let inner = rawEvidence["internalBuildState"]
        let outer = rawEvidence["externalBuildState"]
        switch (inner, outer) {
        case let (i?, o?): return i == o ? i : "\(i) / \(o)"
        case let (i?, nil): return i
        case let (nil, o?): return o
        default: return rawEvidence["processingState"]
        }
    }

    static func == (a: AppStateDefinition, b: AppStateDefinition) -> Bool {
        a.id == b.id && a.headline == b.headline && a.blocker == b.blocker
    }
}

// MARK: - 상태 사전

extension AppStateDefinition {
    /// 근거를 받아 상태 정의를 만든다. 문구는 여기 한 곳에만 존재한다.
    static func make(_ id: AppStateID, evidence: [String: String] = [:],
                     detail: String? = nil) -> AppStateDefinition
    {
        switch id {
        case .noBuild:
            return .init(id: id, severity: .idle,
                         headline: "업로드된 빌드 없음",
                         description: "App Store Connect에 앱 레코드만 있고 빌드를 보낸 적이 없습니다.",
                         blocker: nil, nextAction: .openInAppStoreConnect,
                         notificationPolicy: .silent, rawEvidence: evidence)

        case .buildProcessing:
            return .init(id: id, severity: .info,
                         headline: "Apple 처리 중",
                         description: detail
                            ?? "업로드는 완료됐습니다. 처리가 끝나면 테스트할 수 있으며 지금 할 일은 없습니다.",
                         blocker: nil, nextAction: nil,
                         notificationPolicy: .notifyWhenLeaving, rawEvidence: evidence)

        case .buildInvalid:
            return .init(id: id, severity: .warning,
                         headline: "빌드 거부됨",
                         description: detail ?? "Apple이 이 빌드를 거부했습니다. 새 빌드를 올려야 합니다.",
                         blocker: "Apple이 이 빌드를 거부했습니다.",
                         nextAction: .openInAppStoreConnect,
                         notificationPolicy: .notifyWhenEntering, rawEvidence: evidence)

        case .buildReadyNotDistributed:
            return .init(id: id, severity: .warning,
                         headline: "배포 대상 없음",
                         description: "빌드는 정상이지만 연결된 테스터가 없습니다. 이 상태로는 어떤 기기에도 나타나지 않습니다.",
                         blocker: detail ?? "테스트 대상이 연결되어 있지 않습니다.",
                         nextAction: .assignBuildToGroup,
                         notificationPolicy: .notifyWhenEntering, rawEvidence: evidence)

        case .internalTestingReady:
            return .init(id: id, severity: .success,
                         headline: "테스트 가능",
                         description: "아이폰 TestFlight 앱에서 바로 설치할 수 있습니다.",
                         blocker: nil, nextAction: nil,
                         notificationPolicy: .silent, rawEvidence: evidence)

        case .externalReviewRequired:
            return .init(id: id, severity: .info,
                         headline: "내부 테스트 가능",
                         description: "내 기기에서는 설치할 수 있습니다. 외부 테스터에게 보내려면 Apple 심사를 한 번 거쳐야 합니다.",
                         blocker: nil, nextAction: .openInAppStoreConnect,
                         notificationPolicy: .silent, rawEvidence: evidence)

        case .externalReviewPending:
            return .init(id: id, severity: .info,
                         headline: "외부 심사 중",
                         description: "심사가 끝나면 외부 테스터에게 배포됩니다. 보통 하루 안에 끝나며 지금 할 일은 없습니다.",
                         blocker: nil, nextAction: nil,
                         notificationPolicy: .notifyWhenLeaving, rawEvidence: evidence)

        case .externalTestingReady:
            return .init(id: id, severity: .success,
                         headline: "내부·외부 테스트 가능",
                         description: "내부 테스터와 초대한 외부 테스터 모두 설치할 수 있습니다.",
                         blocker: nil, nextAction: nil,
                         notificationPolicy: .silent, rawEvidence: evidence)

        case .actionRequired:
            return .init(id: id, severity: .warning,
                         headline: "조치 필요",
                         description: detail ?? "진행을 막고 있는 항목이 있습니다.",
                         blocker: detail, nextAction: .openInAppStoreConnect,
                         notificationPolicy: .notifyWhenEntering, rawEvidence: evidence)

        case .unknown:
            // 명세 §29 — 추측하지 않는다. 원본을 그대로 보여주고 Apple로 넘긴다.
            return .init(id: id, severity: .warning,
                         headline: "상태 판별 불가",
                         description: "Apple이 예상하지 못한 값을 반환했습니다. 아래 원본을 확인하거나 App Store Connect에서 직접 보십시오.",
                         blocker: nil, nextAction: .openInAppStoreConnect,
                         notificationPolicy: .notifyWhenEntering, rawEvidence: evidence)
        }
    }
}
