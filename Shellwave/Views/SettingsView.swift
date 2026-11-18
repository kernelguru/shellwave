import SwiftUI
import UniformTypeIdentifiers

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

            ClaudeSettingsSection()

            AppPreferencesSection()

            BackupSection()

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

/// Assistent: Modus, Anbieter, Schlüssel, Modell und Freigaberegeln.
struct ClaudeSettingsSection: View {
    @EnvironmentObject private var claude: ClaudeSettings
    @State private var keyDraft = ""

    private var usesGemini: Bool { claude.mode == .api && claude.apiProvider == .google }

    var body: some View {
        Section {
            Picker("Modus", selection: Binding(get: { claude.mode }, set: { claude.mode = $0 })) {
                ForEach(ClaudeMode.allCases) { Text($0.label).tag($0) }
            }
            if claude.mode == .api {
                Picker("Anbieter", selection: Binding(get: { claude.apiProvider }, set: { claude.apiProvider = $0; keyDraft = "" })) {
                    ForEach(APIProvider.allCases) { Text($0.label).tag($0) }
                }
            }

            if usesGemini {
                SecureField(claude.geminiKey.isEmpty ? "Gemini-API-Schlüssel" : "Gemini-Schlüssel (gespeichert)", text: $keyDraft)
                    .onSubmit(save)
                if !keyDraft.isEmpty {
                    Button("Gemini-Schlüssel sichern", systemImage: "key.fill", action: save)
                }
                TextField("Gemini-Modell", text: $claude.geminiModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
            } else {
                SecureField(claude.apiKey.isEmpty ? "Claude-API-Schlüssel" : "Claude-Schlüssel (gespeichert)", text: $keyDraft)
                    .onSubmit(save)
                if !keyDraft.isEmpty {
                    Button("Claude-Schlüssel sichern", systemImage: "key.fill", action: save)
                }
                if claude.mode == .api {
                    TextField("Claude-Modell", text: $claude.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                }
            }

            Toggle("Lesende Befehle ohne Rückfrage", isOn: $claude.autoApproveReadOnly)
            Toggle("Freigaben mit Face ID bestätigen", isOn: $claude.requireBiometrics)
            if claude.mode == .claudeCode {
                Toggle("API-Schlüssel an Claude Code übergeben", isOn: $claude.passKeyToServer)
            }
        } header: {
            Text("Assistent")
        } footer: {
            Text(footer)
        }
    }

    private var footer: String {
        switch claude.mode {
        case .claudeCode:
            return "Claude Code läuft auf dem Server (Installation über „Server einrichten“, Login einmal mit `claude auth login`). Ohne übergebenen Schlüssel nutzt es dein Claude-Abo."
        case .api where claude.apiProvider == .google:
            return "Gemini über die API: Schlüssel kostenlos in Google AI Studio. Achtung: In der Gratis-Stufe darf Google Anfragen zur Verbesserung seiner Produkte nutzen – also auch Befehle und Terminal-Ausgaben."
        case .api:
            return "Die App ruft die Claude-API direkt auf und führt Befehle per SSH aus. Abrechnung über Guthaben in der Claude Console, nicht über das Abo."
        }
    }

    private func save() {
        guard !keyDraft.trimmed.isEmpty else { return }
        if usesGemini {
            claude.saveGeminiKey(keyDraft)
        } else {
            claude.saveAPIKey(keyDraft)
        }
        keyDraft = ""
    }
}

/// Terminal-Darstellung, Live Activity und Keep-alive.
struct AppPreferencesSection: View {
    @EnvironmentObject private var sessions: SessionManager
    @AppStorage("liveActivity.enabled") private var liveActivity = true
    @AppStorage("terminal.fontSize") private var fontSize: Double = 13
    @State private var themeID = TerminalThemeStore.current.id

    var body: some View {
        Section {
            Picker("Farbschema", selection: $themeID) {
                ForEach(TerminalTheme.all) { Text($0.name).tag($0.id) }
            }
            .onChange(of: themeID) {
                guard let theme = TerminalTheme.all.first(where: { $0.id == themeID }) else { return }
                TerminalThemeStore.select(theme)
                for s in sessions.sessions { TerminalThemeStore.apply(theme, to: s.terminalView) }
            }
            Stepper("Schriftgröße \(Int(fontSize)) pt", value: $fontSize, in: 8...24)
            Toggle("Live Activity im Dynamic Island", isOn: $liveActivity)
            LabeledContent("Keep-alive") {
                Text(keepAliveText).foregroundStyle(.secondary)
            }
        } header: {
            Text("Terminal und Sessions")
        } footer: {
            Text("Keep-alive braucht die Standort-Freigabe „Beim Verwenden“. Die App nutzt nur grobe Updates und verwirft die Position.")
        }
    }

    private var keepAliveText: String {
        switch sessions.keepAlive.authorization {
        case .denied, .restricted: return "Standort verweigert"
        case .notDetermined: return "noch nicht gefragt"
        default: return sessions.keepAlive.isActive ? "aktiv" : "bereit"
        }
    }
}

/// Hosts und Snippets exportieren und importieren (ohne Passwörter und Schlüssel).
struct BackupSection: View {
    @EnvironmentObject private var hosts: HostStore
    @EnvironmentObject private var snippets: SnippetStore
    @State private var exportURL: URL?
    @State private var showImporter = false
    @State private var message: String?

    struct Backup: Codable {
        var version = 1
        var hosts: [Host]
        var snippets: [Snippet]
    }

    var body: some View {
        Section {
            Button("Exportieren", systemImage: "square.and.arrow.up") { export() }
            Button("Importieren", systemImage: "square.and.arrow.down") { showImporter = true }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Sicherung")
        } footer: {
            Text("JSON mit Hosts, Principals und Snippets. Passwörter, Geräte-Key und Zertifikate bleiben im Schlüsselbund.")
        }
        .sheet(item: $exportURL) { url in ShareSheet(items: [url]) }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            importBackup(url)
        }
    }

    private func export() {
        let backup = Backup(hosts: hosts.hosts, snippets: snippets.snippets)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(backup) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shellwave-backup.json")
        try? data.write(to: url)
        exportURL = url
    }

    private func importBackup(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let backup = try? JSONDecoder().decode(Backup.self, from: data) else {
            message = "Datei konnte nicht gelesen werden."
            return
        }
        var added = 0
        for host in backup.hosts where !hosts.hosts.contains(where: { $0.id == host.id }) {
            hosts.upsert(host)
            added += 1
        }
        var merged = snippets.snippets
        for s in backup.snippets where !merged.contains(where: { $0.id == s.id }) { merged.append(s) }
        snippets.replaceAll(merged)
        message = "\(added) Host(s) und \(backup.snippets.count) Snippet(s) übernommen."
    }
}
