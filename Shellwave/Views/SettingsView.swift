import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var ucm: UCMSettings

    @State private var apiKeyDraft = ""
    @State private var cas: [SSHCA] = []
    @State private var loading = false
    @State private var message: String?
    @State private var untrustedFingerprint: String?

    private let validityOptions: [(String, Int)] = [
        ("1 Stunde", 3600), ("8 Stunden", 8 * 3600), ("12 Stunden", 12 * 3600),
        ("24 Stunden", 24 * 3600), ("7 Tage", 7 * 86400), ("Standard der CA", 0),
    ]

    var body: some View {
        Form {
            Section {
                TextField("https://ucm.example.lan", text: $ucm.server)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField(ucm.apiKey.isEmpty ? "API-Schlüssel" : "API-Schlüssel (gespeichert)", text: $apiKeyDraft)
                    .onSubmit(saveKey)
                if !apiKeyDraft.isEmpty {
                    Button("API-Schlüssel sichern", systemImage: "key.fill", action: saveKey)
                }
                if !ucm.pinnedFingerprint.isEmpty {
                    LabeledContent("Gepinntes TLS-Zertifikat") {
                        Text(String(ucm.pinnedFingerprint.prefix(23)) + "…").font(.caption.monospaced())
                    }
                    Button("Pinning entfernen", role: .destructive) { ucm.pinnedFingerprint = "" }
                }
            } header: {
                Text("Ultimate CA Manager")
            } footer: {
                Text("Der API-Schlüssel braucht nur das Recht, SSH-Zertifikate auszustellen. Er liegt im Schlüsselbund dieses Geräts.")
            }

            Section {
                Button {
                    Task { await loadCAs() }
                } label: {
                    HStack {
                        Label("CAs von UCM laden", systemImage: "arrow.down.circle")
                        if loading { Spacer(); ProgressView() }
                    }
                }
                .disabled(ucm.server.trimmed.isEmpty || ucm.apiKey.isEmpty || loading)

                if !cas.isEmpty {
                    Picker("User-CA", selection: $ucm.caID) {
                        Text("Keine").tag(0)
                        ForEach(cas.filter { $0.type == .user }) { ca in
                            Text(ca.displayName).tag(ca.id)
                        }
                    }
                } else if ucm.caID > 0 {
                    LabeledContent("User-CA", value: "ID \(ucm.caID)")
                }

                Picker("Laufzeit", selection: $ucm.validitySeconds) {
                    ForEach(validityOptions, id: \.1) { Text($0.0).tag($0.1) }
                }

                if let ca = cas.first(where: { $0.id == ucm.caID }), let allowed = ca.allowedPrincipals, !allowed.isEmpty {
                    LabeledContent("Erlaubte Principals") {
                        Text(allowed.joined(separator: ", ")).font(.caption.monospaced())
                    }
                }
            } header: {
                Text("Zertifikate")
            } footer: {
                Text("Die App erneuert Zertifikate still, sobald weniger als 20 % der Laufzeit übrig sind.")
            }

            if let message {
                Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }

            if let fp = untrustedFingerprint {
                Section("TLS-Zertifikat nicht vertrauenswürdig") {
                    Text(fp).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Diesem Zertifikat vertrauen", systemImage: "lock.shield") {
                        ucm.pinnedFingerprint = fp
                        untrustedFingerprint = nil
                        Task { await loadCAs() }
                    }
                }
            }

            DeviceKeySection()

            Section("Über") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
            }
        }
        .appBackground()
        .navigationTitle("Einstellungen")
    }

    private func saveKey() {
        guard !apiKeyDraft.trimmed.isEmpty else { return }
        ucm.saveAPIKey(apiKeyDraft)
        apiKeyDraft = ""
        message = "API-Schlüssel gespeichert."
    }

    private func loadCAs() async {
        loading = true
        defer { loading = false }
        do {
            cas = try await ucm.client().listCAs()
            message = cas.isEmpty ? "Keine SSH-CAs gefunden." : "\(cas.count) SSH-CA(s) geladen."
            if ucm.caID == 0, let first = cas.first(where: { $0.type == .user }) { ucm.caID = first.id }
        } catch UCMError.untrustedCertificate(let fp) {
            untrustedFingerprint = fp
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}

/// Public Key und Fingerprint dieses Geräts, zum Kopieren oder Teilen.
struct DeviceKeySection: View {
    private var key: DeviceKey { DeviceKey.shared }
    @State private var copied = false

    var body: some View {
        Section {
            LabeledContent("Fingerprint") {
                Text(key.fingerprint).font(.caption2.monospaced()).textSelection(.enabled)
            }
            Text(key.publicKeyLine)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .lineLimit(3)
            HStack {
                Button(copied ? "Kopiert" : "Kopieren", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = key.publicKeyLine
                    copied = true
                }
                .glassButton()
                ShareLink(item: key.publicKeyLine, preview: SharePreview("id_ed25519.pub")) {
                    Label("Teilen", systemImage: "square.and.arrow.up")
                }
                .glassButton()
            }
        } header: {
            Text("Schlüssel dieses Geräts")
        } footer: {
            Text("Ed25519, erzeugt auf dem Gerät. Der private Teil verlässt das Gerät nie. Zum manuellen Signieren den Public Key z. B. an UCM Remote teilen.")
        }
    }
}
