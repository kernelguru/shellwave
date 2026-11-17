import SwiftUI

@main
struct ShellwaveApp: App {
    @StateObject private var hosts: HostStore
    @StateObject private var ucm: UCMSettings
    @StateObject private var certificates: CertificateManager
    @StateObject private var sessions: SessionManager

    init() {
        let hosts = HostStore()
        let ucm = UCMSettings()
        let certificates = CertificateManager(settings: ucm)
        _hosts = StateObject(wrappedValue: hosts)
        _ucm = StateObject(wrappedValue: ucm)
        _certificates = StateObject(wrappedValue: certificates)
        _sessions = StateObject(wrappedValue: SessionManager(certificates: certificates, hosts: hosts))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(hosts)
                .environmentObject(ucm)
                .environmentObject(certificates)
                .environmentObject(sessions)
                .preferredColorScheme(.dark)
                .tint(Theme.mint)
        }
    }
}

/// Offene Sessions; eine pro Host, damit man zurückspringen kann, ohne neu zu verbinden.
@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var sessions: [TerminalSession] = []
    @Published var presented: TerminalSession?

    private let certificates: CertificateManager
    private let hosts: HostStore

    init(certificates: CertificateManager, hosts: HostStore) {
        self.certificates = certificates
        self.hosts = hosts
    }

    func open(_ host: Host) {
        if let existing = sessions.first(where: { $0.host.id == host.id }) {
            if case .failed = existing.state { existing.reconnect() }
            if existing.state == .closed { existing.reconnect() }
            presented = existing
            return
        }
        let session = TerminalSession(host: host, certificates: certificates, hosts: hosts)
        sessions.append(session)
        presented = session
        session.start()
    }

    func close(_ session: TerminalSession) {
        session.disconnect()
        sessions.removeAll { $0.id == session.id }
        if presented?.id == session.id { presented = nil }
    }

    func session(for host: Host) -> TerminalSession? {
        sessions.first { $0.host.id == host.id }
    }
}

struct RootView: View {
    @EnvironmentObject private var sessions: SessionManager

    var body: some View {
        TabView {
            Tab("Hosts", systemImage: "server.rack") {
                NavigationStack { HostListView() }
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
