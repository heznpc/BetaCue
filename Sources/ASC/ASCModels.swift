import Foundation

// MARK: - JSON:API 봉투

struct ASCList<Attributes: Decodable & Sendable>: Decodable, Sendable {
    var data: [ASCResource<Attributes>]
    var meta: ASCMeta?

    /// 서버가 아는 전체 개수. limit에 걸려 잘렸는지 판단할 때 쓴다.
    var total: Int { meta?.paging.total ?? data.count }
    var isTruncated: Bool { total > data.count }
}

/// 관계 엔드포인트는 속성 없이 `{type, id}`만 준다.
struct ASCRelationshipList: Decodable, Sendable {
    struct Ref: Decodable, Sendable { var id: String }
    var data: [Ref]
    var meta: ASCMeta?

    var ids: [String] { data.map(\.id) }
    var total: Int { meta?.paging.total ?? data.count }
}

struct ASCMeta: Decodable, Sendable {
    struct Paging: Decodable, Sendable {
        var total: Int
        var limit: Int?
    }
    var paging: Paging
}

/// 단일 리소스. 관계가 비어 있으면 Apple이 `data: null`을 준다.
struct ASCSingle<Attributes: Decodable & Sendable>: Decodable, Sendable {
    var data: ASCResource<Attributes>?
}

struct ASCResource<Attributes: Decodable & Sendable>: Decodable, Sendable, Identifiable {
    var id: String
    var attributes: Attributes
}

// MARK: - 속성

struct AppAttributes: Decodable, Sendable {
    var name: String
    var bundleId: String
    var sku: String?
}

struct BuildAttributes: Decodable, Sendable {

    /// Apple이 말하는 "version"은 사실 빌드 번호다. 마케팅 버전이 아니다.
    var version: String?
    var processingState: String?
    var uploadedDate: Date?
    var expirationDate: Date?
    var expired: Bool?
    var usesNonExemptEncryption: Bool?
    var minOsVersion: String?
}

struct BuildBetaDetailAttributes: Decodable, Sendable {
    var autoNotifyEnabled: Bool?
    var internalBuildState: String?
    var externalBuildState: String?
}

struct BetaGroupAttributes: Decodable, Sendable {
    var name: String
    var isInternalGroup: Bool
    var hasAccessToAllBuilds: Bool?
    var publicLinkEnabled: Bool?
    var publicLink: String?
    var publicLinkLimit: Int?
    var feedbackEnabled: Bool?
    var createdDate: Date?
}

struct BetaTesterAttributes: Decodable, Sendable {
    var firstName: String?
    var lastName: String?
    var email: String?
    var inviteType: String?
    /// Apple이 이 필드를 거의 항상 null로 준다. 설치 여부 판단에 쓸 수 없다.
    var state: String?
}

struct CertificateAttributes: Decodable, Sendable {
    var name: String?
    var certificateType: String?
    var expirationDate: Date?
}

struct PreReleaseVersionAttributes: Decodable, Sendable {
    var version: String?
    var platform: String?
}

struct BetaBuildLocalizationAttributes: Decodable, Sendable {
    var whatsNew: String?
    var locale: String?
}

struct FeedbackScreenshotAttributes: Decodable, Sendable {
    var createdDate: Date?
    var comment: String?
    var deviceModel: String?
    var osVersion: String?
}

struct FeedbackCrashAttributes: Decodable, Sendable {
    var createdDate: Date?
    var comment: String?
    var deviceModel: String?
    var osVersion: String?
}

// MARK: - 디코딩

extension JSONDecoder {
    /// Apple은 ISO8601을 소수점 초가 있는 형태와 없는 형태를 섞어서 준다.
    ///
    /// `ISO8601DateFormatter`는 클래스라 Sendable이 아니어서 `@Sendable` 디코딩 클로저에
    /// 캡처할 수 없다. 값 타입인 `Date.ISO8601FormatStyle`을 쓴다.
    static let asc: JSONDecoder = {
        let decoder = JSONDecoder()
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let plain = Date.ISO8601FormatStyle()

        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = try? withFraction.parse(raw) { return date }
            if let date = try? plain.parse(raw) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "날짜 형식을 알 수 없음: \(raw)"))
        }
        return decoder
    }()
}
