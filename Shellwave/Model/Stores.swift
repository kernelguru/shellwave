import Foundation
import SwiftUI

/// Liest und schreibt kleine JSON-Dateien im Application-Support-Ordner.
enum JSONFile {
    static var directory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shellwave", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        let url = directory.appendingPathComponent(name)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

@MainActor
final class HostStore: ObservableObject {
    @Published private(set) var hosts: [Host] = []

    init() {
        hosts = JSONFile.load([Host].self, from: "hosts.json") ?? []
    }

    func upsert(_ host: Host) {
        if let idx = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[idx] = host
        } else {
            hosts.append(host)
        }
        persist()
    }

    func delete(_ host: Host) {
        host.password = ""
        hosts.removeAll { $0.id == host.id }
        persist()
    }

    func learnHostKey(_ key: String, for id: UUID) {
        guard let idx = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[idx].knownHostKey = key
        persist()
    }

    /// Merkt sich das erkannte Betriebssystem (nur speichern, wenn es sich geändert hat).
    func learnOS(_ os: HostOS, for id: UUID) {
        guard let idx = hosts.firstIndex(where: { $0.id == id }), hosts[idx].os != os else { return }
        hosts[idx].os = os
        persist()
    }

    func forgetHostKey(for id: UUID) {
        guard let idx = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[idx].knownHostKey = nil
        persist()
    }

    private func persist() {
        JSONFile.save(hosts, to: "hosts.json")
    }
}

/// UCM-Verbindung und Zertifikats-Vorgaben.
@MainActor
final class UCMSettings: ObservableObject {
    @AppStorage("ucm.server") var server: String = ""
    @AppStorage("ucm.pinnedFingerprint") var pinnedFingerprint: String = ""
    @AppStorage("ucm.caID") var caID: Int = 0
    /// Laufzeit neuer Zertifikate in Sekunden (Standard 12 Stunden).
    @AppStorage("ucm.validity") var validitySeconds: Int = 12 * 3600
    @Published var apiKey: String = KeychainStore.string(service: "ucm", account: "apikey")

    var isConfigured: Bool { !server.trimmed.isEmpty && !apiKey.isEmpty && caID > 0 }

    func saveAPIKey(_ key: String) {
        apiKey = key.trimmed
        KeychainStore.setString(apiKey, service: "ucm", account: "apikey")
    }

    func client() throws -> UCMClient {
        try UCMClient(server: server, apiKey: apiKey, pinnedFingerprint: pinnedFingerprint)
    }
}
