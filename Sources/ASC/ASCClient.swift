import CryptoKit
import Foundation

/// A list that knows whether it is the whole list.
struct PagedResult<Element: Sendable>: Sendable {
    var values: [Element]
    var isComplete: Bool
}

enum ASCError: LocalizedError, Equatable {
    case notConfigured
    case keyFileUnreadable(String)
    case badPrivateKey
    case http(status: Int, title: String, detail: String, retryAfter: Double?)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(localized: "App Store Connect key is not configured yet.")
        case .keyFileUnreadable(let path):
            return String(localized: "Couldn't read the key file: \(path)")
        case .badPrivateKey:
            return String(localized: "That key file isn't in the expected format. Check that it's the .p8 Apple gave you.")
        case .http(let status, let title, let detail, _):
            return detail.isEmpty ? String(localized: "\(title) (HTTP \(status))") : detail
        case .transport(let message):
            return message
        }
    }
}

/// App Store Connect REST client.
///
/// Tokens are minted with a 20-minute expiry and renewed 5 minutes early. Apple's ceiling is 20 minutes.
actor ASCClient {
    private let credentials: ASCCredentials
    private let session: URLSession
    private var cachedToken: (value: String, expiry: Date)?

    private static let base = URL(string: "https://api.appstoreconnect.apple.com")!
    private static let tokenLifetime: TimeInterval = 20 * 60
    private static let renewMargin: TimeInterval = 5 * 60

    /// Scales the retry backoff. Tests set it to zero so a ceiling case doesn't sleep for
    /// seven seconds to prove a policy that is really about ordering, not duration.
    private let retryDelayScale: Double

    init(credentials: ASCCredentials, session: URLSession = .shared,
         retryDelayScale: Double = 1.0)
    {
        self.credentials = credentials
        self.session = session
        self.retryDelayScale = retryDelayScale
    }

    // MARK: - Token

    private func token() throws -> String {
        if let cached = cachedToken, cached.expiry.timeIntervalSinceNow > Self.renewMargin {
            return cached.value
        }
        let expiry = Date().addingTimeInterval(Self.tokenLifetime)
        let jwt = try makeJWT(expiry: expiry)
        cachedToken = (jwt, expiry)
        return jwt
    }

    private func makeJWT(expiry: Date) throws -> String {
        let header: [String: String] = ["alg": "ES256", "kid": credentials.keyID, "typ": "JWT"]
        let payload: [String: Any] = [
            "iss": credentials.issuerID,
            "iat": Int(Date().timeIntervalSince1970),
            "exp": Int(expiry.timeIntervalSince1970),
            "aud": "appstoreconnect-v1",
        ]
        let signingInput = try Self.base64URL(json: header) + "." + Self.base64URL(json: payload)

        let pem = try credentials.privateKeyPEM()
        let key: P256.Signing.PrivateKey
        do {
            key = try P256.Signing.PrivateKey(pemRepresentation: pem)
        } catch {
            throw ASCError.badPrivateKey
        }
        // ES256 JWTs want the raw 64-byte r‖s pair, not a DER signature.
        let signature = try key.signature(for: Data(signingInput.utf8))
        return signingInput + "." + Self.base64URL(signature.rawRepresentation)
    }

    private static func base64URL(json: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return base64URL(data)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Requests

    func get<T: Decodable>(_ path: String, as type: T.Type = T.self) async throws -> T {
        let data = try await send(path: path, method: "GET", body: nil)
        do {
            return try JSONDecoder.asc.decode(T.self, from: data)
        } catch {
            throw ASCError.transport(String(localized: "Couldn't parse the response: \(error.localizedDescription)"))
        }
    }

    /// Follows `links.next` until everything is collected.
    ///
    /// Apple caps a page at 200. Using a truncated count silently undercounts testers,
    /// and that number is what decides "this build reaches nobody".
    /// A page ceiling keeps a runaway response from looping forever.
    func getAllPages<T: Decodable & Sendable>(
        _ path: String, as type: T.Type = T.self, maxPages: Int = 20
    ) async throws -> [ASCResource<T>] where T: Sendable {
        try await getAllPagesResult(path, as: type, maxPages: maxPages).values
    }

    /// Like `getAllPages`, but says whether the ceiling cut the results short.
    ///
    /// Returning a silently truncated array let callers treat a partial list as complete —
    /// the same class of mistake as treating a failed fetch as an empty one.
    func getAllPagesResult<T: Decodable & Sendable>(
        _ path: String, as type: T.Type = T.self, maxPages: Int = 20
    ) async throws -> PagedResult<ASCResource<T>> {
        var collected: [ASCResource<T>] = []
        var next: String? = path
        var pages = 0

        while let current = next, pages < maxPages {
            let page: ASCList<T> = try await get(current)
            collected += page.data
            next = page.links?.next
            pages += 1
        }
        return PagedResult(values: collected, isComplete: next == nil)
    }

    /// Every page of a relationship listing.
    func getAllRelationshipIDs(_ path: String, maxPages: Int = 20) async throws
        -> PagedResult<String>
    {
        var collected: [String] = []
        var next: String? = path
        var pages = 0

        while let current = next, pages < maxPages {
            let page: ASCRelationshipList = try await get(current)
            collected += page.ids
            next = page.links?.next
            pages += 1
        }
        return PagedResult(values: collected, isComplete: next == nil)
    }

    /// For secondary fetches that must not take the whole refresh down. Errors collapse to nil.
    func getOrNil<T: Decodable>(_ path: String, as type: T.Type = T.self) async -> T? {
        try? await get(path, as: type)
    }

    func post<T: Decodable>(_ path: String, body: Encodable, as type: T.Type) async throws -> T {
        let encoded = try JSONEncoder().encode(AnyEncodable(body))
        let data = try await send(path: path, method: "POST", body: encoded)
        return try JSONDecoder.asc.decode(T.self, from: data)
    }

    /// For requests that answer 204 No Content on success, such as creating a relationship.
    ///
    /// The generic `post` would fail decoding an empty body and report success as failure.
    func postNoContent(_ path: String, body: Encodable) async throws {
        let encoded = try JSONEncoder().encode(AnyEncodable(body))
        _ = try await send(path: path, method: "POST", body: encoded)
    }


    func delete(_ path: String) async throws {
        _ = try await send(path: path, method: "DELETE", body: nil)
    }

    /// Apple answers 429 when a burst is too wide, and 5xx transiently. Neither is a real
    /// verdict about the data, but the layers above turn a failed fetch into "unknown" and
    /// then into a user-visible warning. Retrying here keeps transient noise out of the
    /// state machine. 4xx other than 429 is a real answer and is never retried.
    private static let maxAttempts = 4

    private func send(path: String, method: String, body: Data?) async throws -> Data {
        var attempt = 0
        while true {
            // Being cancelled is not a transport failure, and the two were folded together.
            // A cancelled refresh kept retrying to the ceiling, and `try?` around the backoff
            // swallowed the cancellation as well, so the work ran to completion and its answer
            // came back to a caller that had already given up on it.
            try Task.checkCancellation()
            attempt += 1
            do {
                return try await sendOnce(path: path, method: method, body: body)
            } catch let error as ASCError {
                guard attempt < Self.maxAttempts,
                      let delay = Self.retryDelay(for: error, attempt: attempt)
                else { throw error }
                let scaled = delay * retryDelayScale
                // Not `try?`: waiting to retry is exactly when a cancellation arrives.
                if scaled > 0 { try await Task.sleep(for: .seconds(scaled)) }
            }
        }
    }

    /// Seconds to wait, or nil when the failure is final.
    private static func retryDelay(for error: ASCError, attempt: Int) -> Double? {
        switch error {
        case .http(let status, _, _, let retryAfter):
            guard status == 429 || (500..<600).contains(status) else { return nil }
            if let retryAfter { return min(retryAfter, 30) }
        case .transport:
            break   // connection-level failures are worth one more try
        default:
            return nil
        }
        // Exponential with jitter so parallel callers don't line up on the same instant.
        let base = pow(2.0, Double(attempt - 1))
        return min(base, 8) + Double.random(in: 0...0.4)
    }

    private func sendOnce(path: String, method: String, body: Data?) async throws -> Data {
        // links.next arrives as an absolute URL, so accept both absolute and relative paths.
        let resolved: URL?
        if path.hasPrefix("http") {
            // A bearer token rides on every request, so never follow a host we did not expect.
            guard let candidate = URL(string: path),
                  candidate.scheme == "https",
                  candidate.host == Self.base.host
            else { throw ASCError.transport(String(localized: "Refused an unexpected host: \(path)")) }
            resolved = candidate
        } else {
            resolved = URL(string: path, relativeTo: Self.base)
        }
        guard let url = resolved else {
            throw ASCError.transport(String(localized: "Invalid path: \(path)"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            // URLSession reports a cancelled task this way. Dressed as a transport error it
            // would be retried, and the caller would never learn it had been called off.
            throw CancellationError()
        } catch {
            throw ASCError.transport(String(localized: "Couldn't reach App Store Connect: \(error.localizedDescription)"))
        }

        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let parsed = try? JSONDecoder().decode(ASCErrorResponse.self, from: data)
            let first = parsed?.errors.first
            let retryAfter = (http?.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init)
            throw ASCError.http(status: status,
                                title: first?.title ?? String(localized: "The request was refused"),
                                detail: first?.detail ?? "",
                                retryAfter: retryAfter)
        }
        return data
    }
}

private struct ASCErrorResponse: Decodable {
    struct Item: Decodable {
        var title: String?
        var detail: String?
    }
    var errors: [Item]
}

/// Thin wrapper so an existential `Encodable` can be encoded.
private struct AnyEncodable: Encodable {
    private let encodeTo: (Encoder) throws -> Void
    init(_ wrapped: Encodable) { encodeTo = wrapped.encode(to:) }
    func encode(to encoder: Encoder) throws { try encodeTo(encoder) }
}
