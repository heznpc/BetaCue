import SwiftUI

/// 상세. 홈에서 숨긴 Apple 개념을 필요할 때만 확인하는 자리다. (명세 §15)
struct AppDetailView: View {
    let app: AppSnapshot
    let store: Store
    @State private var showsRawState = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                Divider()
                currentBuild
                distribution
                history
                appleDetails
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(app.name)
    }

    private var header: some View {
        let status = app.status
        let state = status.state
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: state.severity.symbol)
                    .foregroundStyle(state.severity.tint)
                    .font(.title3)
                Text(state.headline).font(.title3.weight(.semibold))
                if let term = state.appleTerm {
                    Text(term)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: .rect(cornerRadius: 4))
                        .textSelection(.enabled)
                }
            }
            Text(state.description)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // "새 버전 됐나"와 "지금 받을 수 있나"는 서로 다른 질문이다.
            if let testable = status.testable {
                Label {
                    Text(status.hasOlderTestableBuild
                         ? "지금은 \(testable.displayVersion)을(를) 테스트할 수 있습니다"
                         : "지금 설치할 수 있습니다")
                    + Text(status.audience.map { " · \($0)" } ?? "")
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .font(.callout)
                .foregroundStyle(.green)
            }

            if app.isPartial {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(app.partialErrors, id: \.self) { problem in
                        Label(problem, systemImage: "wifi.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let blocker = state.blocker {
                Label(blocker, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.1), in: .rect(cornerRadius: 8))
            }

            HStack(spacing: 8) {
                if let action = state.nextAction {
                    ActionButton(action: action, app: app, store: store)
                }
                Text("마지막 확인: \(RelativeTime.string(app.fetchedAt))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var currentBuild: some View {
        if let build = app.latestBuild {
            Section2("현재 버전") {
                LabeledContent("버전", value: build.displayVersion)
                if let uploaded = build.uploadedAt {
                    LabeledContent("업로드", value: RelativeTime.string(uploaded))
                }
                LabeledContent("상태", value: "\(build.humanState)  ·  \(build.processingState)")
                if let days = build.daysUntilExpiry, !build.isExpired {
                    LabeledContent("만료", value: "\(days)일 남음")
                }
            }
        }
    }

    /// 앱에 그룹이 있다는 것과 **이 빌드가 그 그룹에 연결됐다**는 건 다른 사실이다.
    /// 둘을 섞으면 "누가 받을 수 있나"에 자신 있게 틀린 답을 하게 된다.
    private var distribution: some View {
        Section2("누가 테스트할 수 있나") {
            if app.groups.isEmpty {
                Text("테스터 그룹이 없습니다.").foregroundStyle(.secondary)
            } else {
                let assigned = app.latestBuild?.assignedGroupIDs ?? []
                ForEach(app.groups) { group in
                    let isOn = assigned.contains(group.id)
                    LabeledContent {
                        HStack(spacing: 6) {
                            if group.publicLinkEnabled {
                                Image(systemName: "link").foregroundStyle(.blue)
                            }
                            Text(group.testerCount == 0 ? "없음" : "\(group.testerCount)명")
                                .foregroundStyle(isOn ? .primary : .secondary)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isOn ? .green : .secondary)
                            Text("\(group.isInternal ? "내부" : "외부") · \(group.name)")
                        }
                    }
                    .font(.callout)
                }
                Text("체크 표시는 최신 빌드가 그 그룹에 연결됐다는 뜻입니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let count = app.latestBuild?.individualTesterCount, count > 0 {
                LabeledContent("개별 초대", value: "\(count)명").font(.callout)
            }
            // 설치 여부는 신뢰 가능한 데이터가 없어 표시하지 않는다. (명세 §28)
        }
    }

    @ViewBuilder
    private var history: some View {
        if app.builds.count > 1 {
            Section2("이전 버전") {
                ForEach(app.builds.dropFirst()) { build in
                    LabeledContent(build.displayVersion) {
                        Text(build.humanState).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }

    /// 고급 사용자용 원본. 기본 접힘. (명세 §15, §29)
    private var appleDetails: some View {
        DisclosureGroup("Apple 원본 정보", isExpanded: $showsRawState) {
            VStack(alignment: .leading, spacing: 5) {
                LabeledContent("상태 ID", value: app.status.state.id.rawValue)
                if let reason = app.status.state.reason {
                    LabeledContent("원인 코드", value: reason)
                }
                LabeledContent("Bundle ID", value: app.bundleID)
                ForEach(app.status.state.rawEvidence.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    LabeledContent(key, value: value)
                }
                Button("App Store Connect에서 열기") {
                    if let url = app.appStoreConnectURL { NSWorkspace.shared.open(url) }
                }
                .padding(.top, 5)
            }
            .font(.callout.monospaced())
            .padding(.top, 7)
        }
        .font(.callout)
    }
}

/// 제목 + 내용 묶음.
struct Section2<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
