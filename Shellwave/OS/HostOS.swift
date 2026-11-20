import Citadel
import Foundation
import NIOCore
import SwiftUI

/// Erkanntes Betriebssystem eines Hosts (aus /etc/os-release, uname & Co.).
struct HostOS: Codable, Hashable {
    /// Kennung, z. B. "debian", "ubuntu", "unraid", "proxmox", "macos".
    var id: String
    /// Anzeigename, z. B. "Debian".
    var name: String
    /// Version, z. B. "12" oder "7.1.4" (kann leer sein).
    var version: String
    /// Verwandte Familie aus ID_LIKE (z. B. "debian" bei unbekannten Ablegern).
    var family: String?

    var label: String { version.isEmpty ? name : "\(name) \(version)" }

    var kind: OSKind {
        let own = OSKind(id: id)
        if case .unknown = own, let family { return OSKind(id: family) }
        return own
    }
}

/// Bekannte Systeme mit typischer Farbe und Symbol (keine Marken-Logos).
enum OSKind {
    case debian, ubuntu, mint, raspbian, fedora, rhel, rocky, alma, centos, arch, manjaro
    case alpine, opensuse, nixos, gentoo, void, kali, popos
    case unraid, proxmox, truenas, openwrt, synology, opnsense, pfsense
    case macos, freebsd, openbsd, linux, unknown

    init(id: String) {
        switch id.lowercased() {
        case "debian": self = .debian
        case "ubuntu": self = .ubuntu
        case "linuxmint": self = .mint
        case "raspbian": self = .raspbian
        case "fedora": self = .fedora
        case "rhel", "redhat": self = .rhel
        case "rocky": self = .rocky
        case "almalinux": self = .alma
        case "centos": self = .centos
        case "arch", "archarm", "endeavouros": self = .arch
        case "manjaro", "manjaro-arm": self = .manjaro
        case "alpine": self = .alpine
        case let s where s.hasPrefix("opensuse") || s == "sles": self = .opensuse
        case "nixos": self = .nixos
        case "gentoo": self = .gentoo
        case "void": self = .void
        case "kali": self = .kali
        case "pop": self = .popos
        case "unraid", "slackware": self = id.lowercased() == "unraid" ? .unraid : .linux
        case "proxmox": self = .proxmox
        case "truenas": self = .truenas
        case "openwrt": self = .openwrt
        case "synology", "dsm": self = .synology
        case "opnsense": self = .opnsense
        case "pfsense": self = .pfsense
        case "macos": self = .macos
        case "freebsd": self = .freebsd
        case "openbsd": self = .openbsd
        case "linux": self = .linux
        default: self = .unknown
        }
    }

    /// Typische Farbe des Systems.
    var color: Color {
        switch self {
        case .debian: return Color(hex6: 0xD70A53)
        case .ubuntu: return Color(hex6: 0xE95420)
        case .mint: return Color(hex6: 0x87CF3E)
        case .raspbian: return Color(hex6: 0xC51A4A)
        case .fedora: return Color(hex6: 0x51A2DA)
        case .rhel: return Color(hex6: 0xEE0000)
        case .rocky: return Color(hex6: 0x10B981)
        case .alma: return Color(hex6: 0xFFCB12)
        case .centos: return Color(hex6: 0x9CCD2A)
        case .arch: return Color(hex6: 0x1793D1)
        case .manjaro: return Color(hex6: 0x35BF5C)
        case .alpine: return Color(hex6: 0x0D597F)
        case .opensuse: return Color(hex6: 0x73BA25)
        case .nixos: return Color(hex6: 0x7EBAE4)
        case .gentoo: return Color(hex6: 0x9C8FD6)
        case .void: return Color(hex6: 0x478061)
        case .kali: return Color(hex6: 0x557C94)
        case .popos: return Color(hex6: 0x48B9C7)
        case .unraid: return Color(hex6: 0xF15A2C)
        case .proxmox: return Color(hex6: 0xE57000)
        case .truenas: return Color(hex6: 0x0095D5)
        case .openwrt: return Color(hex6: 0x00B5E2)
        case .synology: return Color(hex6: 0xB5B5B6)
        case .opnsense: return Color(hex6: 0xD94F00)
        case .pfsense: return Color(hex6: 0x212121)
        case .macos: return Color(hex6: 0xA2AAAD)
        case .freebsd: return Color(hex6: 0xAB2B28)
        case .openbsd: return Color(hex6: 0xF2CA30)
        case .linux, .unknown: return Color(hex6: 0x9AA4B2)
        }
    }

    /// Passendes SF-Symbol nach Art des Systems.
    var symbol: String {
        switch self {
        case .macos: return "apple.logo"
        case .unraid, .truenas, .synology: return "externaldrive.connected.to.line.below"
        case .proxmox: return "square.stack.3d.up"
        case .openwrt, .opnsense, .pfsense: return "wifi.router"
        case .raspbian: return "cpu"
        case .freebsd, .openbsd: return "server.rack"
        case .unknown: return "terminal"
        default: return "terminal.fill"
        }
    }
}

extension Color {
    init(hex6: UInt32) {
        self.init(
            red: Double((hex6 >> 16) & 0xFF) / 255,
            green: Double((hex6 >> 8) & 0xFF) / 255,
            blue: Double(hex6 & 0xFF) / 255
        )
    }
}

/// Liest das Betriebssystem über eine bestehende SSH-Verbindung aus.
enum OSDetector {
    /// Ein Befehl für alle Systeme: Sonderfälle zuerst, dann os-release, zuletzt uname.
    static let command = """
    if [ -f /etc/unraid-version ]; then . /etc/unraid-version; echo "ID=unraid"; echo "NAME=Unraid"; echo "VERSION_ID=$version"; \
    elif command -v pveversion >/dev/null 2>&1; then echo "ID=proxmox"; echo "NAME=Proxmox VE"; echo "VERSION_ID=$(pveversion | sed -n 's#^pve-manager/\\([0-9.]*\\).*#\\1#p')"; \
    elif [ -f /etc/os-release ]; then cat /etc/os-release; \
    elif [ "$(uname -s)" = Darwin ]; then echo "ID=macos"; echo "NAME=macOS"; echo "VERSION_ID=$(sw_vers -productVersion)"; \
    else echo "ID=$(uname -s | tr A-Z a-z)"; echo "NAME=$(uname -s)"; echo "VERSION_ID=$(uname -r)"; fi
    """

    static func detect(on client: SSHClient) async -> HostOS? {
        let wrapped = "sh -c \(SSHConnector.quote(command)) 2>/dev/null"
        guard let output = try? await withTimeout(seconds: 8, operation: {
            try await client.executeCommand(wrapped, mergeStreams: true)
        }) else { return nil }
        return parse(String(buffer: output))
    }

    static func parse(_ text: String) -> HostOS? {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            fields[key] = value
        }
        guard var id = fields["ID"]?.lowercased(), !id.isEmpty else { return nil }
        if id == "darwin" { id = "macos" }
        let family = fields["ID_LIKE"]?.split(separator: " ").map(String.init).first {
            if case .unknown = OSKind(id: $0) { return false }
            return true
        }
        let name = fields["NAME"].map { $0.replacingOccurrences(of: " GNU/Linux", with: "") } ?? id.capitalized
        var version = fields["VERSION_ID"] ?? ""
        if version.isEmpty, let v = fields["VERSION"] { version = v }
        return HostOS(id: id, name: name, version: version, family: family)
    }

    private static func withTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CancellationError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
