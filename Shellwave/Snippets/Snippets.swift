import Citadel
import Foundation

struct Snippet: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String = ""
    /// Befehl mit Platzhaltern `{{name}}`
    var command: String = ""
    var tags: [String] = []
    /// Leer = für alle Hosts sichtbar
    var hostIDs: [UUID] = []

    /// Platzhalter in Reihenfolge ihres ersten Auftretens.
    var variables: [String] {
        var seen: [String] = []
        var rest = command[...]
        while let open = rest.range(of: "{{"), let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) {
            let name = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            let valid = !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
            if valid, !seen.contains(name) { seen.append(name) }
            rest = rest[close.upperBound...]
        }
        return seen
    }

    func render(_ values: [String: String]) -> String {
        var out = command
        for name in variables {
            let value = values[name] ?? ""
            out = out.replacingOccurrences(of: "{{\(name)}}", with: value)
            out = out.replacingOccurrences(of: "{{ \(name) }}", with: value)
        }
        return out
    }

    func applies(to host: Host) -> Bool {
        hostIDs.isEmpty || hostIDs.contains(host.id)
    }
}

@MainActor
final class SnippetStore: ObservableObject {
    @Published private(set) var snippets: [Snippet] = []

    init() {
        snippets = JSONFile.load([Snippet].self, from: "snippets.json") ?? Self.defaults
    }

    func upsert(_ snippet: Snippet) {
        if let i = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[i] = snippet
        } else {
            snippets.append(snippet)
        }
        persist()
    }

    func delete(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        persist()
    }

    func replaceAll(_ list: [Snippet]) {
        snippets = list
        persist()
    }

    private func persist() {
        JSONFile.save(snippets, to: "snippets.json")
    }

    static let defaults: [Snippet] = [
        Snippet(title: "Speicher & Last", command: "uptime; free -h; df -h /", tags: ["system"]),
        Snippet(title: "Docker-Container", command: "docker ps --format 'table {{.Names}}\\t{{.Status}}\\t{{.Image}}'", tags: ["docker"]),
        Snippet(title: "Container-Logs", command: "docker logs --tail 100 -f {{container}}", tags: ["docker"]),
        Snippet(title: "Dienst neu starten", command: "sudo systemctl restart {{dienst}} && systemctl status {{dienst}} --no-pager", tags: ["system"]),
    ]
}

/// Führt einen Befehl auf mehreren Hosts gleichzeitig aus.
@MainActor
final class SnippetRunner: ObservableObject {
    struct Result: Identifiable {
        let id: UUID
        let hostName: String
        var running = true
        var output = ""
        var exitCode: Int?
    }

    @Published private(set) var results: [Result] = []

    func run(_ command: String, on targets: [Host], certificates: CertificateManager, hosts: HostStore) async {
        results = targets.map { Result(id: $0.id, hostName: $0.displayName) }
        await withTaskGroup(of: Void.self) { group in
            for host in targets {
                group.addTask { @MainActor in
                    do {
                        let client = try await SSHConnector.connect(to: host, certificates: certificates, hosts: hosts)
                        let r = try await SSHConnector.runCapturing(command, on: client)
                        try? await client.close()
                        self.finish(host.id, output: r.output, code: r.exitCode)
                    } catch {
                        self.finish(host.id, output: TerminalSession.describe(error), code: -1)
                    }
                }
            }
        }
    }

    private func finish(_ id: UUID, output: String, code: Int) {
        guard let i = results.firstIndex(where: { $0.id == id }) else { return }
        results[i].running = false
        results[i].output = ANSIStripper.strip(output)
        results[i].exitCode = code
    }
}
