import SwiftUI

struct ServerSetupView: View {
    let host: Host

    @EnvironmentObject private var ucm: UCMSettings
    @Environment(\.dismiss) private var dismiss

    @EnvironmentObject private var setup: ServerSetup
    @State private var useDeviceKey = false
    @State private var password = ""
    @State private var mappings: [MappingDraft] = []
    @State private var installMosh = true
    @State private var installClaude = false
    @State private var showScript = false
    @State private var allowedPrincipals: [String] = []

    struct MappingDraft: Identifiable {
        let id = UUID()
        var user: String
        var principals: String
    }

    var body: some View {
        Form {
            Section {
                Picker("Anmeldung zum Einrichten", selection: $useDeviceKey) {
                    Text("Passwort").tag(false)
                    Text("Geräte-Key").tag(true)
                }
                .pickerStyle(.segmented)
                if !useDeviceKey {
                    SecureField("Passwort für \(host.username)", text: $password)
                }
            } header: {
                Text("Einmalige Anmeldung")
            } footer: {
                Text("Nur zum Einrichten. Danach meldet sich die App mit UCM-Zertifikaten an. Ohne root braucht \(host.username) sudo-Rechte.")
            }

            Section {
                ForEach($mappings) { $m in
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Benutzer", text: $m.user)
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Principals, durch Komma getrennt", text: $m.principals)
                            .font(.footnote.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { mappings.remove(atOffsets: $0) }
                Button("Benutzer hinzufügen", systemImage: "plus") {
                    mappings.append(MappingDraft(user: "", principals: ""))
                }
            } header: {
                Text("Wer darf sich als wer anmelden?")
            } footer: {
                if !allowedPrincipals.isEmpty {
                    Text("Die CA erlaubt: \(allowedPrincipals.joined(separator: ", "))")
                } else {
                    Text("Für jeden Server-Benutzer eine Datei in /etc/ssh/auth_principals/ mit diesen Principals.")
                }
            }

            Section("Zusätzlich") {
                Toggle("Mosh installieren, falls nötig", isOn: $installMosh)
                Toggle("Claude Code installieren", isOn: $installClaude)
            }

            if !setup.steps.isEmpty {
                Section("Ablauf") {
                    ForEach(setup.steps) { step in
                        StepRow(step: step)
                    }
                }
            }

            Section {
                Button {
                    Task { await start() }
                } label: {
                    HStack {
                        Spacer()
                        if setup.running { ProgressView().padding(.trailing, 6) }
                        Text(setup.succeeded ? "Fertig" : (setup.running ? "Richte ein …" : "Server einrichten"))
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(setup.running || !canStart)

                Button("Skript ansehen", systemImage: "doc.text.magnifyingglass") {
                    Task {
                        await setup.preview(host: host, mappings: currentMappings, installMosh: installMosh)
                        showScript = true
                    }
                }
            } footer: {
                if !ucm.isConfigured {
                    Text("UCM ist noch nicht eingerichtet (Einstellungen).").foregroundStyle(.orange)
                }
            }
        }
        .appBackground()
        .navigationTitle("Server einrichten")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Schließen", systemImage: "xmark") { dismiss() }
            }
        }
        .sheet(isPresented: $showScript) {
            NavigationStack {
                ScrollView {
                    Text(setup.scriptPreview)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("Einrichtungs-Skript")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fertig") { showScript = false }
                    }
                }
            }
        }
        .onAppear(perform: prepare)
        .task { await loadAllowedPrincipals() }
    }

    private var canStart: Bool {
        ucm.isConfigured && (useDeviceKey || !password.isEmpty) && currentMappings.contains { $0.user == host.username && !$0.principals.isEmpty }
    }

    private var currentMappings: [PrincipalMapping] {
        mappings.map { PrincipalMapping(user: $0.user.trimmed, principals: SignRequest.parsePrincipals($0.principals)) }
            .filter { !$0.user.isEmpty && !$0.principals.isEmpty }
    }

    private func prepare() {
        guard mappings.isEmpty else { return }
        setup.reset()
        guard mappings.isEmpty else { return }
        if !host.principalMap.isEmpty {
            mappings = host.principalMap.map { MappingDraft(user: $0.user, principals: $0.principals.joined(separator: ", ")) }
        } else {
            mappings = [MappingDraft(user: host.username, principals: host.effectivePrincipals.joined(separator: ", "))]
        }
        if host.auth == .password { password = host.password }
        useDeviceKey = host.auth == .key
    }

    private func loadAllowedPrincipals() async {
        guard ucm.isConfigured, let cas = try? await ucm.client().listCAs(),
              let ca = cas.first(where: { $0.id == ucm.caID }) else { return }
        allowedPrincipals = ca.allowedPrincipals ?? []
    }

    private func start() async {
        let options = ServerSetup.Options(
            bootstrap: useDeviceKey ? .deviceKey : .password(password),
            bootstrapPassword: useDeviceKey ? nil : password,
            mappings: currentMappings,
            installMosh: installMosh,
            installClaude: installClaude
        )
        await setup.run(host: host, options: options)
    }
}

struct StepRow: View {
    let step: ServerSetup.Step

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                switch step.state {
                case .running: ProgressView().controlSize(.small)
                case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
                }
            }
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).font(.subheadline.weight(.medium))
                if !step.detail.isEmpty {
                    Text(step.detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
