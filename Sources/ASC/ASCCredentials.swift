import Foundation

/// App Store Connect API 자격증명.
///
/// 키 파일은 Apple이 정한 자리(`~/.appstoreconnect/private_keys/AuthKey_<KeyID>.p8`)에
/// 그대로 둔다. 앱은 경로만 알고 있고 키를 복사하거나 옮기지 않는다.
struct ASCCredentials: Equatable, Sendable {
    var keyID: String
    var issuerID: String

    static let keyDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".appstoreconnect/private_keys", isDirectory: true)

    var privateKeyURL: URL {
        Self.keyDirectory.appendingPathComponent("AuthKey_\(keyID).p8")
    }

    func privateKeyPEM() throws -> String {
        do {
            return try String(contentsOf: privateKeyURL, encoding: .utf8)
        } catch {
            throw ASCError.keyFileUnreadable(privateKeyURL.path)
        }
    }

    /// 키 디렉터리에 실재하는 Key ID 목록. 온보딩에서 고르게 한다.
    static func discoverKeyIDs() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: keyDirectory.path)) ?? []
        return names
            .filter { $0.hasPrefix("AuthKey_") && $0.hasSuffix(".p8") }
            .map { String($0.dropFirst("AuthKey_".count).dropLast(".p8".count)) }
            .sorted()
    }
}

// MARK: - 설정 저장

/// `~/.config/betacue/config.json`. 키 자체는 절대 담지 않는다 — Key ID와 Issuer ID뿐이다.
struct BetaCueConfig: Codable, Equatable, Sendable {
    var keyID: String = ""
    var issuerID: String = ""
    /// 번들 ID → 로컬 프로젝트. 업로드 기능이 쓴다.
    var projects: [String: ProjectRef] = [:]

    struct ProjectRef: Codable, Equatable, Sendable {
        var kind: Kind
        /// .xcodeproj 경로
        var projectPath: String
        var scheme: String
        /// Unity 익스포트처럼 CFBundleVersion이 리터럴인 경우 직접 고쳐야 한다.
        var infoPlistPath: String?

        enum Kind: String, Codable, Sendable {
            case xcodeproj
            case unityExport
        }
    }

    var credentials: ASCCredentials? {
        guard !keyID.isEmpty, !issuerID.isEmpty else { return nil }
        return ASCCredentials(keyID: keyID, issuerID: issuerID)
    }

    static let url = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".config/betacue/config.json")

    static func load() -> BetaCueConfig {
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(BetaCueConfig.self, from: data)
        else { return BetaCueConfig() }
        return cfg
    }

    func save() throws {
        let dir = Self.url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url, options: .atomic)
    }
}
