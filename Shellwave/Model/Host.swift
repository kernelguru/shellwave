import Foundation
import SwiftUI

enum AuthMethod: String, Codable, CaseIterable, Identifiable {
    case certificate, key, password
    var id: String { rawValue }
    var label: String {
        switch self {
        case .certificate: return "UCM-Zertifikat"
        case .key: return "Geräte-Key"
        case .password: return "Passwort"
        }
    }
    var symbol: String {
        switch self {
        case .certificate: return "checkmark.seal"
        case .key: return "key.horizontal"
        case .password: return "ellipsis.rectangle"
        }
    }
}

enum Transport: String, Codable, CaseIterable, Identifiable {
    case ssh, mosh
    /// NetBird SSH über das eingebettete Overlay (Beta).
    case netbird
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ssh: return "SSH"
        case .mosh: return "Mosh"
        case .netbird: return "NetBird"
        }
    }
    var symbol: String {
        switch self {
        case .ssh: return "network"
        case .mosh: return "antenna.radiowaves.left.and.right"
        case .netbird: return "point.3.connected.trianglepath.dotted"
        }
    }
    /// Auswahl im Host-Editor (NetBird nur mit eingeschalteter Beta).
    static func available(netbird: Bool) -> [Transport] {
        netbird ? [.ssh, .mosh, .netbird] : [.ssh, .mosh]
    }
}

enum HostColor: String, Codable, CaseIterable, Identifiable {
    case mint, teal, indigo, orange, pink, yellow
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .mint: return Theme.mint
        case .teal: return .teal
        case .indigo: return .indigo
        case .orange: return .orange
        case .pink: return .pink
        case .yellow: return .yellow
        }
    }
    /// Für die Live Activity (Widget-Extension kennt Theme nicht).
    var hex: String {
        switch self {
        case .mint: return "73F2CC"
        case .teal: return "30B0C7"
        case .indigo: return "5856D6"
        case .orange: return "FF9500"
        case .pink: return "FF2D55"
        case .yellow: return "FFCC00"
        }
    }
}

/// Benutzer auf dem Server → Principals, die sich als dieser Benutzer anmelden dürfen.
struct PrincipalMapping: Codable, Hashable, Identifiable {
    var id = UUID()
    var user: String
    var principals: [String]
}

struct Host: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var hostname: String = ""
    var port: Int = 22
    var username: String = "root"
    var auth: AuthMethod = .certificate
    /// Principals, die ins Zertifikat kommen (leer = Benutzername).
    var principals: [String] = []
    var color: HostColor = .mint
    var tags: [String] = []
    /// Bekannter Host-Key ("ssh-ed25519 AAAA…"), beim ersten Verbinden gelernt (TOFU).
    var knownHostKey: String?
    var transport: Transport = .ssh
    /// Session im Hintergrund über den Standort-Modus am Leben halten.
    var keepAlive: Bool = true
    /// Name der tmux-Session für Auto-Attach (leer = aus).
    var tmuxSession: String = ""
    /// Zuordnung für den Server-Auto-Install.
    var principalMap: [PrincipalMapping] = []
    /// Ob der Server per Auto-Install eingerichtet wurde.
    var setupDone: Bool = false

    init() {}

    var displayName: String { name.trimmed.isEmpty ? hostname : name }
    var effectivePrincipals: [String] { principals.isEmpty ? [username] : principals }
    var address: String {
        if transport == .netbird { return "\(username)@\(hostname) (NetBird)" }
        return port == 22 ? "\(username)@\(hostname)" : "\(username)@\(hostname):\(port)"
    }
    var isNetBird: Bool { transport == .netbird }

    // MARK: Passwort (nur Schlüsselbund)

    var password: String {
        get { KeychainStore.string(service: "password", account: id.uuidString) }
        nonmutating set { KeychainStore.setString(newValue, service: "password", account: id.uuidString) }
    }

    // MARK: Codable mit Vorgaben, damit ältere Dateien weiter lesbar sind

    enum CodingKeys: String, CodingKey {
        case id, name, hostname, port, username, auth, principals, color, tags, knownHostKey
        case transport, keepAlive, tmuxSession, principalMap, setupDone
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        hostname = try c.decodeIfPresent(String.self, forKey: .hostname) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? "root"
        auth = try c.decodeIfPresent(AuthMethod.self, forKey: .auth) ?? .certificate
        principals = try c.decodeIfPresent([String].self, forKey: .principals) ?? []
        color = try c.decodeIfPresent(HostColor.self, forKey: .color) ?? .mint
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        knownHostKey = try c.decodeIfPresent(String.self, forKey: .knownHostKey)
        transport = try c.decodeIfPresent(Transport.self, forKey: .transport) ?? .ssh
        keepAlive = try c.decodeIfPresent(Bool.self, forKey: .keepAlive) ?? true
        tmuxSession = try c.decodeIfPresent(String.self, forKey: .tmuxSession) ?? ""
        principalMap = try c.decodeIfPresent([PrincipalMapping].self, forKey: .principalMap) ?? []
        setupDone = try c.decodeIfPresent(Bool.self, forKey: .setupDone) ?? false
    }
}
