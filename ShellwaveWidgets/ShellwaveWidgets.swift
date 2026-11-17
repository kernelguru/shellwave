import ActivityKit
import SwiftUI
import WidgetKit

@main
struct ShellwaveWidgets: WidgetBundle {
    var body: some Widget {
        SessionLiveActivity()
    }
}

struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color(red: 0.03, green: 0.12, blue: 0.14).opacity(0.85))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(url(for: context))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.attributes.hostName).font(.headline).lineLimit(1)
                    } icon: {
                        Image(systemName: "terminal.fill").foregroundStyle(hostColor(context))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.startedAt, style: .timer)
                        .font(.headline.monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 70)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.pendingApproval {
                        Link(destination: approvalURL(for: context)) {
                            HStack {
                                Image(systemName: "hand.raised.fill")
                                Text(context.state.approvalSummary ?? "Claude wartet auf Freigabe")
                                    .lineLimit(1)
                                Spacer()
                                Text("Prüfen").fontWeight(.semibold)
                            }
                            .padding(10)
                            .background(.orange.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
                        }
                    } else {
                        HStack {
                            StatusBadge(status: context.state.status)
                            Text(context.state.transport).font(.caption.weight(.semibold))
                            Spacer()
                            Text(context.attributes.address)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.pendingApproval ? "hand.raised.fill" : "terminal.fill")
                    .foregroundStyle(context.state.pendingApproval ? .orange : hostColor(context))
            } compactTrailing: {
                if context.state.pendingApproval {
                    Text("Claude").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                } else {
                    Text(context.state.startedAt, style: .timer)
                        .font(.caption2.monospacedDigit())
                        .frame(maxWidth: 44)
                }
            } minimal: {
                Image(systemName: context.state.pendingApproval ? "hand.raised.fill" : "terminal.fill")
                    .foregroundStyle(context.state.pendingApproval ? .orange : hostColor(context))
            }
            .widgetURL(url(for: context))
            .keylineTint(hostColor(context))
        }
    }

    private func url(for context: ActivityViewContext<SessionActivityAttributes>) -> URL {
        URL(string: "shellwave://session/\(context.attributes.hostID)")!
    }

    private func approvalURL(for context: ActivityViewContext<SessionActivityAttributes>) -> URL {
        URL(string: "shellwave://approve/\(context.attributes.hostID)")!
    }

    private func hostColor(_ context: ActivityViewContext<SessionActivityAttributes>) -> Color {
        Color(hex: context.attributes.colorHex)
    }
}

struct LockScreenView: View {
    let context: ActivityViewContext<SessionActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: context.state.pendingApproval ? "hand.raised.fill" : "terminal.fill")
                .font(.title2)
                .foregroundStyle(context.state.pendingApproval ? .orange : Color(hex: context.attributes.colorHex))
            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.hostName).font(.headline)
                if context.state.pendingApproval {
                    Text(context.state.approvalSummary ?? "Claude wartet auf Freigabe")
                        .font(.caption)
                        .lineLimit(2)
                } else {
                    HStack(spacing: 6) {
                        StatusBadge(status: context.state.status)
                        Text("\(context.state.transport) · \(context.attributes.address)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            Text(context.state.startedAt, style: .timer)
                .font(.title3.monospacedDigit())
                .frame(maxWidth: 80)
                .multilineTextAlignment(.trailing)
        }
        .padding(16)
    }
}

struct StatusBadge: View {
    let status: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption2.weight(.medium))
        }
    }

    private var color: Color {
        switch status {
        case "connected": return .green
        case "connecting": return .yellow
        case "failed": return .red
        default: return .gray
        }
    }

    private var label: String {
        switch status {
        case "connected": return "Verbunden"
        case "connecting": return "Verbinde"
        case "failed": return "Fehler"
        default: return "Getrennt"
        }
    }
}

extension Color {
    init(hex: String) {
        let v = UInt32(hex, radix: 16) ?? 0x73F2CC
        self.init(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}
