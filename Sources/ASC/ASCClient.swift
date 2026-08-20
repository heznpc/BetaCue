import CryptoKit
import Foundation

enum ASCError: LocalizedError, Equatable {
    case notConfigured
    case keyFileUnreadable(String)
    case badPrivateKey
    case http(status: Int, title: String, detail: String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "App Store Connect 키가 아직 설정되지 않았습니다."
        case .keyFileUnreadable(let path):
            return "키 파일을 읽지 못했습니다: \(path)"
        case .badPrivateKey:
            return "키 파일이 올바른 형식이 아닙니다. Apple에서 받은 .p8 파일이 맞는지 확인하세요."
        case .http(let status, let title, let detail):
            return detail.isEmpty ? "\(title) (HTTP \(status))" : detail
        case .transport(let message):
            return message
        }
    }
}

/// App Store Connect REST 클라이언트.
///
/// 토큰은 20분 만료로 발급하고 5분 여유를 두고 재발급한다. Apple 상한은 20분이다.
actor ASCClient {
    private let credentials: ASCCredentials
    private let session: URLSession
    private var cachedToken: (value: String, expiry: Date)?

    private static let base = URL(string: "https://api.appstoreconnect.apple.com")!
    private static let tokenLifetime: TimeInterval = 20 * 60
    private static let renewMargin: TimeInterval = 5 * 60

    init(credentials: ASCCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    // MARK: - 토큰

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
        // JWT ES256은 DER이 아니라 r‖s 원시 64바이트를 요구한다.
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

    // MARK: - 요청

    func get<T: Decodable>(_ path: String, as type: T.Type = T.self) async throws -> T {
        let data = try await send(path: path, method: "GET", body: nil)
        do {
            return try JSONDecoder.asc.decode(T.self, from: data)
        } catch {
            throw ASCError.transport("응답을 해석하지 못했습니다: \(error.localizedDescription)")
        }
    }

    /// 실패해도 전체를 무너뜨리면 안 되는 부수 조회용. 오류는 nil로 접는다.
    func getOrNil<T: Decodable>(_ path: String, as type: T.Type = T.self) async -> T? {
        try? await get(path, as: type)
    }

    func post<T: Decodable>(_ path: String, body: Encodable, as type: T.Type) async throws -> T {
        let encoded = try JSONEncoder().encode(AnyEncodable(body))
        let data = try await send(path: path, method: "POST", body: encoded)
        return try JSONDecoder.asc.decode(T.self, from: data)
    }

    /// 관계 생성처럼 성공 시 204 No Content를 주는 요청.
    ///
    /// 제네릭 `post`로 부르면 본문이 비어 있어 디코딩에서 실패한다 — 성공했는데 실패로 보인다.
    func postNoContent(_ path: String, body: Encodable) async throws {
        let encoded = try JSONEncoder().encode(AnyEncodable(body))
        _ = try await send(path: path, method: "POST", body: encoded)
    }

    func deleteNoContent(_ path: String, body: Encodable) async throws {
        let encoded = try JSONEncoder().encode(AnyEncodable(body))
        _ = try await send(path: path, method: "DELETE", body: encoded)
    }

    func delete(_ path: String) async throws {
        _ = try await send(path: path, method: "DELETE", body: nil)
    }

    private func send(path: String, method: String, body: Data?) async throws -> Data {
        guard let url = URL(string: path, relativeTo: Self.base) else {
            throw ASCError.transport("잘못된 경로: \(path)")
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
        } catch {
            throw ASCError.transport("App Store Connect에 연결하지 못했습니다: \(error.localizedDescription)")
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let parsed = try? JSONDecoder().decode(ASCErrorResponse.self, from: data)
            let first = parsed?.errors.first
            throw ASCError.http(status: status,
                                title: first?.title ?? "요청이 거부되었습니다",
                                detail: first?.detail ?? "")
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

/// `Encodable` 존재 타입을 인코딩하기 위한 얇은 래퍼.
private struct AnyEncodable: Encodable {
    private let encodeTo: (Encoder) throws -> Void
    init(_ wrapped: Encodable) { encodeTo = wrapped.encode(to:) }
    func encode(to encoder: Encoder) throws { try encodeTo(encoder) }
}
