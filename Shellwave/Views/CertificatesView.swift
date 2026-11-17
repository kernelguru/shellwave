import SwiftUI
import UniformTypeIdentifiers

struct CertificatesView: View {
    @EnvironmentObject private var certificates: CertificateManager
    @EnvironmentObject private var ucm: UCMSettings
    @EnvironmentObject private var hosts: HostStore

    @State private var showImporter = false
    @State private var pasteText = ""
    @State private var showPaste = false
    @State private var message: String?
    @State private var busy = false

    private var sorted: [(slot: String, cert: StoredCertificate)] {
        certificates.certificates.map { ($0.key, $0.value) }.sorted { $0.cert.validBefore > $1.cert.validBefore }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if sorted.isEmpty {
                    GlassCard(title: "Noch keine Zertifikate", systemImage: "checkmark.seal") {
                        Text(ucm.isConfigured
                             ? "Beim ersten Verbinden zu einem Host mit UCM-Anmeldung holt die App automatisch eines."
                             : "Richte UCM in den Einstellungen ein oder importiere ein extern signiertes Zertifikat.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(sorted, id: \.slot) { item in
                    CertificateCard(cert: item.cert)
                        .contextMenu {
                            if !item.cert.manual {
                                Button("Jetzt erneuern", systemImage: "arrow.clockwise") {
                                    Task { await renew(item.cert.principals) }
                                }
                            }
                            Button("Zeile kopieren", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = item.cert.line
                            }
                            Button("Entfernen", systemImage: "trash", role: .destructive) {
                                certificates.remove(slot: item.slot)
                            }
                        }
                }

                if ucm.isConfigured, !hosts.hosts.isEmpty {
                    Button {
                        Task { await renewAll() }
                    } label: {
                        Label(busy ? "Erneuere …" : "Alle Hosts jetzt erneuern", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .glassProminentButton()
                    .disabled(busy)
                }

                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(16)
        }
        .appBackground()
        .navigationTitle("Zertifikate")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Aus Datei (-cert.pub)", systemImage: "doc") { showImporter = true }
                    Button("Aus Zwischenablage", systemImage: "doc.on.clipboard") {
                        importText(UIPasteboard.general.string ?? "")
                    }
                    Button("Einfügen …", systemImage: "text.cursor") { showPaste = true }
                } label: {
                    Label("Importieren", systemImage: "square.and.arrow.down")
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.plainText, .data, .item]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            importText((try? String(contentsOf: url, encoding: .utf8)) ?? "")
        }
        .alert("Zertifikat einfügen", isPresented: $showPaste) {
            TextField("ssh-ed25519-cert-v01@openssh.com …", text: $pasteText)
            Button("Importieren") { importText(pasteText); pasteText = "" }
            Button("Abbrechen", role: .cancel) { pasteText = "" }
        }
    }

    private func importText(_ text: String) {
        do {
            let cert = try certificates.importManual(text)
            message = "Importiert: \(cert.keyID), gültig bis \(cert.validBefore.formatted(date: .abbreviated, time: .shortened))."
        } catch {
            message = error.localizedDescription
        }
    }

    private func renew(_ principals: [String]) async {
        do {
            try await certificates.renew(principals: principals)
            message = "Zertifikat erneuert."
        } catch {
            message = error.localizedDescription
        }
    }

    private func renewAll() async {
        busy = true
        defer { busy = false }
        let sets = Set(hosts.hosts.filter { $0.auth == .certificate }.map { $0.effectivePrincipals.sorted() })
        var failures: [String] = []
        for principals in sets {
            do { try await certificates.renew(principals: principals) } catch { failures.append(error.localizedDescription) }
        }
        message = failures.isEmpty ? "\(sets.count) Zertifikat(e) erneuert." : failures.joined(separator: "\n")
    }
}

struct CertificateCard: View {
    let cert: StoredCertificate

    private var remaining: String {
        if cert.validBefore == .distantFuture { return "unbegrenzt" }
        let left = cert.validBefore.timeIntervalSinceNow
        if left <= 0 { return "abgelaufen" }
        let f = DateComponentsFormatter()
        f.allowedUnits = left > 86400 ? [.day, .hour] : [.hour, .minute]
        f.unitsStyle = .abbreviated
        return "noch " + (f.string(from: left) ?? "")
    }

    private var progress: Double {
        let total = cert.validBefore.timeIntervalSince(cert.validAfter)
        guard total > 0, cert.validBefore != .distantFuture else { return 1 }
        return max(0, min(1, cert.validBefore.timeIntervalSinceNow / total))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(cert.keyID.isEmpty ? "Zertifikat" : cert.keyID, systemImage: cert.manual ? "doc.badge.arrow.up" : "checkmark.seal.fill")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(cert.manual ? "manuell" : "UCM")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.white.opacity(0.08), in: Capsule())
            }
            Text(cert.principals.joined(separator: ", "))
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
            ProgressView(value: progress)
                .tint(progress > 0.2 ? Theme.mint : .orange)
            Text(remaining)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .glassCard(cornerRadius: 22)
    }
}
