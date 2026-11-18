import SwiftUI

/// Chat mit Claude zur aktuellen Session, als Sheet über dem Terminal.
struct ClaudePanel: View {
    @ObservedObject var agent: ClaudeAgent
    @ObservedObject private var settings = ClaudeSettings.shared
    @State private var input = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if agent.items.isEmpty {
                            emptyHint
                        }
                        ForEach(agent.items) { item in
                            ChatRow(item: item).id(item.id)
                        }
                        if agent.status == .working {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("\(assistantName) arbeitet …").font(.footnote).foregroundStyle(.secondary)
                            }
                            .id("working")
                        }
                    }
                    .padding(16)
                }
                .onChange(of: agent.items.count) {
                    withAnimation { proxy.scrollTo(agent.items.last?.id, anchor: .bottom) }
                }
            }

            if let request = agent.pending {
                ApprovalCard(request: request) { allow in
                    Task { await agent.approve(allow) }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            inputBar
        }
        .animation(.smooth, value: agent.pending)
        .background(AppBackground())
        .sensoryFeedback(.warning, trigger: agent.pending?.id)
    }

    private var header: some View {
        HStack {
            Label(assistantName, systemImage: "sparkles")
                .font(.headline)
            statusText
            Spacer()
            Menu {
                Picker("Modus", selection: Binding(get: { settings.mode }, set: { settings.mode = $0 })) {
                    ForEach(ClaudeMode.allCases) { Text($0.label).tag($0) }
                }
                if settings.mode == .api {
                    Picker("Anbieter", selection: Binding(get: { settings.apiProvider }, set: { settings.apiProvider = $0 })) {
                        ForEach(APIProvider.allCases) { Text($0.label).tag($0) }
                    }
                }
                Button("Neue Unterhaltung", systemImage: "arrow.counterclockwise") { agent.reset() }
                if agent.status == .working {
                    Button("Unterbrechen", systemImage: "stop.circle") { agent.interrupt() }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var statusText: some View {
        switch agent.status {
        case .connecting: Text("verbinde …").font(.caption).foregroundStyle(.secondary)
        case .failed: Text("Fehler").font(.caption).foregroundStyle(.red)
        default: Text(modeText).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var usesGemini: Bool { settings.mode == .api && settings.apiProvider == .google }
    private var assistantName: String {
        guard settings.mode == .api else { return "Claude" }
        switch settings.apiProvider {
        case .anthropic: return "Claude"
        case .google: return "Gemini"
        case .openAICompatible: return "Assistent"
        }
    }
    private var modeText: String {
        switch settings.mode {
        case .claudeCode: return "Claude Code"
        case .api:
            switch settings.apiProvider {
            case .anthropic: return "Claude-API"
            case .google: return "Gemini-API"
            case .openAICompatible: return settings.openAIModel
            }
        }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Frag \(assistantName) nach diesem Server.").font(.subheadline.weight(.semibold))
            Text("Zum Beispiel: „Warum startet der Jellyfin-Container nicht?“ oder „Installiere htop und zeig mir die Last.“ Lesende Befehle laufen direkt, alles andere wartet auf deine Freigabe.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .glassCard(cornerRadius: 18)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Nachricht an \(assistantName)", text: $input, axis: .vertical)
                .lineLimit(1...5)
                .focused($focused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
            Button {
                agent.send(input)
                input = ""
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(input.trimmed.isEmpty || agent.status == .connecting)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

struct ChatRow: View {
    let item: ChatItem
    @State private var expanded = false

    var body: some View {
        switch item.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .padding(12)
                    .background(Theme.teal.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
                    .textSelection(.enabled)
            }
        case .assistant(let text):
            Text(LocalizedStringKey(text))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(cornerRadius: 16)
                .textSelection(.enabled)
        case .tool(let name, let summary, let output, let done, let failed):
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        if !done { ProgressView().controlSize(.mini) }
                        else {
                            Image(systemName: failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(failed ? .orange : .green)
                        }
                        Text(name).font(.caption.weight(.semibold))
                        Text(summary)
                            .font(.caption.monospaced())
                            .lineLimit(expanded ? nil : 1)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if !output.isEmpty {
                            Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2)
                        }
                    }
                }
                .tint(.primary)
                if expanded, !output.isEmpty {
                    ScrollView(.horizontal) {
                        Text(output)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 240)
                }
            }
            .padding(10)
            .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
        case .notice(let text):
            Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        case .error(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
    }
}

struct ApprovalCard: View {
    let request: ApprovalRequest
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Freigabe nötig: \(request.tool)", systemImage: "hand.raised.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            ScrollView {
                Text(request.detail)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 160)
            HStack {
                Button("Ablehnen", role: .destructive) { decide(false) }
                    .glassButton()
                Spacer()
                Button("Erlauben", systemImage: "checkmark") { decide(true) }
                    .glassProminentButton()
            }
        }
        .padding(14)
        .glassEffect(.regular.tint(.orange.opacity(0.18)), in: .rect(cornerRadius: 20))
    }
}
