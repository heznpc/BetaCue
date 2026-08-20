import Foundation

/// Apple 응답을 정규화 스키마로 바꾸는 계층. (명세 §18)
///
/// 앱 다섯 개를 순차 조회하면 20초가 걸린다. 전부 동시에 던진다.
enum Collector {
    static func loadApp(_ app: ASCResource<AppAttributes>, using client: ASCClient) async throws
        -> AppSnapshot
    {
        async let groupsRaw: ASCList<BetaGroupAttributes> =
            client.get("/v1/apps/\(app.id)/betaGroups?limit=20")
        async let buildsRaw: ASCList<BuildAttributes> =
            client.get("/v1/builds?filter[app]=\(app.id)&limit=10&sort=-uploadedDate")

        let (groupList, buildList) = try await (groupsRaw, buildsRaw)

        async let groups = loadGroups(groupList, using: client)
        async let builds = loadBuilds(buildList, using: client)
        let (resolvedGroups, resolvedBuilds) = try await (groups, builds)

        return AppSnapshot(
            id: app.id,
            name: app.attributes.name,
            bundleID: app.attributes.bundleId,
            groups: resolvedGroups,
            builds: resolvedBuilds,
            stateID: RuleEngine.resolve(groups: resolvedGroups, builds: resolvedBuilds).id,
            fetchedAt: Date())
    }

    private static func loadGroups(
        _ list: ASCList<BetaGroupAttributes>, using client: ASCClient
    ) async throws -> [GroupSnapshot] {
        var groups: [GroupSnapshot] = []
        try await withThrowingTaskGroup(of: GroupSnapshot.self) { tg in
            for g in list.data {
                tg.addTask {
                    let testers: ASCList<BetaTesterAttributes> =
                        try await client.get("/v1/betaGroups/\(g.id)/betaTesters?limit=200")
                    return GroupSnapshot(
                        id: g.id,
                        name: g.attributes.name,
                        isInternal: g.attributes.isInternalGroup,
                        testerCount: testers.data.count,
                        autoDistributes: g.attributes.hasAccessToAllBuilds ?? false,
                        publicLink: g.attributes.publicLink)
                }
            }
            for try await snapshot in tg { groups.append(snapshot) }
        }
        // 내부 그룹 먼저, 그다음 이름순.
        return groups.sorted {
            $0.isInternal == $1.isInternal
                ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                : $0.isInternal
        }
    }

    private static func loadBuilds(
        _ list: ASCList<BuildAttributes>, using client: ASCClient
    ) async throws -> [BuildSnapshot] {
        var indexed: [(Int, BuildSnapshot)] = []
        try await withThrowingTaskGroup(of: (Int, BuildSnapshot).self) { tg in
            for (index, b) in list.data.enumerated() {
                tg.addTask {
                    // 마케팅 버전은 빌드가 아니라 preReleaseVersion에 있다.
                    async let detailRaw: ASCSingle<BuildBetaDetailAttributes> =
                        client.get("/v1/builds/\(b.id)/buildBetaDetail")
                    async let versionRaw: ASCSingle<PreReleaseVersionAttributes> =
                        client.get("/v1/builds/\(b.id)/preReleaseVersion")
                    let (detail, preRelease) = try await (detailRaw, versionRaw)

                    return (index, BuildSnapshot(
                        id: b.id,
                        number: b.attributes.version ?? "?",
                        marketingVersion: preRelease.data?.attributes.version,
                        processingState: b.attributes.processingState ?? "UNKNOWN",
                        internalState: detail.data?.attributes.internalBuildState,
                        externalState: detail.data?.attributes.externalBuildState,
                        uploadedAt: b.attributes.uploadedDate,
                        expiresAt: b.attributes.expirationDate,
                        isExpired: b.attributes.expired ?? false))
                }
            }
            for try await pair in tg { indexed.append(pair) }
        }
        // 업로드 최신순(서버 정렬)을 그대로 유지한다.
        return indexed.sorted { $0.0 < $1.0 }.map(\.1)
    }

    static func loadCertificates(using client: ASCClient) async throws -> [CertificateSnapshot] {
        let list: ASCList<CertificateAttributes> = try await client.get("/v1/certificates?limit=50")
        return list.data
            .map {
                CertificateSnapshot(
                    id: $0.id,
                    name: $0.attributes.name ?? "이름 없음",
                    type: $0.attributes.certificateType ?? "",
                    expiresAt: $0.attributes.expirationDate)
            }
            .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }
}
