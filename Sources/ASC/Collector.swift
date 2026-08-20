import Foundation

/// Apple 응답을 정규화 스키마로 바꾸는 계층. (명세 §18)
///
/// 앱 다섯 개를 순차 조회하면 20초가 걸린다. 전부 동시에 던진다.
/// 부수 조회는 실패해도 던지지 않는다 — 앱 하나가 404를 뱉어도 나머지 앱의 갱신은 살아야 한다.
enum Collector {
    /// 한 앱에서 가져오는 빌드 개수. 히스토리 표시용이라 제품 정책으로 제한한다.
    private static let buildHistoryLimit = 10
    private static let groupLimit = 50
    private static let testerLimit = 200

    static func loadApp(_ app: ASCResource<AppAttributes>, using client: ASCClient) async throws
        -> AppSnapshot
    {
        // iOS 대시보드이므로 플랫폼을 고정한다. 안 걸면 같은 앱의 macOS 빌드가
        // "최신 빌드"로 잡혀 엉뚱한 상태를 말하게 된다.
        async let groupsRaw: ASCList<BetaGroupAttributes> =
            client.get("/v1/apps/\(app.id)/betaGroups?limit=\(groupLimit)")
        async let buildsRaw: ASCList<BuildAttributes> =
            client.get("/v1/builds?filter[app]=\(app.id)"
                       + "&filter[preReleaseVersion.platform]=IOS"
                       + "&limit=\(buildHistoryLimit)&sort=-uploadedDate")

        let (groupList, buildList) = try await (groupsRaw, buildsRaw)

        var problems: [String] = []
        async let groupsTask = loadGroups(groupList, using: client)
        async let buildsTask = loadBuilds(buildList, using: client)
        var (groups, builds) = await (groupsTask, buildsTask)

        problems += groups.problems + builds.problems

        // 어떤 빌드가 어떤 그룹에 붙어 있는지는 그룹 쪽에서만 읽을 수 있다.
        // (build → betaGroups 관계는 GET_RELATED를 허용하지 않는다.)
        let assignment = await loadAssignments(groups.value, using: client)
        problems += assignment.problems
        for index in builds.value.indices {
            builds.value[index].assignedGroupIDs =
                assignment.value.filter { $0.value.contains(builds.value[index].id) }.map(\.key)
        }

        if groupList.isTruncated {
            problems.append("그룹이 \(groupList.total)개인데 \(groupList.data.count)개만 읽었습니다.")
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

    /// 값과 그 값을 만드는 동안 생긴 문제를 함께 나른다.
    private struct Partial<T: Sendable>: Sendable {
        var value: T
        var problems: [String] = []
    }

    private static func loadGroups(
        _ list: ASCList<BetaGroupAttributes>, using client: ASCClient
    ) async -> Partial<[GroupSnapshot]> {
        var groups: [GroupSnapshot] = []
        var problems: [String] = []

        await withTaskGroup(of: (GroupSnapshot, String?).self) { tg in
            for g in list.data {
                tg.addTask {
                    let testers: ASCList<BetaTesterAttributes>? =
                        await client.getOrNil("/v1/betaGroups/\(g.id)/betaTesters?limit=\(testerLimit)")
                    let snapshot = GroupSnapshot(
                        id: g.id,
                        name: g.attributes.name,
                        isInternal: g.attributes.isInternalGroup,
                        testerCount: testers?.total ?? 0,
                        autoDistributes: g.attributes.hasAccessToAllBuilds ?? false,
                        publicLinkEnabled: g.attributes.publicLinkEnabled ?? false,
                        publicLink: g.attributes.publicLink,
                        testerCountIsExact: testers != nil)
                    let problem = testers == nil
                        ? "'\(g.attributes.name)' 그룹의 테스터를 읽지 못했습니다." : nil
                    return (snapshot, problem)
                }
            }
            for await (snapshot, problem) in tg {
                groups.append(snapshot)
                if let problem { problems.append(problem) }
            }
        }

        // 내부 그룹 먼저, 그다음 이름순.
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
                    // 마케팅 버전은 빌드가 아니라 preReleaseVersion에 있다.
                    async let detail: ASCSingle<BuildBetaDetailAttributes>? =
                        client.getOrNil("/v1/builds/\(b.id)/buildBetaDetail")
                    async let preRelease: ASCSingle<PreReleaseVersionAttributes>? =
                        client.getOrNil("/v1/builds/\(b.id)/preReleaseVersion")
                    async let individuals: ASCRelationshipList? =
                        client.getOrNil("/v1/builds/\(b.id)/relationships/individualTesters?limit=\(testerLimit)")
                    let (d, pre, ind) = await (detail, preRelease, individuals)

                    let snapshot = BuildSnapshot(
                        id: b.id,
                        number: b.attributes.version ?? "?",
                        marketingVersion: pre?.data?.attributes.version,
                        platform: pre?.data?.attributes.platform,
                        processingState: b.attributes.processingState ?? "UNKNOWN",
                        internalState: d?.data?.attributes.internalBuildState,
                        externalState: d?.data?.attributes.externalBuildState,
                        uploadedAt: b.attributes.uploadedDate,
                        expiresAt: b.attributes.expirationDate,
                        isExpired: b.attributes.expired ?? false,
                        individualTesterCount: ind?.total ?? 0)
                    let problem = d == nil
                        ? "빌드 \(b.attributes.version ?? b.id)의 배포 상태를 읽지 못했습니다." : nil
                    return (index, snapshot, problem)
                }
            }
            for await triple in tg { indexed.append(triple) }
        }

        indexed.sort { $0.0 < $1.0 }   // 업로드 최신순(서버 정렬) 유지
        return Partial(value: indexed.map(\.1), problems: indexed.compactMap(\.2))
    }

    /// 그룹 ID → 그 그룹에 연결된 빌드 ID 집합.
    private static func loadAssignments(
        _ groups: [GroupSnapshot], using client: ASCClient
    ) async -> Partial<[String: Set<String>]> {
        var map: [String: Set<String>] = [:]
        var problems: [String] = []

        await withTaskGroup(of: (String, Set<String>?, String?).self) { tg in
            for group in groups {
                tg.addTask {
                    let refs: ASCRelationshipList? = await client.getOrNil(
                        "/v1/betaGroups/\(group.id)/relationships/builds?limit=200")
                    guard let refs else {
                        return (group.id, nil, "'\(group.name)' 그룹의 배포 빌드를 읽지 못했습니다.")
                    }
                    return (group.id, Set(refs.ids), nil)
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
                    name: $0.attributes.name ?? "이름 없음",
                    type: $0.attributes.certificateType ?? "",
                    expiresAt: $0.attributes.expirationDate)
            }
            .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }
}
