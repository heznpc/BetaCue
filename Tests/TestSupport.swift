import Foundation
@testable import BetaCue

/// A URLProtocol that answers from a script instead of the network.
///
/// Everything BetaCue believes about the world arrives through `URLSession`, so this is the
/// seam where failure conditions — 429, truncation, a foreign redirect target — can be
/// reproduced exactly rather than hoped about.
final class MockURLProtocol: URLProtocol {
    struct Response: Sendable {
        var status: Int
        var body: Data
        var headers: [String: String]

        init(status: Int = 200, body: Data = Data(), headers: [String: String] = [:]) {
            self.status = status
            self.body = body
            self.headers = headers
        }

        static func json(_ text: String, status: Int = 200,
                         headers: [String: String] = [:]) -> Response {
            Response(status: status, body: Data(text.utf8), headers: headers)
        }
    }

    /// Handler consulted for every request. Set it before making one.
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Response)?
    /// Every request that was made, in order, for asserting on what was actually sent.
    nonisolated(unsafe) private(set) static var recorded: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.withLock {
            handler = nil
            recorded = []
        }
    }

    static var requests: [URLRequest] { lock.withLock { recorded } }

    /// A session wired to this protocol and nothing else.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Answers each URL from a table, failing loudly on anything unexpected.
    ///
    /// Longer patterns win, because a dictionary has no order and `/betaGroups` is a substring
    /// of `/betaGroups/g1/relationships/betaTesters`. Matching by insertion luck made tests
    /// pass or fail depending on hashing.
    static func respond(_ table: [String: Response],
                        fallback: Response = .init(status: 404, body: Data())) {
        let ordered = table.sorted { $0.key.count > $1.key.count }
        handler = { request in
            let path = request.url.map { $0.path + ($0.query.map { "?\($0)" } ?? "") } ?? ""
            for (key, response) in ordered where path.contains(key) { return response }
            return fallback
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.recorded.append(request) }

        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let reply = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A flag that can be raised from a `@Sendable` callback and read back afterwards.
///
/// `withObservationTracking`'s onChange is `@Sendable`, so a plain captured `var` will not do.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    var isRaised: Bool { lock.withLock { raised } }
    func raise() { lock.withLock { raised = true } }
}

/// Holds a request open until the test lets it go.
///
/// Some of what Store has to get right is about *timing* — a key swapped while a fetch is in
/// flight, a refresh asked for while another is running. Without a way to stop a request
/// mid-air those races can only be hoped at. Once opened it stays open, so retries do not
/// deadlock against a one-shot signal.
final class RequestGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false

    func waitUntilOpen() {
        condition.lock()
        defer { condition.unlock() }
        while !isOpen { condition.wait() }
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }
}

/// Records notification decisions instead of showing banners.
final class FakeNotifier: NotificationSending, @unchecked Sendable {
    struct Sent: Equatable {
        var title: String
        var body: String
    }

    private let lock = NSLock()
    private var sent: [Sent] = []
    private var onFailure: (@MainActor @Sendable (String) -> Void)?

    var messages: [Sent] { lock.withLock { sent } }
    var count: Int { messages.count }

    func post(title: String, body: String) {
        lock.withLock { sent.append(Sent(title: title, body: body)) }
    }

    func observeFailures(_ handler: @escaping @MainActor @Sendable (String) -> Void) {
        lock.withLock { onFailure = handler }
    }

    /// Simulates macOS refusing a banner, which the real notifier reports asynchronously.
    @MainActor
    func reportFailure(_ message: String) {
        let handler = lock.withLock { onFailure }
        handler?(message)
    }
}

// MARK: - Fixtures

enum Fixture {
    /// A P-256 key in the shape Apple hands out, so JWT signing runs for real in tests.
    static let privateKeyPEM = """
    -----BEGIN PRIVATE KEY-----
    MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgevZzL1gdAFr88hb2
    OF/2NxApJCzGCEDdfSp6VQO30hyhRANCAAQRWz+jn65BtOMvdyHKcvjBeBSDZH2r
    1RTwjmYSi9R/zpBnuQ4EiMnCqfMPWiZqB4QdbAd0E7oH50VpuZ1P087G
    -----END PRIVATE KEY-----
    """

    /// Writes the key where `ASCCredentials` expects it and returns matching credentials.
    static func credentials(in directory: URL, keyID: String = "TESTKEY123") throws
        -> (ASCCredentials, URL)
    {
        let keyDir = directory.appendingPathComponent("private_keys", isDirectory: true)
        try FileManager.default.createDirectory(at: keyDir, withIntermediateDirectories: true)
        let url = keyDir.appendingPathComponent("AuthKey_\(keyID).p8")
        try privateKeyPEM.write(to: url, atomically: true, encoding: .utf8)
        return (ASCCredentials(keyID: keyID, issuerID: "issuer-1", keyDirectory: keyDir), url)
    }

    static func apps(_ ids: [String]) -> String {
        let entries = ids.map {
            """
            {"type":"apps","id":"\($0)","attributes":
             {"name":"App \($0)","bundleId":"app.\($0)"}}
            """
        }
        return #"{"data":[\#(entries.joined(separator: ","))],"meta":{"paging":{"total":\#(ids.count)}}}"#
    }

    static func builds(_ ids: [String], state: String = "VALID",
                       audienceType: String? = nil) -> String {
        let audience = audienceType.map { #","buildAudienceType":"\#($0)""# } ?? ""
        let entries = ids.map {
            """
            {"type":"builds","id":"\($0)","attributes":
             {"version":"\($0)","processingState":"\(state)","expired":false\(audience)}}
            """
        }
        return #"{"data":[\#(entries.joined(separator: ","))]}"#
    }

    static func groups(_ ids: [String], isInternal: Bool = true) -> String {
        let entries = ids.map {
            """
            {"type":"betaGroups","id":"\($0)","attributes":
             {"name":"Group \($0)","isInternalGroup":\(isInternal),
              "hasAccessToAllBuilds":true}}
            """
        }
        return #"{"data":[\#(entries.joined(separator: ","))]}"#
    }

    static func relationship(_ ids: [String]) -> String {
        let entries = ids.map { #"{"type":"x","id":"\#($0)"}"# }
        return #"{"data":[\#(entries.joined(separator: ","))],"meta":{"paging":{"total":\#(ids.count)}}}"#
    }

    static func betaDetail(internalState: String = "IN_BETA_TESTING",
                           externalState: String? = nil) -> String {
        let ext = externalState.map { #","externalBuildState":"\#($0)""# } ?? ""
        let attrs = #""internalBuildState":"\#(internalState)""# + ext
        return #"{"data":{"type":"buildBetaDetails","id":"d","attributes":{\#(attrs)}}}"#
    }

    /// A certificate close enough to expiry that BetaCue is supposed to say something.
    static func expiringCertificate(daysFromNow: Int, id: String = "c1") -> String {
        let expiry = Date().addingTimeInterval(Double(daysFromNow) * 86_400 + 3_600)
        let stamp = expiry.formatted(.iso8601)
        return """
        {"data":[{"type":"certificates","id":"\(id)","attributes":
         {"name":"Developer ID Application","certificateType":"DEVELOPER_ID_APPLICATION",
          "expirationDate":"\(stamp)"}}]}
        """
    }

    static let emptyRelationship = #"{"data":[],"meta":{"paging":{"total":0}}}"#
    static let nullSingle = #"{"data":null}"#
}
