import Foundation

/// Turns Apple's responses into the normalized schema. (spec §18)
///
/// Five apps fetched serially take 20 seconds, so everything goes out concurrently.
/// Secondary fetches never throw — one app returning 404 must not stop the others from refreshing.
enum Collector {
    /// Builds fetched per app.
    ///
    /// This feeds two different jobs: the history list, and the search for the build that is
    /// installable right now. If the newest ten are all processing or rejected while an
    /// eleventh is still serving, a limit of ten would hide it.
    private static let buildFetchLimit = 25
    private static let groupLimit = 50
    private static let testerLimit = 200

    static func loadApp(_ app: ASCResource<AppAttributes>, using client: ASCClient) async throws
        -> AppSnapshot
    {
        // This is an iOS dashboard, so pin the platform. Without it a macOS build of the same
        // app can win "latest build" and the reported state becomes wrong.
        async let groupsRaw: [ASCResource<BetaGroupAttributes>] =
            client.getAllPages("/v1/apps/\(app.id)/betaGroups?limit=\(groupLimit)")
        async let buildsRaw: ASCList<BuildAttributes> =
            client.get("/v1/builds?filter[app]=\(app.id)"
                       + "&filter[preReleaseVersion.platform]=IOS"
                       + "&limit=\(buildFetchLimit)&sort=-uploadedDate")

        let (groupList, buildList) = try await (groupsRaw, buildsRaw)

        var problems: [String] = []
        async let groupsTask = loadGroups(groupList, using: client)
        async let buildsTask = loadBuilds(buildList, using: client)
        var (groups, builds) = await (groupsTask, buildsTask)

        problems += groups.problems + builds.problems

        // Which build belongs to which group is only readable from the group side.
        // (The build → betaGroups relationship does not allow GET_RELATED.)
        let assignment = await loadAssignments(groups.value, using: client)
        problems += assignment.problems
        // A group whose attachments could not be read makes every build's attachment list
        // incomplete. Leaving it nil keeps "unread" from masquerading as "attached to nothing".
        let assignmentsComplete = assignment.value.count == groups.value.count
        for index in builds.value.indices {
            builds.value[index].assignedGroupIDs = assignmentsComplete
                ? assignment.value.filter { $0.value.contains(builds.value[index].id) }.map(\.key)
                : nil
        }

        return AppSnapshot(
            id: app.id,
            name: app.attributes.name,
            bundleID: app.attributes.bundleId,
            groups: groups.value,
            builds: builds.value,
            fetchedAt: Date(),
            partialErrors: problems)
    }

    /// Carries a value together with whatever went wrong while producing it.
    private struct Partial<T: Sendable>: Sendable {
        var value: T
        var problems: [String] = []
    }

    private static func loadGroups(
        _ list: [ASCResource<BetaGroupAttributes>], using client: ASCClient
    ) async -> Partial<[GroupSnapshot]> {
        var groups: [GroupSnapshot] = []
        var problems: [String] = []

        await withTaskGroup(of: (GroupSnapshot, String?).self) { tg in
            for g in list {
                tg.addTask {
                    // Only the count is needed, so read relationship IDs rather than whole
                    // tester objects with names and email addresses.
                    let testers = try? await client.getAllRelationshipIDs(
                        "/v1/betaGroups/\(g.id)/relationships/betaTesters?limit=\(testerLimit)")
                    let snapshot = GroupSnapshot(
                        id: g.id,
                        name: g.attributes.name,
                        isInternal: g.attributes.isInternalGroup,
                        testerCount: (testers?.isComplete ?? false) ? testers?.values.count : nil,
                        autoDistributes: g.attributes.hasAccessToAllBuilds ?? false,
                        publicLinkEnabled: g.attributes.publicLinkEnabled ?? false,
                        publicLink: g.attributes.publicLink)
                    let problem = (testers?.isComplete ?? false)
                        ? nil
                        : String(localized: "Couldn't read testers for the '\(g.attributes.name)' group.")
                    return (snapshot, problem)
                }
            }
            for await (snapshot, problem) in tg {
                groups.append(snapshot)
                if let problem { problems.append(problem) }
            }
        }

        // Internal groups first, then by name.
        groups.sort {
            $0.isInternal == $1.isInternal
                ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                : $0.isInternal
        }
        return Partial(value: groups, problems: problems)
    }

    private static func loadBuilds(
        _ list: ASCList<BuildAttributes>, using client: ASCClient
    ) async -> Partial<[BuildSnapshot]> {
        var indexed: [(Int, BuildSnapshot, String?)] = []

        await withTaskGroup(of: (Int, BuildSnapshot, String?).self) { tg in
            for (index, b) in list.data.enumerated() {
                tg.addTask {
                    // The marketing version lives on preReleaseVersion, not on the build.
                    async let detail: ASCSingle<BuildBetaDetailAttributes>? =
                        client.getOrNil("/v1/builds/\(b.id)/buildBetaDetail")
                    async let preRelease: ASCSingle<PreReleaseVersionAttributes>? =
                        client.getOrNil("/v1/builds/\(b.id)/preReleaseVersion")
                    async let individuals: PagedResult<String>? =
                        try? client.getAllRelationshipIDs(
                            "/v1/builds/\(b.id)/relationships/individualTesters?limit=\(testerLimit)")
                    let (d, pre, ind) = await (detail, preRelease, individuals)

                    let snapshot = BuildSnapshot(
                        id: b.id,
                        number: b.attributes.version ?? "?",
                        marketingVersion: pre?.data?.attributes.version,
                        platform: pre?.data?.attributes.platform,
                        processingState: b.attributes.processingState ?? "UNKNOWN",
                        internalState: d?.data?.attributes.internalBuildState,
                        externalState: d?.data?.attributes.externalBuildState,
                        betaStateIsKnown: d != nil,
                        uploadedAt: b.attributes.uploadedDate,
                        expiresAt: b.attributes.expirationDate,
                        isExpired: b.attributes.expired ?? false,
                        assignedGroupIDs: nil,
                        individualTesterCount: (ind?.isComplete ?? false) ? ind?.values.count : nil,
                        audienceType: b.attributes.buildAudienceType)
                    let problem = d == nil
                        ? String(localized: "Couldn't read distribution state for build \(b.attributes.version ?? b.id).") : nil
                    return (index, snapshot, problem)
                }
            }
            for await triple in tg { indexed.append(triple) }
        }

        indexed.sort { $0.0 < $1.0 }   // keep the server's newest-upload-first order
        return Partial(value: indexed.map(\.1), problems: indexed.compactMap(\.2))
    }

    /// Group ID to the set of build IDs attached to that group.
    private static func loadAssignments(
        _ groups: [GroupSnapshot], using client: ASCClient
    ) async -> Partial<[String: Set<String>]> {
        var map: [String: Set<String>] = [:]
        var problems: [String] = []

        await withTaskGroup(of: (String, Set<String>?, String?).self) { tg in
            for group in groups {
                tg.addTask {
                    guard let page = try? await client.getAllRelationshipIDs(
                        "/v1/betaGroups/\(group.id)/relationships/builds?limit=200"),
                          page.isComplete
                    else {
                        return (group.id, nil, String(localized: "Couldn't read distributed builds for the '\(group.name)' group."))
                    }
                    return (group.id, Set(page.values), nil)
                }
            }
            for await (id, ids, problem) in tg {
                if let ids { map[id] = ids }
                if let problem { problems.append(problem) }
            }
        }
        return Partial(value: map, problems: problems)
    }

    static func loadCertificates(using client: ASCClient) async throws -> [CertificateSnapshot] {
        let list: ASCList<CertificateAttributes> = try await client.get("/v1/certificates?limit=50")
        return list.data
            .map {
                CertificateSnapshot(
                    id: $0.id,
                    name: $0.attributes.name ?? String(localized: "Unnamed"),
                    type: $0.attributes.certificateType ?? "",
                    expiresAt: $0.attributes.expirationDate)
            }
            .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }
}
