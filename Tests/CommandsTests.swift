import XCTest
@testable import BetaCue

/// The only requests that change server state.
///
/// A read that goes wrong shows a wrong number; a write that goes wrong puts a build in front
/// of people who were never meant to see it. The request shape is pinned exactly.
final class CommandsTests: XCTestCase {
    private var directory: URL!
    private var client: ASCClient!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("betacue-commands-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (credentials, _) = try Fixture.credentials(in: directory)
        MockURLProtocol.reset()
        client = ASCClient(credentials: credentials,
                           session: MockURLProtocol.makeSession(),
                           retryDelayScale: 0)
    }

    override func tearDownWithError() throws {
        MockURLProtocol.reset()
        try? FileManager.default.removeItem(at: directory)
    }

    private func sentBody() throws -> [String: Any]? {
        guard let request = MockURLProtocol.requests.first else { return nil }
        // URLProtocol hands the body back as a stream, so read it rather than httpBody.
        guard let stream = request.httpBodyStream else {
            return request.httpBody.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func testSendsTheExactRelationshipPayload() async throws {
        MockURLProtocol.respond(["relationships/betaGroups": .init(status: 204)])
        try await Commands.assign(build: "b1", toGroups: ["g1", "g2"], using: client)

        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/builds/b1/relationships/betaGroups")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(sentBody())
        let data = try XCTUnwrap(body["data"] as? [[String: String]])
        XCTAssertEqual(data.count, 2)
        XCTAssertEqual(Set(data.compactMap { $0["id"] }), ["g1", "g2"])
        XCTAssertEqual(Set(data.compactMap { $0["type"] }), ["betaGroups"])
    }

    /// Only the chosen groups may appear. A stray ID here is an unintended distribution.
    func testSendsOnlyTheChosenGroups() async throws {
        MockURLProtocol.respond(["relationships/betaGroups": .init(status: 204)])
        try await Commands.assign(build: "b1", toGroups: ["chosen"], using: client)

        let body = try XCTUnwrap(sentBody())
        let data = try XCTUnwrap(body["data"] as? [[String: String]])
        XCTAssertEqual(data.compactMap { $0["id"] }, ["chosen"])
    }

    func testTreats204AsSuccess() async throws {
        MockURLProtocol.respond(["relationships/betaGroups": .init(status: 204)])
        try await Commands.assign(build: "b1", toGroups: ["g1"], using: client)
        // Reaching here without throwing is the assertion.
    }

    func testSurfacesAConflictToTheCaller() async throws {
        let body = #"{"errors":[{"title":"Conflict","detail":"Build already assigned"}]}"#
        MockURLProtocol.respond(["relationships/betaGroups": .json(body, status: 409)])

        do {
            try await Commands.assign(build: "b1", toGroups: ["g1"], using: client)
            XCTFail("a 409 has to reach the user, not be swallowed")
        } catch let error as ASCError {
            guard case .http(let status, _, let detail, _) = error else {
                return XCTFail("expected an http error, got \(error)")
            }
            XCTAssertEqual(status, 409)
            XCTAssertEqual(detail, "Build already assigned")
        }
    }

    func testDoesNotRetryAConflict() async throws {
        MockURLProtocol.respond(["relationships/betaGroups": .json(#"{"errors":[]}"#, status: 409)])
        _ = try? await Commands.assign(build: "b1", toGroups: ["g1"], using: client)
        XCTAssertEqual(MockURLProtocol.requests.count, 1,
                       "repeating a write that was refused could distribute twice")
    }

    /// No groups means no request at all — never an empty write.
    func testEmptySelectionSendsNothing() async throws {
        MockURLProtocol.respond(["relationships/betaGroups": .init(status: 204)])
        try await Commands.assign(build: "b1", toGroups: [], using: client)
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }
}
