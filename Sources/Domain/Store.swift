import Foundation
import Observation

/// 화면이 보는 단 하나의 상태 소유자.
///
/// 파이프라인은 명세 §2.1 그대로다:
/// ASC API → Collector → Normalizer → StateStore → RuleEngine → 사람이 읽는 상태 → UI.
/// 이 경로에는 LLM 호출이 하나도 없다.
@MainActor
@Observable
final class Store {
    private(set) var apps: [AppSnapshot] = []
    private(set) var certificates: [CertificateSnapshot] = []
    private(set) var lastRefresh: Date?
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?

    var config: BetaCueConfig {
        didSet { client = config.credentials.map { ASCClient(credentials: $0) } }
    }

    private var client: ASCClient?
    private let persistence: StateStore
    private var refreshTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    var isConfigured: Bool { client != nil }

    /// 창이 닫혀 있어도 폴링과 알림은 계속돼야 하므로 앱 수명과 같은 인스턴스를 쓴다.
    static let shared = Store()

    init(config: BetaCueConfig = .load(), persistence: StateStore = StateStore()) {
        self.config = config
        self.persistence = persistence
        self.client = config.credentials.map { ASCClient(credentials: $0) }
        // 네트워크를 기다리지 않고 마지막으로 본 상태를 즉시 보여준다. (명세 UC-01 ①)
        self.apps = Self.sorted(persistence.loadSnapshots())
        self.lastRefresh = apps.map(\.fetchedAt).max()
    }

    // MARK: - 폴링 (명세 §22)

    /// 처리 중인 빌드가 있으면 1분, 평소엔 5분, 조용하면 15분.
    private var pollInterval: TimeInterval {
        if apps.contains(where: { $0.status.state.id == .buildProcessing }) { return 60 }
        if apps.contains(where: { $0.status.state.severity == .warning }) { return 300 }
        return apps.isEmpty ? 300 : 900
    }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshNow()
                guard let interval = self?.pollInterval else { return }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// 수동 새로고침. (명세 §22 마지막 줄)
    func refresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await self?.refreshNow()
            self?.refreshTask = nil
        }
    }

    private func refreshNow() async {
        guard let client else {
            errorMessage = ASCError.notConfigured.localizedDescription
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let appList: ASCList<AppAttributes> = try await client.get("/v1/apps?limit=200")

            // 앱 하나가 실패해도 나머지는 갱신돼야 한다. 실패한 앱은 마지막 상태를 유지한다.
            var collected: [AppSnapshot] = []
            var failedNames: [String] = []
            await withTaskGroup(of: Result<AppSnapshot, Error>.self) { group in
                for app in appList.data {
                    group.addTask {
                        do { return .success(try await Collector.loadApp(app, using: client)) }
                        catch { return .failure(AppLoadFailure(name: app.attributes.name, underlying: error)) }
                    }
                }
                for await result in group {
                    switch result {
                    case .success(let snapshot): collected.append(snapshot)
                    case .failure(let error):
                        let name = (error as? AppLoadFailure)?.name ?? "앱"
                        failedNames.append(name)
                        // 새로 못 읽었으면 직전 스냅샷을 그대로 둔다 — 화면이 비지 않게.
                        if let stale = apps.first(where: { $0.name == name }) {
                            collected.append(stale)
                        }
                    }
                }
            }
            collected = Self.sorted(collected)

            detectAndNotify(collected)
            persistence.saveSnapshots(collected)
            apps = collected

            certificates = try await Collector.loadCertificates(using: client)
            notifyExpiringCertificates()

            lastRefresh = Date()
            errorMessage = failedNames.isEmpty
                ? nil
                : "\(failedNames.joined(separator: ", "))을(를) 읽지 못해 이전 상태를 표시합니다."
        } catch {
            errorMessage = (error as? ASCError)?.localizedDescription ?? error.localizedDescription
        }
    }

    /// 조치가 필요한 것부터, 그다음 이름순. (명세 §13)
    private static func sorted(_ list: [AppSnapshot]) -> [AppSnapshot] {
        list.sorted {
            let a = $0.status.state.severity, b = $1.status.state.severity
            return a == b
                ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                : a < b
        }
    }

    // MARK: - 전이 감지와 알림 (명세 §12, §21)

    private func detectAndNotify(_ next: [AppSnapshot]) {
        for snapshot in next {
            // 부분 실패로 되돌려 쓴 이전 스냅샷은 전이로 치지 않는다.
            guard !snapshot.isPartial || snapshot.fetchedAt > (lastRefresh ?? .distantPast) else {
                continue
            }
            let current = snapshot.status.state
            let previous = persistence.lastFingerprint(appID: snapshot.id)
            guard previous?.fingerprint != current.fingerprint else { continue }

            persistence.recordTransition(appID: snapshot.id, from: previous?.state,
                                         to: current.id, fingerprint: current.fingerprint)

            // 첫 조회에서는 알리지 않는다. 알림이 한꺼번에 쏟아지는 것을 막는다.
            guard let previousState = previous?.state else { continue }
            guard let message = notificationText(app: snapshot, from: previousState, to: current)
            else { continue }
            Notifier.post(title: message.title, body: message.body)
        }
    }

    /// 모든 변경을 알리지 않는다. 알릴 가치가 있는 전이만 정의한다. (명세 §12)
    private func notificationText(app: AppSnapshot, from: AppStateID, to: AppStateDefinition)
        -> (title: String, body: String)?
    {
        let version = app.latestBuild?.displayVersion ?? ""

        switch (from, to.id) {
        case (.buildProcessing, .internalTestingReady),
             (.buildProcessing, .externalTestingReady),
             (.buildProcessing, .externalReviewRequired):
            return ("\(app.name) 테스트 준비 완료",
                    version.isEmpty ? "아이폰 TestFlight에서 설치할 수 있습니다."
                                    : "\(version) — 아이폰 TestFlight에서 설치할 수 있습니다.")

        case (.buildProcessing, .buildReadyNotDistributed):
            return ("\(app.name) 배포 대상 없음", to.blocker ?? to.description)

        case (_, .buildInvalid) where app.status.testable != nil:
            let alive = app.status.testable?.displayVersion ?? ""
            return ("\(app.name) 새 빌드 거부됨", "\(alive)은(는) 계속 테스트할 수 있습니다.")

        case (.externalReviewPending, .externalTestingReady):
            return ("\(app.name) 외부 테스트 승인됨", "외부 테스터에게 배포할 수 있습니다.")

        case (_, .buildInvalid):
            return ("\(app.name) 빌드 거부됨", to.description)

        case (_, .actionRequired), (_, .unknown):
            // 이전에 없던 blocker가 생긴 경우만.
            return ("\(app.name) 조치 필요", to.blocker ?? to.description)

        case (_, .buildReadyNotDistributed):
            return ("\(app.name) 배포 대상 없음", to.blocker ?? to.description)

        default:
            return nil
        }
    }

    private func notifyExpiringCertificates() {
        for cert in certificates where cert.isExpiringSoon {
            guard let days = cert.daysLeft, days >= 0 else { continue }
            let previous = persistence.exchangeFeedbackCount(
                appID: "certificate:\(cert.id)", kind: "expiry-notified", newCount: 1)
            guard previous == nil else { continue }   // 인증서당 한 번만
            Notifier.post(title: "인증서 만료 임박",
                          body: "\(cert.name) — \(days)일 뒤 만료됩니다.")
        }
    }

    // MARK: - 명령 (명세 §25)

    /// 진행 중인 명령. 버튼 비활성화와 진행 표시에 쓴다.
    private(set) var runningCommand: String?

    /// 빌드를 그룹에 연결한다. v0에서 유일한 쓰기 동작이다. (명세 §26)
    func distribute(build: BuildSnapshot, of app: AppSnapshot, to groups: [GroupSnapshot]) {
        guard let client, runningCommand == nil else { return }
        runningCommand = app.id
        Task { [weak self] in
            defer { self?.runningCommand = nil }
            do {
                try await Commands.assign(build: build.id, toGroups: groups.map(\.id), using: client)
                await self?.refreshNow()
            } catch {
                self?.errorMessage = (error as? ASCError)?.localizedDescription
                    ?? error.localizedDescription
            }
        }
    }

    /// 이 빌드를 붙일 후보 그룹. 이미 붙어 있는 곳은 뺀다.
    func distributionTargets(for build: BuildSnapshot, in app: AppSnapshot) -> [GroupSnapshot] {
        app.groups.filter { !build.assignedGroupIDs.contains($0.id) }
    }

    // MARK: - 조회 보조

    func transitions(for app: AppSnapshot) -> [StateStore.Transition] {
        persistence.transitions(appID: app.id)
    }
}

/// 어느 앱이 실패했는지 알아야 그 앱만 이전 상태로 되돌릴 수 있다.
struct AppLoadFailure: Error {
    var name: String
    var underlying: Error
}
