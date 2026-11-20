import SwiftUI

/// Auswahl eines NetBird-Peers als Ziel für einen Host.
struct NetBirdPeerPicker: View {
    @ObservedObject private var nb = NetBirdManager.shared
    @Environment(\.dismiss) private var dismiss
    let onPick: (NetBirdManager.Peer) -> Void

    @State private var search = ""
    @State private var error: String?

    private var filtered: [NetBirdManager.Peer] {
        let q = search.trimmed.lowercased()
        guard !q.isEmpty else { return nb.peers }
        return nb.peers.filter { $0.fqdn.lowercased().contains(q) || $0.ip.contains(q) }
    }

    var body: some View {
        List {
            switch nb.state {
            case .starting:
                HStack { ProgressView(); Text("NetBird startet …") }
            case .running:
                if nb.peers.isEmpty {
                    Text("Keine Peers sichtbar. Prüfe die Zugriffsrichtlinien in NetBird.")
                        .foregroundStyle(.secondary)
                }
                ForEach(filtered) { peer in
                    Button {
                        onPick(peer)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "circle.fill")
                                .font(.caption2)
                                .foregroundStyle(peer.status.lowercased() == "connected" ? .green : .secondary)
                            VStack(alignment: .leading) {
                                Text(peer.fqdn.split(separator: ".").first.map(String.init) ?? peer.fqdn)
                                Text("\(peer.fqdn) · \(peer.ip)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            default:
                Button("NetBird starten und Peers laden", systemImage: "point.3.connected.trianglepath.dotted") {
                    Task { await load() }
                }
                if case .failed(let message) = nb.state {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .searchable(text: $search, prompt: "Peer suchen")
        .refreshable { nb.refreshPeers() }
        .navigationTitle("NetBird-Peer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Abbrechen", systemImage: "xmark") { dismiss() }
            }
        }
        .task {
            if nb.state == .running { nb.refreshPeers() } else if nb.state != .starting { await load() }
        }
        .onDisappear { nb.stopIfUnused() }
    }

    private func load() async {
        error = nil
        do {
            try await nb.ensureOverlay()
            nb.refreshPeers()
        } catch {
            self.error = NetBirdManager.describe(error)
        }
    }
}
