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

    /// Whether individual testers can install depends on this field, so it has to survive
    /// the trip from JSON to snapshot rather than being quietly dropped.
    func testCarriesTheBuildAudienceType() async throws {
        var table = healthyTable()
        table["/v1/builds?"] = .json(Fixture.builds(["1"], audienceType: "INTERNAL_ONLY"))
        MockURLProtocol.respond(table)

        let snapshot = try await Collector.loadApp(app, using: client)
        XCTAssertEqual(snapshot.builds.first?.audienceType, "INTERNAL_ONLY")
    }

    func testAbsentBuildAudienceTypeStaysNil() async throws {
        MockURLProtocol.respond(healthyTable())
        let snapshot = try await Collector.loadApp(app, using: client)
        XCTAssertNil(snapshot.builds.first?.audienceType,
                     "an unread audience type must not read as a value")
    }

    /// The count going unknown is only half of it. Without the failure in `partialErrors`
    /// the snapshot claims to be complete, and Store then records a transition into UNKNOWN
    /// and announces a transient blip as something that needs attention.
    func testFailedIndividualTesterFetchLeavesTheCountUnknown() async throws {
        var table = healthyTable()
        table["relationships/individualTesters"] = .init(status: 500)
        MockURLProtocol.respond(table)

        let snapshot = try await Collector.loadApp(app, using: client)
        XCTAssertNil(snapshot.builds.first?.individualTesterCount)
        XCTAssertTrue(snapshot.isPartial, "an unread channel must not read as a complete snapshot")
        // Asserting on the wording would only assert which language the test process runs in.
        XCTAssertEqual(snapshot.partialErrors.count, 1,
                       "exactly one fetch failed: \(snapshot.partialErrors)")
    }

    /// A page ceiling hit is the same ignorance as a 500, and has to be reported the same way.
    func testTruncatedIndividualTesterListIsReportedAsPartial() async throws {
        var table = healthyTable()
        table["relationships/individualTesters"] = .json(#"""
        {"data":[{"type":"x","id":"t"}],
         "links":{"next":"https://api.appstoreconnect.apple.com/v1/y?cursor=1"}}
        """#)
        MockURLProtocol.respond(table)

        let snapshot = try await Collector.loadApp(app, using: client)
        XCTAssertNil(snapshot.builds.first?.individualTesterCount)
        XCTAssertTrue(snapshot.isPartial)
    }

    /// A readable group answers the audience question on its own. Losing the individual
    /// count must not drag an app that is plainly distributed into UNKNOWN.
    func testAReadableGroupStillSettlesTheAudience() async throws {
        var table = healthyTable()
        table["relationships/individualTesters"] = .init(status: 500)
        MockURLProtocol.respond(table)

        let snapshot = try await Collector.loadApp(app, using: client)
        XCTAssertEqual(snapshot.status.state.id, .internalTestingReady,
                       "one unread channel is not a reason to forget the other one answered")
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

    // MARK: - Looking past the history page for something installable

    /// Answers the build endpoint from a script of pages, keyed by cursor.
    private func respondWithBuildPages(_ pages: [String], table: [String: MockURLProtocol.Response]) {
        MockURLProtocol.handler = { request in
            let url = request.url?.absoluteString ?? ""
            let path = request.url.map { $0.path + ($0.query.map { "?\($0)" } ?? "") } ?? ""
            if path.hasPrefix("/v1/builds?") {
                let index = url.range(of: "cursor=").map {
                    Int(url[$0.upperBound...]) ?? 0
                } ?? 0
                return .json(pages[min(index, pages.count - 1)])
            }
            for (key, response) in table.sorted(by: { $0.key.count > $1.key.count })
            where path.contains(key) { return response }
            return .init(status: 404)
        }
    }

    /// P1-9. The page size is a display choice; installability is not. A serving build sitting
    /// past the first page used to be reported as "nobody can install anything", and the
    /// newest builds are exactly the ones most likely to be stuck.
    func testFindsAnInstallableBuildPastTheFirstPage() async throws {
        var table = healthyTable()
        table["relationships/builds"] = .json(Fixture.relationship(["old"]))
        respondWithBuildPages([
            Fixture.builds(["30", "29"], state: "PROCESSING",
                           nextPage: Fixture.nextBuildPage("1")),
            Fixture.builds(["old"]),
        ], table: table)

        let snapshot = try await Collector.loadApp(app, using: client)
        XCTAssertEqual(snapshot.builds.map(\.number), ["30", "29", "old"],
                       "the newer page still comes first")
        XCTAssertEqual(snapshot.status.testable?.id, "old")
        XCTAssertTrue(snapshot.partialErrors.isEmpty, "got: \(snapshot.partialErrors)")
    }

    /// One page is enough when it already answers the question, and reading more would cost
    /// three extra requests per build for nothing.
    func testStopsAtTheFirstPageWhenSomethingAlreadyInstalls() async throws {
        var table = healthyTable()
        table["relationships/builds"] = .json(Fixture.relationship(["1"]))
        respondWithBuildPages([
            Fixture.builds(["1"], nextPage: Fixture.nextBuildPage("1")),
            Fixture.builds(["old"]),
        ], table: table)

        _ = try await Collector.loadApp(app, using: client)
        let buildListCalls = MockURLProtocol.requests.filter {
            ($0.url?.path.hasSuffix("/v1/builds") ?? false)
        }
        XCTAssertEqual(buildListCalls.count, 1, "nothing older can change the answer")
    }

    /// Apple expires a build 90 days after upload and returns them newest first, so an expired
    /// build ends the search on a read fact rather than on a cap.
    func testStopsSearchingOnceTheBuildsAreExpired() async throws {
        var table = healthyTable()
        table["relationships/builds"] = .json(Fixture.emptyRelationship)
        respondWithBuildPages([
            Fixture.builds(["9"], expired: true, nextPage: Fixture.nextBuildPage("1")),
            Fixture.builds(["8"], expired: true),
        ], table: table)

        let snapshot = try await Collector.loadApp(app, using: client)
        XCTAssertNil(snapshot.status.testable)
        XCTAssertTrue(snapshot.partialErrors.isEmpty,
                      "nothing behind an expired build can install; that is an answer")
        XCTAssertEqual(MockURLProtocol.requests.filter {
            $0.url?.path.hasSuffix("/v1/builds") ?? false
        }.count, 1)
    }

    /// Giving up at the ceiling is ignorance, and must not read as "nothing installs".
    func testGivingUpTheSearchIsReportedRatherThanAnswered() async throws {
        var mutable = healthyTable()
        mutable["relationships/builds"] = .json(Fixture.emptyRelationship)
        let table = mutable
        MockURLProtocol.handler = { request in
            let path = request.url.map { $0.path + ($0.query.map { "?\($0)" } ?? "") } ?? ""
            if path.hasPrefix("/v1/builds?") {
                // Always one more page, never anything installable.
                return .json(Fixture.builds(["x"], state: "PROCESSING",
                                            nextPage: Fixture.nextBuildPage("9")))
            }
            for (key, response) in table.sorted(by: { $0.key.count > $1.key.count })
            where path.contains(key) { return response }
            return .init(status: 404)
        }

        let snapshot = try await Collector.loadApp(app, using: client)
        XCTAssertNil(snapshot.status.testable)
        XCTAssertTrue(snapshot.isPartial,
                      "an unfinished search is not proof that nothing installs")
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
