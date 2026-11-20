import SwiftUI

/// Einstellungen und Diagnose für NetBird (Beta).
struct NetBirdSettingsView: View {
    @ObservedObject private var nb = NetBirdManager.shared
    @State private var confirmReset = false
    @State private var showGoLog = false

    var body: some View {
        Form {
            if !nb.lastCrash.isEmpty {
                Section {
                    ScrollView(.horizontal) {
                        Text(nb.lastCrash.prefix(6000))
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 260)
                    Button("Absturzmeldung kopieren", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = nb.lastCrash
                    }
                    Button("Verwerfen", role: .destructive) { nb.clearCrash() }
                } header: {
                    Label("Go-Absturz im letzten Lauf", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                TextField("https://netbird.example.com", text: $nb.managementURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.body.monospaced())
            } header: {
                Text("Management-URL")
            } footer: {
                Text("Ohne Pfad. Der eingebaute IdP wird unter /oauth2 erwartet.")
            }

            Section {
                if nb.loginBusy {
                    HStack { ProgressView(); Text("Verbinde mit NetBird …") }
                } else if let prompt = nb.loginPrompt {
                    if !prompt.userCode.isEmpty {
                        LabeledContent("Code", value: prompt.userCode).font(.body.monospaced())
                    }
                    Button("Login abbrechen", role: .destructive) { nb.cancelLogin() }
                } else {
                    Button("Anmelden", systemImage: "person.badge.key") { nb.login() }
                        .disabled(nb.managementURL.trimmed.isEmpty)
                }
                if let until = nb.tokenValidUntil, until > .now {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let rest = max(0, Int(until.timeIntervalSince(context.date)))
                        HStack {
                            Label(rest > 0 ? "Token gültig noch \(rest / 60):\(String(format: "%02d", rest % 60))" : "Token abgelaufen",
                                  systemImage: "checkmark.seal.fill")
                                .foregroundStyle(rest > 0 ? .green : .secondary)
                                .monospacedDigit()
                            Spacer()
                            Button("Verwerfen") { nb.forgetToken() }.font(.footnote)
                        }
                    }
                }
                LabeledContent("Peer registriert", value: nb.peerRegistered ? "ja" : "nein")
            } header: {
                Text("Anmeldung")
            } footer: {
                Text("Originaler NetBird-Login im Browser. Das Token wird 5 Minuten für Overlay-Start und NetBird SSH wiederverwendet.")
            }

            Section("Overlay") {
                switch nb.state {
                case .running:
                    LabeledContent("Eigene IP", value: nb.ownIP).font(.body.monospaced())
                    Button("Peers aktualisieren", systemImage: "arrow.clockwise") { nb.refreshPeers() }
                    Button("Overlay stoppen", role: .destructive) { Task { await nb.stopOverlay() } }
                case .starting:
                    HStack {
                        ProgressView()
                        if let since = nb.startingSince {
                            TimelineView(.periodic(from: since, by: 1)) { context in
                                Text("Starte … \(Int(context.date.timeIntervalSince(since))) s")
                                    .monospacedDigit()
                            }
                        } else {
                            Text("Starte …")
                        }
                    }
                    Button("Abbrechen", role: .destructive) { nb.cancelOverlayStart() }
                default:
                    Button("Overlay starten", systemImage: "network") { Task { await nb.startOverlay() } }
                        .disabled(nb.managementURL.trimmed.isEmpty)
                }
                if case .failed(let message) = nb.state {
                    Text(message).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                }
            }

            if !nb.peers.isEmpty {
                Section("Peers (\(nb.peers.count))") {
                    ForEach(nb.peers) { peer in
                        HStack {
                            Image(systemName: "circle.fill")
                                .font(.caption2)
                                .foregroundStyle(peer.status.lowercased() == "connected" ? .green : .secondary)
                            VStack(alignment: .leading) {
                                Text(peer.fqdn).font(.subheadline)
                                Text("\(peer.ip) · \(peer.status)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                Button("NetBird-Log anzeigen", systemImage: "doc.text.magnifyingglass") {
                    nb.loadGoLog()
                    showGoLog = true
                }
                Button("NetBird-Daten zurücksetzen", systemImage: "trash", role: .destructive) {
                    confirmReset = true
                }
                .disabled(nb.state == .starting)
            } header: {
                Text("Diagnose")
            } footer: {
                Text("Zurücksetzen löscht Peer-Schlüssel, Logs und Absturzmeldungen. Danach meldet sich die App als neuer Peer an.")
            }

            Section("Protokoll") {
                if nb.log.isEmpty {
                    Text("Noch nichts passiert.").foregroundStyle(.secondary)
                }
                ForEach(Array(nb.log.enumerated().reversed()), id: \.offset) { _, line in
                    Text(line).font(.caption2.monospaced()).textSelection(.enabled)
                }
                if !nb.log.isEmpty {
                    Button("Protokoll kopieren", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = nb.log.joined(separator: "\n")
                    }
                    Button("Protokoll leeren", role: .destructive) { nb.clearLog() }
                }
            }
        }
        .navigationTitle("NetBird (Beta)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { nb.loadDiagnostics() }
        .onDisappear { nb.stopIfUnused() }
        .confirmationDialog("NetBird-Daten zurücksetzen?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Zurücksetzen", role: .destructive) { Task { await nb.resetData() } }
        } message: {
            Text("Der Peer-Schlüssel wird gelöscht. Den alten Peer im Dashboard bitte manuell entfernen.")
        }
        .sheet(isPresented: $showGoLog) {
            NavigationStack {
                ScrollView([.vertical, .horizontal]) {
                    Text(nb.goLog)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .padding()
                }
                .navigationTitle("NetBird-Log")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Kopieren", systemImage: "doc.on.doc") { UIPasteboard.general.string = nb.goLog }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Fertig") { showGoLog = false }
                    }
                }
            }
        }
    }
}
