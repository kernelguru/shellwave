import ActivityKit
import Foundation

/// Eine Live Activity pro laufender Session (Dynamic Island und Sperrbildschirm).
@MainActor
final class LiveActivityManager {
    private var activities: [UUID: Activity<SessionActivityAttributes>] = [:]

    var enabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
            && (UserDefaults.standard.object(forKey: "liveActivity.enabled") as? Bool ?? true)
    }

    func update(for session: TerminalSession, pendingApproval: Bool = false, summary: String? = nil) {
        let state = SessionActivityAttributes.ContentState(
            status: Self.status(session.state),
            transport: session.activeTransport.label,
            startedAt: session.startedAt,
            pendingApproval: pendingApproval,
            approvalSummary: summary
        )

        if let activity = activities[session.id] {
            if case .closed = session.state {
                end(session)
                return
            }
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
            return
        }

        guard enabled, session.state.isActive else { return }
        let attributes = SessionActivityAttributes(
            hostID: session.host.id.uuidString,
            hostName: session.host.displayName,
            address: session.host.address,
            colorHex: session.host.color.hex
        )
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            activities[session.id] = activity
        } catch {
            // Live Activities deaktiviert oder Limit erreicht – kein Fehler für die Session.
        }
    }

    func end(_ session: TerminalSession) {
        guard let activity = activities.removeValue(forKey: session.id) else { return }
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    func endAll() {
        for activity in Activity<SessionActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        activities.removeAll()
    }

    private static func status(_ state: TerminalSession.State) -> String {
        switch state {
        case .connected: return "connected"
        case .connecting, .renewingCertificate, .idle: return "connecting"
        case .failed: return "failed"
        case .closed: return "closed"
        }
    }
}
