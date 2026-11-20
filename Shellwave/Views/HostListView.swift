import SwiftUI

struct HostListView: View {
    @EnvironmentObject private var hosts: HostStore
    @EnvironmentObject private var sessions: SessionManager
    @EnvironmentObject private var certificates: CertificateManager
    @State private var editing: Host?
    @State private var settingUp: Host?
    @State private var browsing: Host?
    @State private var search = ""

    private var filtered: [Host] {
        let q = search.trimmed.lowercased()
        guard !q.isEmpty else { return hosts.hosts }
        return hosts.hosts.filter {
            $0.displayName.lowercased().contains(q) || $0.hostname.lowercased().contains(q)
                || $0.tags.contains { $0.lowercased().contains(q) }
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 10)]

    var body: some View {
        ScrollView {
            if hosts.hosts.isEmpty {
                emptyState
            } else {
                // Bewusst ohne GlassEffectContainer: darin erscheinen Kontextmenüs der Karten nicht.
                LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(filtered) { host in
                            Button {
                                sessions.open(host)
                            } label: {
                                HostCard(host: host, session: sessions.session(for: host))
                            }
                            .buttonStyle(.plain)
                            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .contextMenu { actions(for: host) }
                                .overlay(alignment: .trailing) {
                                    Menu {
                                        actions(for: host)
                                    } label: {
                                        Image(systemName: "ellipsis")
                                            .font(.system(size: 15, weight: .semibold))
                                            .frame(width: 36, height: 36)
                                            .contentShape(.rect)
                                    }
                                    .tint(.secondary)
                                    .padding(.trailing, 4)
                                }
                        }
                }
                .padding(16)
            }
        }
        .appBackground()
        .navigationTitle("Hosts")
        .searchable(text: $search, prompt: "Host, Adresse oder Tag")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Host hinzufügen", systemImage: "plus") { editing = Host() }
            }
        }
        .sheet(item: $editing) { host in
            NavigationStack { HostEditorView(host: host) }
        }
        .sheet(item: $settingUp) { host in
            NavigationStack { ServerSetupView(host: host) }
        }
        .sheet(item: $browsing) { host in
            NavigationStack { SFTPBrowserView(host: host, certificates: certificates, hosts: hosts) }
        }
    }

    @ViewBuilder
    private func actions(for host: Host) -> some View {
        Button("Verbinden", systemImage: "terminal") { sessions.open(host) }
        Button("Bearbeiten", systemImage: "pencil") { editing = hosts.hosts.first { $0.id == host.id } ?? host }
        Button("Server einrichten", systemImage: "wand.and.stars") { settingUp = host }
        Button("Dateien (SFTP)", systemImage: "folder") { browsing = host }
        Button("Duplizieren", systemImage: "plus.square.on.square") {
            var copy = host
            copy.id = UUID()
            copy.name += " Kopie"
            copy.knownHostKey = nil
            copy.setupDone = false
            editing = copy
        }
        Divider()
        Button("Löschen", systemImage: "trash", role: .destructive) { hosts.delete(host) }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "server.rack")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.accent)
                .padding(24)
                .glassCircle()
            Text("Noch keine Hosts").font(.title3.weight(.semibold))
            Text("Lege deinen ersten Server an. Mit UCM-Zertifikat brauchst du kein Passwort.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Host hinzufügen", systemImage: "plus") { editing = Host() }
                .glassProminentButton()
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

struct HostCard: View {
    let host: Host
    let session: TerminalSession?

    /// Ziel ohne Zusatz (die Verbindungsart steht als Symbol daneben).
    private var target: String {
        if host.isNetBird || host.port == 22 { return "\(host.username)@\(host.hostname)" }
        return "\(host.username)@\(host.hostname):\(host.port)"
    }

    private var iconColor: Color { host.os.map { $0.kind.color } ?? host.color.color }
    private var iconSymbol: String { host.os.map { $0.kind.symbol } ?? "terminal" }
    private var authSymbol: String { host.isNetBird ? "person.badge.key" : host.auth.symbol }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(iconColor.opacity(0.22))
                Circle().strokeBorder(host.color.color.opacity(0.55), lineWidth: 1.5)
                Image(systemName: iconSymbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(host.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let os = host.os {
                        Text(os.label)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(os.kind.color)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 5) {
                    Image(systemName: host.transport.symbol)
                        .accessibilityLabel(host.transport.label)
                    Image(systemName: authSymbol)
                        .accessibilityLabel(host.isNetBird ? "NetBird-Login" : host.auth.label)
                    Text(target)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let tag = host.tags.first {
                        Badge(text: tag, symbol: "tag")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let session {
                SessionDot(session: session)
            }
            Color.clear.frame(width: 24)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(.rect)
        .glassCard(cornerRadius: 18)
    }
}

struct Badge: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.white.opacity(0.08), in: Capsule())
    }
}

struct StatusDot: View {
    let state: TerminalSession.State

    var color: Color {
        switch state {
        case .connected: return .green
        case .connecting, .renewingCertificate: return .yellow
        case .failed: return .red
        case .idle, .closed: return .gray
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .shadow(color: color.opacity(0.8), radius: 4)
    }
}

/// Beobachtet eine Session, damit sich der Punkt live aktualisiert.
struct SessionDot: View {
    @ObservedObject var session: TerminalSession
    var body: some View { StatusDot(state: session.state) }
}
