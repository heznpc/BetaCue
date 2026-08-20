import SwiftUI

/// 최초 연결. 키 파일은 Apple이 정한 자리에서 찾고, 사용자에게는 Issuer ID만 받는다.
struct OnboardingView: View {
    @Bindable var store: Store
    @State private var keyID: String = ""
    @State private var issuerID: String = ""
    @State private var saveError: String?

    private var discovered: [String] { ASCCredentials.discoverKeyIDs() }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("App Store Connect 연결")
                    .font(.title3.weight(.semibold))
                Text("내 앱 상태를 읽어오려면 Apple에서 발급한 API 키가 필요합니다. 키 파일은 그대로 두고 식별자만 알려주면 됩니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if discovered.isEmpty {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("키 파일을 찾지 못했습니다")
                        Text("App Store Connect에서 API 키를 만들고 내려받은 .p8 파일을 아래 위치에 두세요.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("~/.appstoreconnect/private_keys/")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "key.slash").foregroundStyle(.orange)
                }
            } else {
                Picker("키", selection: $keyID) {
                    Text("선택").tag("")
                    ForEach(discovered, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 4) {
                TextField("Issuer ID", text: $issuerID)
                    .textFieldStyle(.roundedBorder)
                Text("App Store Connect → 사용자 및 액세스 → 통합 화면 상단에 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let saveError {
                Text(saveError).font(.callout).foregroundStyle(.red)
            }

            Button("연결") { connect() }
                .buttonStyle(.borderedProminent)
                .disabled(keyID.isEmpty || issuerID.trimmed.isEmpty)

            Spacer()
        }
        .padding(22)
        .frame(maxWidth: 460, alignment: .leading)
        .onAppear {
            if keyID.isEmpty, discovered.count == 1 { keyID = discovered[0] }
            keyID = keyID.isEmpty ? store.config.keyID : keyID
            issuerID = store.config.issuerID
        }
    }

    private func connect() {
        var config = store.config
        config.keyID = keyID
        config.issuerID = issuerID.trimmed
        do {
            try config.save()
            store.config = config
            saveError = nil
            store.refresh()
        } catch {
            saveError = "설정을 저장하지 못했습니다: \(error.localizedDescription)"
        }
    }
}

struct SettingsView: View {
    @Bindable var store: Store

    var body: some View {
        TabView {
            OnboardingView(store: store)
                .tabItem { Label("연결", systemImage: "key") }
            certificates
                .tabItem { Label("인증서", systemImage: "checkmark.seal") }
        }
        .frame(width: 500, height: 380)
    }

    private var certificates: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.certificates.isEmpty {
                Text("아직 불러오지 않았습니다.").foregroundStyle(.secondary)
            } else {
                ForEach(store.certificates) { cert in
                    LabeledContent(cert.name) {
                        if let days = cert.daysLeft {
                            Text(days < 0 ? "만료됨" : "\(days)일 남음")
                                .foregroundStyle(days < 60 ? .orange : .secondary)
                        } else {
                            Text("—").foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                }
            }
            Spacer()
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
