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

    var displayName: String { name.trimmed.isEmpty ? hostname : name }
    var effectivePrincipals: [String] { principals.isEmpty ? [username] : principals }
    var address: String { port == 22 ? "\(username)@\(hostname)" : "\(username)@\(hostname):\(port)" }

    // MARK: Passwort (nur Schlüsselbund)

    var password: String {
        get { KeychainStore.string(service: "password", account: id.uuidString) }
        nonmutating set { KeychainStore.setString(newValue, service: "password", account: id.uuidString) }
    }
}
