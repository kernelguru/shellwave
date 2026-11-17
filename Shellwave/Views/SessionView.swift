import SwiftUI

struct SessionView: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject private var sessions: SessionManager
    @AppStorage("terminal.fontSize") private var fontSize: Double = 13

    var body: some View {
        ZStack(alignment: .top) {
            Color(red: 0.02, green: 0.06, blue: 0.07).ignoresSafeArea()

            TerminalScreen(session: session, fontSize: fontSize)
                .padding(.top, 56)
                .padding(.horizontal, 4)

            topBar
                .padding(.horizontal, 12)
                .padding(.top, 4)

            if session.state != .connected {
                statusOverlay
                    .padding(.top, 120)
                    .padding(.horizontal, 24)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.smooth, value: session.state)
        .sensoryFeedback(trigger: session.state) { _, new in
            switch new {
            case .connected: return .success
            case .failed: return .error
            default: return nil
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
                        Text(session.host.address)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .glassEffect(.regular, in: .capsule)

                Menu {
                    Button("Neu verbinden", systemImage: "arrow.clockwise") { session.reconnect() }
                    Button("Schrift größer", systemImage: "textformat.size.larger") { fontSize = min(fontSize + 1, 24) }
                    Button("Schrift kleiner", systemImage: "textformat.size.smaller") { fontSize = max(fontSize - 1, 8) }
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
