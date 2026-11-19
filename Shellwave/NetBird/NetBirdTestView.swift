import SafariServices
import SwiftUI

/// Versteckte Testansicht für den NetBird-Machbarkeitstest.
struct NetBirdTestView: View {
    @ObservedObject private var nb = NetBirdManager.shared
    @State private var selectedPeer: NetBirdManager.Peer?
    @State private var username = "root"
    @State private var command = "whoami; hostname; uptime"
    @State private var output = ""
    @State private var running = false

    private var loginURL: Binding<URL?> {
        Binding(
            get: { if case .loggingIn(_, let url) = nb.state { return url } else { return nil } },
            set: { if $0 == nil { nb.cancelLogin() } }
        )
    }

    var body: some View {
        Form {
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

            Section("1. Anmelden") {
                if nb.loggedIn {
                    Label("Angemeldet", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    Button("Abmelden", role: .destructive) { nb.logout() }
                } else {
                    Button("Mit NetBird anmelden", systemImage: "person.badge.key") { nb.startLogin() }
                        .disabled(nb.managementURL.trimmed.isEmpty)
                }
                if case .loggingIn(let code, _) = nb.state {
                    LabeledContent("Code", value: code).font(.body.monospaced())
                }
            }

            Section("2. Overlay") {
                switch nb.state {
                case .running:
                    LabeledContent("Eigene IP", value: nb.ownIP).font(.body.monospaced())
                    Button("Peers aktualisieren", systemImage: "arrow.clockwise") { nb.refreshPeers() }
                    Button("Overlay stoppen", role: .destructive) { Task { await nb.stopOverlay() } }
                case .starting:
                    HStack { ProgressView(); Text("Starte …") }
                default:
                    Button("Overlay starten", systemImage: "network") { Task { await nb.startOverlay() } }
                        .disabled(!nb.loggedIn)
                }
                if case .failed(let message) = nb.state {
                    Text(message).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                }
            }

            if !nb.peers.isEmpty {
                Section("3. Peer wählen") {
                    ForEach(nb.peers) { peer in
                        Button {
                            selectedPeer = peer
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(peer.fqdn).font(.subheadline)
                                    Text("\(peer.ip) · \(peer.status)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedPeer == peer { Image(systemName: "checkmark").foregroundStyle(Theme.mint) }
                            }
                        }
                        .tint(.primary)
                    }
                }
            }

            if let peer = selectedPeer {
                Section("4. NetBird SSH") {
                    TextField("Benutzer", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Befehl", text: $command)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        running = true
                        Task {
                            output = await nb.runTest(peer: peer, username: username, command: command)
                            running = false
                        }
                    } label: {
                        HStack {
                            Text("Auf \(peer.fqdn) ausführen")
                            if running { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(running)
                    if !output.isEmpty {
                        Text(output).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
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
                }
            }
        }
        .navigationTitle("NetBird (Test)")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: loginURL) { url in
            SafariView(url: url)
                .ignoresSafeArea()
        }
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
