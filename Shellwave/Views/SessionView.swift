import SwiftUI

struct SessionView: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject private var sessions: SessionManager
    @EnvironmentObject private var certificates: CertificateManager
    @EnvironmentObject private var hosts: HostStore
    @AppStorage("terminal.fontSize") private var fontSize: Double = 13

    @State private var showSnippets = false
    @State private var showSFTP = false
    @State private var showThemes = false
    @State private var editingHost: Host?

    var body: some View {
        ZStack(alignment: .top) {
            Color(uiColor: session.terminalView.backgroundColor ?? .black).ignoresSafeArea()

            VStack(spacing: 0) {
                Color.clear.frame(height: sessions.sessions.count > 1 ? 100 : 56)
                TerminalScreen(session: session, fontSize: $fontSize)
                    .padding(.horizontal, 4)
            }

            VStack(spacing: 8) {
                topBar
                if sessions.sessions.count > 1 {
                    SessionTabs()
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)

            if session.state != .connected {
                statusOverlay
                    .padding(.top, 140)
                    .padding(.horizontal, 24)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            ApprovalBanner(agent: session.claude)
        }
        .animation(.smooth, value: session.state)
        .sensoryFeedback(trigger: session.state) { _, new in
            switch new {
            case .connected: return .success
            case .failed: return .error
            default: return nil
            }
        }
        .sheet(isPresented: $sessions.showClaude) {
            ClaudePanel(agent: session.claude)
                .presentationDetents([.fraction(0.45), .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.45)))
                .presentationBackground(.clear)
        }
        .sheet(isPresented: $showSnippets) {
            NavigationStack { SessionSnippetPicker(session: session) }
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSFTP) {
            NavigationStack { SFTPBrowserView(host: session.host, certificates: certificates, hosts: hosts) }
        }
        .sheet(item: $editingHost) { host in
            NavigationStack { HostEditorView(host: host) }
        }
        .confirmationDialog("Farbschema", isPresented: $showThemes) {
            ForEach(TerminalTheme.all) { theme in
                Button(theme.name) {
                    TerminalThemeStore.select(theme)
                    for s in sessions.sessions { TerminalThemeStore.apply(theme, to: s.terminalView) }
                }
            }
        }
    }

    // MARK: Schwebende Glas-Leiste

    private var topBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    sessions.presented = nil
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 40, height: 40)
                }
                .glassEffect(.regular.interactive(), in: .circle)

                HStack(spacing: 8) {
                    StatusDot(state: session.state)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(session.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Text(session.activeTransport.label).fontWeight(.semibold)
                            Text(session.host.address)
                        }
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .glassEffect(.regular, in: .capsule)

                Button {
                    sessions.showClaude = true
                } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 40, height: 40)
                }
                .glassEffect(.regular.tint(Theme.accent.opacity(0.25)).interactive(), in: .circle)

                Menu {
                    Button("Snippets", systemImage: "text.badge.plus") { showSnippets = true }
                    Button("Dateien (SFTP)", systemImage: "folder") { showSFTP = true }
                    Button("Host bearbeiten", systemImage: "pencil") {
                        editingHost = hosts.hosts.first { $0.id == session.host.id } ?? session.host
                    }
                    Divider()
                    Button("Neu verbinden", systemImage: "arrow.clockwise") { session.reconnect() }
                    Button("Schrift größer", systemImage: "textformat.size.larger") { fontSize = min(fontSize + 1, TerminalScreen.maxFontSize) }
                    Button("Schrift kleiner", systemImage: "textformat.size.smaller") { fontSize = max(fontSize - 1, TerminalScreen.minFontSize) }
                    Button("Farbschema", systemImage: "paintpalette") { showThemes = true }
                    Divider()
                    Button("Trennen", systemImage: "xmark.circle", role: .destructive) { sessions.close(session) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 40, height: 40)
                }
                .glassEffect(.regular.interactive(), in: .circle)
            }
        }
    }

    // MARK: Status während Aufbau oder nach Fehler

    @ViewBuilder
    private var statusOverlay: some View {
        VStack(spacing: 14) {
            switch session.state {
            case .renewingCertificate, .connecting, .idle:
                ProgressView().controlSize(.large)
                Text(session.state.label).font(.headline)
                if let detail = session.connectingDetail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.orange)
                Text("Verbindung fehlgeschlagen").font(.headline)
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                retryButtons
            case .closed:
                Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                Text("Verbindung getrennt").font(.headline)
                retryButtons
            case .connected:
                EmptyView()
            }
        }
        .padding(22)
        .frame(maxWidth: 420)
        .glassCard(cornerRadius: 26)
    }

    private var retryButtons: some View {
        HStack {
            Button("Schließen") { sessions.close(session) }
                .glassButton()
            Button("Erneut verbinden", systemImage: "arrow.clockwise") { session.reconnect() }
                .glassProminentButton()
        }
        .padding(.top, 4)
    }
}

/// Reiter für alle offenen Sessions (iPhone und iPad).
struct SessionTabs: View {
    @EnvironmentObject private var sessions: SessionManager

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(sessions.sessions) { s in
                        SessionTab(session: s, selected: s.id == sessions.presented?.id)
                            .onTapGesture { sessions.presented = s }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .frame(height: 36)
    }
}

struct SessionTab: View {
    @ObservedObject var session: TerminalSession
    let selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(state: session.state).scaleEffect(0.8)
            Text(session.host.displayName)
                .font(.caption.weight(selected ? .semibold : .regular))
                .lineLimit(1)
            ApprovalIndicator(agent: session.claude)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .glassEffect(selected ? .regular.tint(session.host.color.color.opacity(0.35)).interactive() : .regular.interactive(), in: .capsule)
    }
}

/// Hinweis unten im Terminal, wenn Claude auf eine Freigabe wartet und das Panel zu ist.
struct ApprovalBanner: View {
    @ObservedObject var agent: ClaudeAgent
    @EnvironmentObject private var sessions: SessionManager

    var body: some View {
        if let pending = agent.pending, !sessions.showClaude {
            VStack {
                Spacer()
                Button {
                    sessions.showClaude = true
                } label: {
                    Label("Claude wartet auf Freigabe: \(pending.summary)", systemImage: "hand.raised.fill")
                        .lineLimit(1)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 12)
                }
                .glassEffect(.regular.tint(.orange.opacity(0.3)).interactive(), in: .capsule)
                .padding(.bottom, 12)
            }
            .padding(.horizontal, 16)
        }
    }
}

struct ApprovalIndicator: View {
    @ObservedObject var agent: ClaudeAgent

    var body: some View {
        if agent.pending != nil {
            Image(systemName: "hand.raised.fill").font(.caption2).foregroundStyle(.orange)
        }
    }
}
