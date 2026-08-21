import Foundation

// MARK: - JSON:API envelopes

struct ASCList<Attributes: Decodable & Sendable>: Decodable, Sendable {
    var data: [ASCResource<Attributes>]
    var meta: ASCMeta?
    var links: ASCLinks?

    /// Total the server knows about. Used to tell whether `limit` truncated the page.
    var total: Int { meta?.paging.total ?? data.count }
    var isTruncated: Bool { total > data.count }
}

/// Relationship endpoints return `{type, id}` only, with no attributes.
struct ASCRelationshipList: Decodable, Sendable {
    struct Ref: Decodable, Sendable { var id: String }
    var data: [Ref]
    var meta: ASCMeta?
    var links: ASCLinks?

    var ids: [String] { data.map(\.id) }
    var total: Int { meta?.paging.total ?? data.count }
}

/// Address of the next page. Its presence means unread items remain.
struct ASCLinks: Decodable, Sendable {
    var next: String?
}

struct ASCMeta: Decodable, Sendable {
    struct Paging: Decodable, Sendable {
        var total: Int
        var limit: Int?
    }
    var paging: Paging
}

/// A single resource. Apple sends `data: null` when the relationship is empty.
struct ASCSingle<Attributes: Decodable & Sendable>: Decodable, Sendable {
    var data: ASCResource<Attributes>?
}

struct ASCResource<Attributes: Decodable & Sendable>: Decodable, Sendable, Identifiable {
    var id: String
    var attributes: Attributes
}

// MARK: - Attributes

struct AppAttributes: Decodable, Sendable {
    var name: String
    var bundleId: String
    var sku: String?
}

struct BuildAttributes: Decodable, Sendable {

    /// What Apple calls "version" is the build number, not the marketing version.
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
    /// Apple returns this as null almost always. It cannot be used to tell who installed.
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

// MARK: - Decoding

extension JSONDecoder {
    /// Apple mixes ISO8601 with and without fractional seconds.
    ///
    /// `ISO8601DateFormatter` is a class and therefore not Sendable, so it cannot be captured
    /// in the `@Sendable` decoding closure. `Date.ISO8601FormatStyle` is a value type.
    static let asc: JSONDecoder = {
        let decoder = JSONDecoder()
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let plain = Date.ISO8601FormatStyle()

        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = try? withFraction.parse(raw) { return date }
            if let date = try? plain.parse(raw) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(localized: "unrecognized date format: \(raw)")))
        }
        return decoder
    }()
}
