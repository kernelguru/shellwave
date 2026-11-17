import SwiftUI

struct HostListView: View {
    @EnvironmentObject private var hosts: HostStore
    @EnvironmentObject private var sessions: SessionManager
    @State private var editing: Host?
    @State private var search = ""

    private var filtered: [Host] {
        let q = search.trimmed.lowercased()
        guard !q.isEmpty else { return hosts.hosts }
        return hosts.hosts.filter {
            $0.displayName.lowercased().contains(q) || $0.hostname.lowercased().contains(q)
                || $0.tags.contains { $0.lowercased().contains(q) }
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 14)]

    var body: some View {
        ScrollView {
            if hosts.hosts.isEmpty {
                emptyState
            } else {
                GlassEffectContainer(spacing: 14) {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(filtered) { host in
                            HostCard(host: host, session: sessions.session(for: host))
                                .onTapGesture { sessions.open(host) }
                                .contextMenu {
                                    Button("Verbinden", systemImage: "terminal") { sessions.open(host) }
                                    Button("Bearbeiten", systemImage: "pencil") { editing = host }
                                    Button("Duplizieren", systemImage: "plus.square.on.square") {
                                        var copy = host
                                        copy.id = UUID()
                                        copy.name += " Kopie"
                                        copy.knownHostKey = nil
                                        editing = copy
                                    }
                                    Divider()
                                    Button("Löschen", systemImage: "trash", role: .destructive) { hosts.delete(host) }
                                }
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
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "server.rack")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.mint)
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

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(host.color.color.opacity(0.25))
                Image(systemName: "terminal")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(host.color.color)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(host.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(host.address)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Badge(text: host.auth.label, symbol: host.auth.symbol)
                    ForEach(host.tags.prefix(2), id: \.self) { Badge(text: $0, symbol: "tag") }
                }
            }
            Spacer(minLength: 0)
            if let session {
                SessionDot(session: session)
            }
        }
        .padding(16)
        .contentShape(.rect)
        .glassCard(cornerRadius: 22)
    }
}

struct Badge: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
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
