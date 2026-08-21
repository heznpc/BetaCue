import XCTest
@testable import BetaCue

/// The path from JSON to `AppSnapshot`.
///
/// `ReliabilityTests` proves the rule engine treats `nil` as unknown. These prove the
/// collector actually produces `nil` when a fetch fails, instead of a zero that looks
/// like a real answer.
final class CollectorTests: XCTestCase {
    private var directory: URL!
    private var client: ASCClient!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("betacue-collector-\(UUID().uuidString)")
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

    private let app = ASCResource<AppAttributes>(
        id: "app1", attributes: AppAttributes(name: "Sample", bundleId: "app.sample", sku: nil))

    /// Everything answers; nothing is unknown.
    private func healthyTable() -> [String: MockURLProtocol.Response] {
        [
            "/betaGroups": .json(Fixture.groups(["g1"])),
            "/v1/builds?": .json(Fixture.builds(["1"])),
            "/buildBetaDetail": .json(Fixture.betaDetail()),
            "/preReleaseVersion": .json(Fixture.nullSingle),
            "relationships/individualTesters": .json(Fixture.emptyRelationship),
            "relationships/betaTesters": .json(Fixture.relationship(["t1", "t2"])),
            "relationships/builds": .json(Fixture.relationship(["1"])),
        ]
    }

    func testHappyPathProducesKnownValues() async throws {
        MockURLProtocol.respond(healthyTable())
        let snapshot = try await Collector.loadApp(app, using: client)

        XCTAssertEqual(snapshot.bundleID, "app.sample")
        XCTAssertEqual(snapshot.groups.first?.testerCount, 2)
        XCTAssertEqual(snapshot.builds.first?.betaStateIsKnown, true)
        XCTAssertEqual(snapshot.builds.first?.assignedGroupIDs, ["g1"])
        XCTAssertEqual(snapshot.builds.first?.individualTesterCount, 0)
        XCTAssertTrue(snapshot.partialErrors.isEmpty)
    }

    /// The iOS filter has to reach the wire, or a macOS build can win "latest".
    func testRequestsOnlyIOSBuilds() async throws {
        MockURLProtocol.respond(healthyTable())
        _ = try await Collector.loadApp(app, using: client)

        let buildRequest = MockURLProtocol.requests
            .compactMap(\.url?.absoluteString)
            .first { $0.contains("filter") && $0.contains("/v1/builds") }
        XCTAssertNotNil(buildRequest, "sent: \(MockURLProtocol.requests.compactMap(\.url?.absoluteString))")
        XCTAssertTrue(buildRequest?.contains("platform") == true
                      && buildRequest?.contains("IOS") == true,
                      "got: \(buildRequest ?? "none")")
    }

    // MARK: - Failures stay unknown

    func testFailedBetaDetailLeavesTheStateUnknown() async throws {
        var table = healthyTable()
        table["/buildBetaDetail"] = .init(status: 500)
        MockURLProtocol.respond(table)

        let snapshot = try await Collector.loadApp(app, using: client)
        XCTAssertEqual(snapshot.builds.first?.betaStateIsKnown, false)
        XCTAssertNil(snapshot.builds.first?.internalState)
        XCTAssertFalse(snapshot.partialErrors.isEmpty, "the failure has to be reported")
        XCTAssertEqual(snapshot.status.state.id, .unknown)
    }

    func testFailedTesterFetchLeavesTheCountUnknown() async throws {
        var table = healthyTable()
        table["relationships/betaTesters"] = .init(status: 500)
        MockURLProtocol.respond(table)

        let snapshot = try await Collector.loadApp(app, using: client)
        XCTAssertNil(snapshot.groups.first?.testerCount,
                     "an unreadable tester list must not become zero testers")
        XCTAssertEqual(snapshot.groups.first?.reachability, .unknown)
    }

    func testFailedAssignmentFetchLeavesAttachmentsUnknown() async throws {
        var table = healthyTable()
        table["relationships/builds"] = .init(status: 503)
        MockURLProtocol.respond(table)

        let snapshot = try await Collector.loadApp(app, using: client)
        XCTAssertNil(snapshot.builds.first?.assignedGroupIDs,
                     "one unreadable group must not make every build look unattached")
        XCTAssertEqual(snapshot.status.state.id, .unknown)
    }

    func testFailedIndividualTesterFetchLeavesTheCountUnknown() async throws {
        var table = healthyTable()
        table["relationships/individualTesters"] = .init(status: 500)
        MockURLProtocol.respond(table)

        let snapshot = try await Collector.loadApp(app, using: client)
        XCTAssertNil(snapshot.builds.first?.individualTesterCount)
    }

    /// A truncated page is the same kind of ignorance as a failed one.
    func testTruncatedTesterListIsUnknownRatherThanShort() async throws {
        var table = healthyTable()
        let endless = #"""
        {"data":[{"type":"x","id":"t"}],
         "links":{"next":"https://api.appstoreconnect.apple.com/v1/x?cursor=1"}}
        """#
        table["relationships/betaTesters"] = .json(endless)
        MockURLProtocol.respond(table)

        let snapshot = try await Collector.loadApp(app, using: client)
        XCTAssertNil(snapshot.groups.first?.testerCount,
                     "a list cut short by the page ceiling is not a count")
    }

    // MARK: - Ordering and isolation

    func testKeepsTheServersNewestFirstOrdering() async throws {
        var table = healthyTable()
        table["/v1/builds?"] = .json(Fixture.builds(["30", "29", "28", "27"]))
        table["relationships/builds"] = .json(Fixture.relationship(["30"]))
        MockURLProtocol.respond(table)

        let snapshot = try await Collector.loadApp(app, using: client)
        XCTAssertEqual(snapshot.builds.map(\.number), ["30", "29", "28", "27"],
                       "concurrent detail fetches must not reshuffle the builds")
    }

    /// One build's detail failing must not blank the others.
    func testOneBuildFailingLeavesTheOthersIntact() async throws {
        var mutable = healthyTable()
        mutable["/v1/builds?"] = .json(Fixture.builds(["2", "1"]))
        let table = mutable
        MockURLProtocol.handler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("/builds/2/buildBetaDetail") { return .init(status: 500) }
            let path = request.url.map { $0.path + ($0.query.map { "?\($0)" } ?? "") } ?? ""
            for (key, response) in table.sorted(by: { $0.key.count > $1.key.count })
            where path.contains(key) { return response }
            return .init(status: 404)
        }

        let snapshot = try await Collector.loadApp(app, using: client)
        XCTAssertEqual(snapshot.builds.count, 2)
        XCTAssertEqual(snapshot.builds.first(where: { $0.number == "2" })?.betaStateIsKnown, false)
        XCTAssertEqual(snapshot.builds.first(where: { $0.number == "1" })?.betaStateIsKnown, true)
    }

    func testNoGroupsIsNotAFailure() async throws {
        var table = healthyTable()
        table["/betaGroups"] = .json(#"{"data":[]}"#)
        MockURLProtocol.respond(table)

        let snapshot = try await Collector.loadApp(app, using: client)
        XCTAssertTrue(snapshot.groups.isEmpty)
        XCTAssertTrue(snapshot.partialErrors.isEmpty, "an empty list is an answer, not an error")
        XCTAssertEqual(snapshot.builds.first?.assignedGroupIDs, [],
                       "no groups means no attachments, which is known — not unknown")
    }
}
