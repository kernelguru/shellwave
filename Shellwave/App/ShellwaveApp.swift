import MoshKit
import SwiftUI

@main
struct ShellwaveApp: App {
    @StateObject private var hosts: HostStore
    @StateObject private var ucm: UCMSettings
    @StateObject private var certificates: CertificateManager
    @StateObject private var sessions: SessionManager
    @StateObject private var snippets: SnippetStore
    @StateObject private var setup: ServerSetup
    @StateObject private var claudeSettings = ClaudeSettings.shared

    init() {
        MoshRunner.prepareLocale(bundlePath: Bundle.main.path(forResource: "locales", ofType: "bundle"))
        let hosts = HostStore()
        let ucm = UCMSettings()
        let certificates = CertificateManager(settings: ucm)
        _hosts = StateObject(wrappedValue: hosts)
        _ucm = StateObject(wrappedValue: ucm)
        _certificates = StateObject(wrappedValue: certificates)
        _sessions = StateObject(wrappedValue: SessionManager(certificates: certificates, hosts: hosts))
        _snippets = StateObject(wrappedValue: SnippetStore())
        _setup = StateObject(wrappedValue: ServerSetup(ucm: ucm, certificates: certificates, hosts: hosts))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(hosts)
                .environmentObject(ucm)
                .environmentObject(certificates)
                .environmentObject(sessions)
                .environmentObject(snippets)
                .environmentObject(setup)
                .environmentObject(claudeSettings)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onOpenURL { sessions.handle(url: $0) }
        }
    }
}

/// Offene Sessions; eine pro Host, damit man zurückspringen kann, ohne neu zu verbinden.
@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var sessions: [TerminalSession] = []
    @Published var presented: TerminalSession?
    /// Claude-Panel der angezeigten Session öffnen (z. B. aus dem Dynamic Island).
    @Published var showClaude = false

    let keepAlive = KeepAliveManager()
    private let liveActivities = LiveActivityManager()
    private let certificates: CertificateManager
    private let hosts: HostStore

    init(certificates: CertificateManager, hosts: HostStore) {
        self.certificates = certificates
        self.hosts = hosts
        liveActivities.endAll()
        keepAlive.onAuthorizationChange = { [weak self] in self?.refreshKeepAlive() }
    }

    func open(_ host: Host) {
        let current = hosts.hosts.first { $0.id == host.id } ?? host
        if let existing = sessions.first(where: { $0.host.id == current.id }) {
            if !existing.state.isActive { existing.reconnect() }
            presented = existing
            return
        }
        let session = TerminalSession(host: current, certificates: certificates, hosts: hosts)
        session.onStateChange = { [weak self] s in self?.stateChanged(s) }
        sessions.append(session)
        presented = session
        session.start()
    }

    func close(_ session: TerminalSession) {
        session.claude.stop()
        session.disconnect()
        liveActivities.end(session)
        sessions.removeAll { $0.id == session.id }
        if presented?.id == session.id { presented = sessions.last }
        refreshKeepAlive()
    }

    func session(for host: Host) -> TerminalSession? {
        sessions.first { $0.host.id == host.id }
    }

    // MARK: Deep Links (Live Activity)

    func handle(url: URL) {
        guard url.scheme == "shellwave", let host = url.host() else { return }
        let id = url.pathComponents.dropFirst().first ?? ""
        guard let uuid = UUID(uuidString: id), let target = hosts.hosts.first(where: { $0.id == uuid }) else { return }
        switch host {
        case "session":
            open(target)
        case "approve":
            open(target)
            showClaude = true
        default:
            break
        }
    }

    // MARK: Status → Live Activity und Keep-alive

    private func stateChanged(_ session: TerminalSession) {
        wireClaude(session)
        liveActivities.update(for: session, pendingApproval: session.claude.pending != nil, summary: session.claude.pending?.summary)
        refreshKeepAlive()
    }

    private func wireClaude(_ session: TerminalSession) {
        session.claude.onApprovalChange = { [weak self, weak session] request in
            guard let self, let session else { return }
            self.liveActivities.update(for: session, pendingApproval: request != nil, summary: request.map { "\($0.tool): \($0.summary)" })
            if request != nil { Haptics.warning() }
        }
    }

    func refreshKeepAlive() {
        let needed = sessions.contains { $0.host.keepAlive && $0.state.isActive }
        keepAlive.update(needed: needed)
    }
}

enum Haptics {
    @MainActor static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

struct RootView: View {
    @EnvironmentObject private var sessions: SessionManager

    var body: some View {
        TabView {
            Tab("Hosts", systemImage: "server.rack") {
                NavigationStack { HostListView() }
            }
            Tab("Snippets", systemImage: "text.badge.plus") {
                NavigationStack { SnippetListView() }
            }
            Tab("Zertifikate", systemImage: "checkmark.seal") {
                NavigationStack { CertificatesView() }
            }
            Tab("Einstellungen", systemImage: "gearshape") {
                NavigationStack { SettingsView() }
            }
        }
        .minimizingTabBar()
        .fullScreenCover(item: $sessions.presented) { session in
            SessionView(session: session)
        }
    }
}
