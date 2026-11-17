import SwiftUI

struct HostEditorView: View {
    @EnvironmentObject private var hosts: HostStore
    @Environment(\.dismiss) private var dismiss

    @State private var host: Host
    @State private var portText: String
    @State private var principalsText: String
    @State private var tagsText: String
    @State private var password: String

    init(host: Host) {
        _host = State(initialValue: host)
        _portText = State(initialValue: String(host.port))
        _principalsText = State(initialValue: host.principals.joined(separator: ", "))
        _tagsText = State(initialValue: host.tags.joined(separator: ", "))
        _password = State(initialValue: host.password)
    }

    private var isNew: Bool { !hosts.hosts.contains { $0.id == host.id } }
    private var canSave: Bool { !host.hostname.trimmed.isEmpty && !host.username.trimmed.isEmpty && Int(portText) != nil }

    var body: some View {
        Form {
            Section("Verbindung") {
                TextField("Name (optional)", text: $host.name)
                TextField("Hostname oder IP", text: $host.hostname)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("Port", text: $portText)
                    .keyboardType(.numberPad)
                TextField("Benutzer", text: $host.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section {
                Picker("Anmeldung", selection: $host.auth) {
                    ForEach(AuthMethod.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                switch host.auth {
                case .certificate:
                    TextField("Principals (leer = Benutzer)", text: $principalsText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                case .key:
                    Text("Der Public Key dieses Geräts muss in `authorized_keys` stehen. Du findest ihn unter Einstellungen.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .password:
                    SecureField("Passwort", text: $password)
                }
            } header: {
                Text("Anmeldung")
            } footer: {
                if host.auth == .certificate {
                    Text("Die App holt sich vor dem Verbinden ein Zertifikat von UCM mit diesen Principals. Auf dem Server müssen sie in der AuthorizedPrincipalsFile des Benutzers stehen.")
                }
            }

            Section("Darstellung") {
                Picker("Farbe", selection: $host.color) {
                    ForEach(HostColor.allCases) { c in
                        Label(c.rawValue.capitalized, systemImage: "circle.fill")
                            .foregroundStyle(c.color)
                            .tag(c)
                    }
                }
                TextField("Tags, durch Komma getrennt", text: $tagsText)
                    .textInputAutocapitalization(.never)
            }

            if let known = host.knownHostKey {
                Section {
                    Text(TOFUHostKeyValidator.fingerprint(of: known))
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                    Button("Host-Key vergessen", role: .destructive) { host.knownHostKey = nil }
                } header: {
                    Text("Host-Key")
                } footer: {
                    Text("Wird beim ersten Verbinden gespeichert. Ändert er sich, bricht die Verbindung ab.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .navigationTitle(isNew ? "Neuer Host" : host.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Abbrechen", systemImage: "xmark") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Sichern", systemImage: "checkmark") { save() }
                    .disabled(!canSave)
            }
        }
    }

    private func save() {
        host.hostname = host.hostname.trimmed
        host.username = host.username.trimmed
        host.port = Int(portText) ?? 22
        host.principals = SignRequest.parsePrincipals(principalsText)
        host.tags = SignRequest.parsePrincipals(tagsText)
        host.password = host.auth == .password ? password : ""
        hosts.upsert(host)
        dismiss()
    }
}
