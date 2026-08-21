import Foundation

/// App Store Connect API credentials.
///
/// The key file stays where Apple puts it (`~/.appstoreconnect/private_keys/AuthKey_<KeyID>.p8`).
/// BetaCue only remembers the path; it never copies or relocates the key.
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

    /// Key IDs actually present in the key directory. Onboarding lets you pick one.
    static func discoverKeyIDs() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: keyDirectory.path)) ?? []
        return names
            .filter { $0.hasPrefix("AuthKey_") && $0.hasSuffix(".p8") }
            .map { String($0.dropFirst("AuthKey_".count).dropLast(".p8".count)) }
            .sorted()
    }
}

// MARK: - Persisted configuration

/// `~/.config/betacue/config.json`. Never holds the key itself — only the Key ID and Issuer ID.
struct BetaCueConfig: Codable, Equatable, Sendable {
    var keyID: String = ""
    var issuerID: String = ""
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
