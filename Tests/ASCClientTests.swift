import XCTest
@testable import BetaCue

/// The contract with Apple's API — the boundary every belief in this app crosses.
///
/// Everything above this layer trusts what comes out of it, so the failure shapes are pinned
/// here rather than discovered in production.
final class ASCClientTests: XCTestCase {
    private var directory: URL!
    private var credentials: ASCCredentials!
    private var session: URLSession!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("betacue-asc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        (credentials, _) = try Fixture.credentials(in: directory)
        session = MockURLProtocol.makeSession()
        MockURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        MockURLProtocol.reset()
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeClient() -> ASCClient {
        ASCClient(credentials: credentials, session: session, retryDelayScale: 0)
    }

    // MARK: - Success shapes

    func testDecodesA200Response() async throws {
        MockURLProtocol.respond(["/v1/apps": .json(Fixture.apps(["a1", "a2"]))])
        let list: ASCList<AppAttributes> = try await makeClient().get("/v1/apps")
        XCTAssertEqual(list.data.map(\.id), ["a1", "a2"])
        XCTAssertEqual(list.data.first?.attributes.bundleId, "app.a1")
        XCTAssertEqual(list.total, 2)
    }

    func testSignsEveryRequestWithABearerToken() async throws {
        MockURLProtocol.respond(["/v1/apps": .json(Fixture.apps([]))])
        _ = try? await makeClient().get("/v1/apps", as: ASCList<AppAttributes>.self)
        let auth = MockURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(auth?.hasPrefix("Bearer eyJ"), true, "an ES256 JWT should be attached")
    }

    /// Relationship writes answer 204 with no body; decoding one would fail a successful call.
    func testPostNoContentAcceptsAnEmpty204() async throws {
        MockURLProtocol.respond(["/relationships/betaGroups": .init(status: 204)])
        try await makeClient().postNoContent("/v1/builds/b1/relationships/betaGroups",
                                             body: ["data": [String]()])
        XCTAssertEqual(MockURLProtocol.requests.first?.httpMethod, "POST")
    }

    // MARK: - Cancellation

    /// P1-8. Cancellation used to arrive dressed as a transport error, which is a retryable
    /// shape — so a call that had already been given up on was tried again up to the ceiling
    /// and its answer came back to nobody.
    func testCancellationSurfacesInsteadOfBeingRetried() async throws {
        MockURLProtocol.responseDelay = 0.4
        MockURLProtocol.respond(["/v1/apps": .json(Fixture.apps(["a1"]))])
        let client = makeClient()

        let call = Task { try await client.get("/v1/apps", as: ASCList<AppAttributes>.self) }
        try await Task.sleep(for: .milliseconds(80))
        call.cancel()

        do {
            _ = try await call.value
            XCTFail("a cancelled call must not come back with data")
        } catch {
            XCTAssertTrue(error is CancellationError, "got: \(error)")
        }
        XCTAssertEqual(MockURLProtocol.requests.count, 1,
                       "a cancelled request is not a transient failure to retry")
    }

    /// The backoff between retries is exactly when a cancellation tends to land, and `try?`
    /// around the sleep swallowed it — the loop simply carried on to the next attempt.
    func testCancellationDuringBackoffStopsTheRetryLoop() async throws {
        MockURLProtocol.respond(["/v1/apps": .init(status: 503)])
        // Real backoff, so there is a wait to be cancelled during.
        let client = ASCClient(credentials: credentials, session: session, retryDelayScale: 1.0)

        let call = Task { try await client.get("/v1/apps", as: ASCList<AppAttributes>.self) }
        try await Task.sleep(for: .milliseconds(150))
        call.cancel()

        do {
            _ = try await call.value
            XCTFail("expected the cancellation to end the loop")
        } catch {
            XCTAssertTrue(error is CancellationError, "got: \(error)")
        }
        XCTAssertEqual(MockURLProtocol.requests.count, 1,
                       "the second attempt was never made: \(MockURLProtocol.requests.count)")
    }

    /// A request that is never cancelled still gets its retries.
    func testAnUncancelledCallStillRetries() async throws {
        MockURLProtocol.respond(["/v1/apps": .init(status: 503)])
        _ = try? await makeClient().get("/v1/apps", as: ASCList<AppAttributes>.self)
        XCTAssertEqual(MockURLProtocol.requests.count, 4, "the ceiling is still four attempts")
    }

    // MARK: - Error shapes

    func testDecodesAnApiErrorDetail() async throws {
        let body = #"{"errors":[{"title":"Forbidden","detail":"Not allowed here"}]}"#
        MockURLProtocol.respond(["/v1/apps": .json(body, status: 403)])
        do {
            let _: ASCList<AppAttributes> = try await makeClient().get("/v1/apps")
            XCTFail("403 should throw")
        } catch let error as ASCError {
            guard case .http(let status, _, let detail, _) = error else {
                return XCTFail("expected an http error, got \(error)")
            }
            XCTAssertEqual(status, 403)
            XCTAssertEqual(detail, "Not allowed here")
        }
    }

    func testDoesNotRetryA401() async throws {
        MockURLProtocol.respond(["/v1/apps": .json(#"{"errors":[]}"#, status: 401)])
        _ = try? await makeClient().get("/v1/apps", as: ASCList<AppAttributes>.self)
        XCTAssertEqual(MockURLProtocol.requests.count, 1,
                       "a rejected credential is a real answer, not a transient one")
    }

    func testRejectsAnUnparseableDate() async throws {
        let body = #"""
        {"data":[{"type":"builds","id":"b","attributes":
         {"version":"1","processingState":"VALID","uploadedDate":"not-a-date"}}]}
        """#
        MockURLProtocol.respond(["/v1/builds": .json(body)])
        do {
            let _: ASCList<BuildAttributes> = try await makeClient().get("/v1/builds")
            XCTFail("an unparseable date should surface, not be silently dropped")
        } catch {
            // expected
        }
    }

    func testAcceptsBothISO8601Forms() async throws {
        let body = #"""
        {"data":[
          {"type":"builds","id":"b1","attributes":
           {"version":"1","processingState":"VALID","uploadedDate":"2026-08-20T07:00:25.123-07:00"}},
          {"type":"builds","id":"b2","attributes":
           {"version":"2","processingState":"VALID","uploadedDate":"2026-08-20T07:00:25-07:00"}}
        ]}
        """#
        MockURLProtocol.respond(["/v1/builds": .json(body)])
        let list: ASCList<BuildAttributes> = try await makeClient().get("/v1/builds")
        XCTAssertNotNil(list.data[0].attributes.uploadedDate, "fractional seconds")
        XCTAssertNotNil(list.data[1].attributes.uploadedDate, "no fractional seconds")
    }

    // MARK: - Retry

    func testRetriesA429AndSucceeds() async throws {
        let attempts = Counter()
        MockURLProtocol.handler = { _ in
            attempts.increment() == 1
                ? .json(#"{"errors":[]}"#, status: 429, headers: ["Retry-After": "0"])
                : .json(Fixture.apps(["a1"]))
        }
        let list: ASCList<AppAttributes> = try await makeClient().get("/v1/apps")
        XCTAssertEqual(list.data.map(\.id), ["a1"])
        XCTAssertEqual(attempts.value, 2)
    }

    func testRetriesA503AndSucceeds() async throws {
        let attempts = Counter()
        MockURLProtocol.handler = { _ in
            attempts.increment() < 3 ? .init(status: 503) : .json(Fixture.apps(["a1"]))
        }
        let list: ASCList<AppAttributes> = try await makeClient().get("/v1/apps")
        XCTAssertEqual(list.data.count, 1)
        XCTAssertEqual(attempts.value, 3)
    }

    func testGivesUpAfterTheAttemptCeiling() async throws {
        MockURLProtocol.respond(["/v1/apps": .init(status: 500)])
        _ = try? await makeClient().get("/v1/apps", as: ASCList<AppAttributes>.self)
        XCTAssertEqual(MockURLProtocol.requests.count, 4,
                       "retrying forever would hang the refresh instead of reporting a failure")
    }

    // MARK: - Pagination

    func testFollowsLinksNextAcrossPages() async throws {
        let page1 = #"""
        {"data":[{"type":"apps","id":"a1","attributes":{"name":"A","bundleId":"app.a"}}],
         "links":{"next":"https://api.appstoreconnect.apple.com/v1/apps?cursor=2"}}
        """#
        MockURLProtocol.handler = { request in
            (request.url?.query?.contains("cursor=2") ?? false)
                ? .json(Fixture.apps(["a2"]))
                : .json(page1)
        }
        let result: PagedResult<ASCResource<AppAttributes>> =
            try await makeClient().getAllPagesResult("/v1/apps", as: AppAttributes.self)
        XCTAssertEqual(result.values.map(\.id), ["a1", "a2"])
        XCTAssertTrue(result.isComplete)
    }

    /// A page ceiling has to be reported, or a truncated list masquerades as the whole list.
    func testReportsTruncationWhenThePageCeilingIsHit() async throws {
        let endless = #"""
        {"data":[{"type":"apps","id":"a","attributes":{"name":"A","bundleId":"app.a"}}],
         "links":{"next":"https://api.appstoreconnect.apple.com/v1/apps?cursor=next"}}
        """#
        MockURLProtocol.respond(["/v1/apps": .json(endless)])
        let result: PagedResult<ASCResource<AppAttributes>> =
            try await makeClient().getAllPagesResult("/v1/apps", as: AppAttributes.self,
                                                     maxPages: 3)
        XCTAssertEqual(result.values.count, 3)
        XCTAssertFalse(result.isComplete, "the caller has to know the list was cut short")
    }

    func testPaginatesRelationshipIDs() async throws {
        MockURLProtocol.respond(["/relationships/builds": .json(Fixture.relationship(["b1", "b2"]))])
        let page = try await makeClient()
            .getAllRelationshipIDs("/v1/betaGroups/g/relationships/builds")
        XCTAssertEqual(page.values, ["b1", "b2"])
        XCTAssertTrue(page.isComplete)
    }

    // MARK: - Host safety

    /// Every request carries a bearer token, so a `next` pointing elsewhere must not be followed.
    func testRefusesAForeignHostInLinksNext() async throws {
        let page1 = #"""
        {"data":[{"type":"apps","id":"a1","attributes":{"name":"A","bundleId":"app.a"}}],
         "links":{"next":"https://evil.example.com/v1/apps?cursor=2"}}
        """#
        MockURLProtocol.respond(["/v1/apps": .json(page1)])
        do {
            _ = try await makeClient().getAllPagesResult("/v1/apps", as: AppAttributes.self)
            XCTFail("a foreign next link must not be followed with a credential attached")
        } catch let error as ASCError {
            guard case .transport(let message) = error else {
                return XCTFail("expected a transport refusal, got \(error)")
            }
            XCTAssertTrue(message.contains("evil.example.com"))
        }
    }

    func testAcceptsAnAbsoluteAppleURL() async throws {
        MockURLProtocol.respond(["/v1/apps": .json(Fixture.apps(["a1"]))])
        let list: ASCList<AppAttributes> = try await makeClient()
            .get("https://api.appstoreconnect.apple.com/v1/apps?limit=1")
        XCTAssertEqual(list.data.count, 1)
    }

    func testRefusesPlainHTTP() async throws {
        MockURLProtocol.respond(["/v1/apps": .json(Fixture.apps(["a1"]))])
        do {
            _ = try await makeClient()
                .get("http://api.appstoreconnect.apple.com/v1/apps", as: ASCList<AppAttributes>.self)
            XCTFail("a bearer token must not travel over plain HTTP")
        } catch {
            // expected
        }
    }
}

/// Thread-safe counter for scripting multi-attempt responses.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int { lock.withLock { count += 1; return count } }
    var value: Int { lock.withLock { count } }
}
