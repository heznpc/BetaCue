import SwiftUI

/// First-run connection. The key file is discovered where Apple keeps it; only the Issuer ID is asked for.
struct OnboardingView: View {
    @Bindable var store: Store
    @State private var keyID: String = ""
    @State private var issuerID: String = ""
    @State private var saveError: String?

    private var discovered: [String] { ASCCredentials.discoverKeyIDs() }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Connect App Store Connect"))
                    .font(.title3.weight(.semibold))
                Text(String(localized: "Reading your app status needs an API key from Apple. Leave the key file where it is and just give the identifiers."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if discovered.isEmpty {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "No key file found"))
                        Text(String(localized: "Create an API key in App Store Connect and put the downloaded .p8 file here."))
                            .font(.caption).foregroundStyle(.secondary)
                        Text("~/.appstoreconnect/private_keys/")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "key.slash").foregroundStyle(.orange)
                }
            } else {
                Picker(String(localized: "Key"), selection: $keyID) {
                    Text(String(localized: "Select")).tag("")
                    ForEach(discovered, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 4) {
                TextField("Issuer ID", text: $issuerID)
                    .textFieldStyle(.roundedBorder)
                Text(String(localized: "It's at the top of App Store Connect → Users and Access → Integrations."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let saveError {
                Text(saveError).font(.callout).foregroundStyle(.red)
            }

            Button(String(localized: "Connect")) { connect() }
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
            saveError = String(localized: "Couldn't save settings: \(error.localizedDescription)")
        }
    }
}

struct SettingsView: View {
    @Bindable var store: Store

    var body: some View {
        TabView {
            OnboardingView(store: store)
                .tabItem { Label(String(localized: "Connect"), systemImage: "key") }
            certificates
                .tabItem { Label(String(localized: "Certificates"), systemImage: "checkmark.seal") }
        }
        .frame(width: 500, height: 380)
    }

    private var certificates: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.certificates.isEmpty {
                Text(String(localized: "Nothing loaded yet.")).foregroundStyle(.secondary)
            } else {
                ForEach(store.certificates) { cert in
                    LabeledContent(cert.name) {
                        if let days = cert.daysLeft {
                            Text(days < 0 ? String(localized: "Expired") : String(localized: "\(days) days left"))
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
