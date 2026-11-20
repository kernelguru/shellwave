import Citadel
import Foundation
import NIOCore
import NIOSSH

/// Baut SSH-Verbindungen zu einem Host auf – mit Zertifikat, Geräte-Key oder Passwort.
/// Wird von Terminal, Mosh-Bootstrap, Auto-Install, Snippets, Claude und SFTP genutzt.
@MainActor
enum SSHConnector {
    /// Anmeldeart, die von der Host-Einstellung abweichen kann (z. B. Passwort beim Einrichten).
    enum AuthOverride {
        case password(String)
        case deviceKey
    }

    static func connect(
        to host: Host,
        certificates: CertificateManager,
        hosts: HostStore,
        override: AuthOverride? = nil,
        username: String? = nil,
        progress: ((String) -> Void)? = nil
    ) async throws -> SSHClient {
        if host.isNetBird {
            return try await NetBirdManager.shared.connectSSH(host: host, username: username ?? host.username, progress: progress)
        }
        let auth = try await authentication(for: host, certificates: certificates, override: override, username: username)
        let hostID = host.id
        // Immer den aktuell gespeicherten Host-Key nehmen (die Session hält evtl. eine ältere Kopie).
        let known = hosts.hosts.first { $0.id == hostID }?.knownHostKey ?? host.knownHostKey
        let validator = TOFUHostKeyValidator(known: known) { key in
            Task { @MainActor in hosts.learnHostKey(key, for: hostID) }
        }
        var settings = SSHClientSettings(
            host: host.hostname,
            port: host.port,
            authenticationMethod: { auth() },
            hostKeyValidator: .custom(validator)
        )
        settings.connectTimeout = .seconds(15)
        return try await SSHClient.connect(to: settings)
    }

    static func authentication(
        for host: Host,
        certificates: CertificateManager,
        override: AuthOverride? = nil,
        username: String? = nil
    ) async throws -> @Sendable () -> SSHAuthenticationMethod {
        let user = username ?? host.username
        if let override {
            switch override {
            case .password(let pw):
                return { .passwordBased(username: user, password: pw) }
            case .deviceKey:
                let key = DeviceKey.shared.privateKey
                return { .ed25519(username: user, privateKey: key) }
            }
        }
        switch host.auth {
        case .password:
            let password = host.password
            guard !password.isEmpty else { throw SSHConnectError.missingPassword }
            return { .passwordBased(username: user, password: password) }
        case .key:
            let key = DeviceKey.shared.privateKey
            return { .ed25519(username: user, privateKey: key) }
        case .certificate:
            let cert = try await certificates.certificate(for: host.effectivePrincipals)
            guard let certified = cert.parsed else { throw CertificateError.invalidCertificate }
            let key = DeviceKey.shared.privateKey
            return { .custom(CertificateAuthDelegate(username: user, privateKey: key, certifiedKey: certified)) }
        }
    }

    /// Verbindung für Nebenaufgaben (SFTP, Snippets, Claude). Bei NetBird-Hosts wird die
    /// Verbindung einer offenen Terminal-Sitzung mitbenutzt (kein neuer Login nötig).
    static func lease(
        to host: Host,
        certificates: CertificateManager,
        hosts: HostStore
    ) async throws -> SSHLease {
        if host.isNetBird, let shared = SharedConnections.shared.client(for: host.id) {
            return SSHLease(client: shared, owned: false)
        }
        let client = try await connect(to: host, certificates: certificates, hosts: hosts)
        return SSHLease(client: client, owned: true)
    }

    /// Führt einen Befehl aus und liefert stdout+stderr als Text. Wirft bei Exit-Code ≠ 0 nicht,
    /// sondern liefert den Code mit.
    static func run(_ command: String, on client: SSHClient) async throws -> (output: String, exitCode: Int) {
        do {
            let buffer = try await client.executeCommand(command, mergeStreams: true)
            return (String(buffer: buffer), 0)
        } catch let failed as SSHClient.CommandFailed {
            return ("", failed.exitCode)
        }
    }

    /// Wie `run`, aber mit Ausgabe auch im Fehlerfall (über einen Exit-Marker).
    static func runCapturing(_ command: String, on client: SSHClient) async throws -> (output: String, exitCode: Int) {
        let marker = "__SW_EXIT__"
        let wrapped = "{ \(command) ; } 2>&1; echo \"\(marker)$?\""
        let buffer = try await client.executeCommand(wrapped, mergeStreams: true)
        var text = String(buffer: buffer)
        var code = 0
        if let range = text.range(of: marker, options: .backwards) {
            code = Int(text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            text = String(text[..<range.lowerBound])
        }
        return (text, code)
    }

    /// Single-Quote-Escaping für die Shell.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Eine SSH-Verbindung, die entweder selbst aufgebaut wurde oder einer Sitzung gehört.
struct SSHLease {
    let client: SSHClient
    /// Selbst aufgebaut → beim Freigeben schließen. Geteilt → offen lassen.
    let owned: Bool

    func release() async {
        if owned { try? await client.close() }
    }
}

/// Verbindungen laufender Terminal-Sitzungen, die andere Funktionen mitbenutzen dürfen.
@MainActor
final class SharedConnections {
    static let shared = SharedConnections()
    private var clients: [UUID: SSHClient] = [:]

    func register(_ client: SSHClient, for hostID: UUID) { clients[hostID] = client }

    func unregister(_ client: SSHClient, for hostID: UUID) {
        if clients[hostID] === client { clients[hostID] = nil }
    }

    func client(for hostID: UUID) -> SSHClient? {
        guard let client = clients[hostID] else { return nil }
        guard client.isConnected else {
            clients[hostID] = nil
            return nil
        }
        return client
    }
}
