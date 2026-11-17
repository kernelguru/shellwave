import Foundation
import NIOSSH

/// Ein User-Zertifikat für den Geräte-Key, entweder von UCM geholt oder manuell importiert.
struct StoredCertificate: Codable, Hashable {
    var line: String
    var ucmID: Int?
    var manual: Bool

    var parsed: NIOSSHCertifiedPublicKey? {
        guard let key = try? NIOSSHPublicKey(openSSHPublicKey: line.trimmed) else { return nil }
        return NIOSSHCertifiedPublicKey(key)
    }

    var principals: [String] { parsed?.validPrincipals ?? [] }
    var keyID: String { parsed?.keyID ?? "" }
    var validAfter: Date { Date(timeIntervalSince1970: TimeInterval(parsed?.validAfter ?? 0)) }
    var validBefore: Date {
        guard let vb = parsed?.validBefore else { return .distantPast }
        // OpenSSH nutzt UInt64.max für "unbegrenzt"
        return vb >= UInt64(Int64.max) ? .distantFuture : Date(timeIntervalSince1970: TimeInterval(vb))
    }

    /// Gültig und mit ausreichend Restlaufzeit (mind. 20 % bzw. 1 Stunde).
    func isFresh(now: Date = .now) -> Bool {
        guard now >= validAfter, now < validBefore else { return false }
        if validBefore == .distantFuture { return true }
        let total = validBefore.timeIntervalSince(validAfter)
        let left = validBefore.timeIntervalSince(now)
        return left > min(3600, total * 0.5) && left > total * 0.2
    }

    func covers(_ wanted: [String]) -> Bool {
        let have = Set(principals)
        return !wanted.isEmpty && Set(wanted).isSubset(of: have)
    }
}

enum CertificateError: LocalizedError {
    case notConfigured
    case invalidCertificate
    case wrongKey
    case noCertificateInResponse
    case expired

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Kein gültiges Zertifikat vorhanden und UCM ist nicht eingerichtet (Server, API-Schlüssel, CA)."
        case .invalidCertificate:
            return "Das ist kein gültiges OpenSSH-User-Zertifikat."
        case .wrongKey:
            return "Das Zertifikat gehört zu einem anderen Schlüssel als dem dieses Geräts."
        case .noCertificateInResponse:
            return "UCM hat kein Zertifikat zurückgegeben."
        case .expired:
            return "Das Zertifikat ist abgelaufen."
        }
    }
}

/// Hält Zertifikate pro Principal-Satz und erneuert sie bei Bedarf still über UCM.
@MainActor
final class CertificateManager: ObservableObject {
    @Published private(set) var certificates: [String: StoredCertificate] = [:]

    private let settings: UCMSettings
    private var key: DeviceKey { DeviceKey.shared }

    init(settings: UCMSettings) {
        self.settings = settings
        certificates = JSONFile.load([String: StoredCertificate].self, from: "certificates.json") ?? [:]
    }

    private static func slot(for principals: [String]) -> String {
        principals.sorted().joined(separator: ",")
    }

    /// Liefert ein gültiges Zertifikat für die Principals – aus dem Speicher, sonst frisch von UCM.
    func certificate(for principals: [String]) async throws -> StoredCertificate {
        let slot = Self.slot(for: principals)
        if let cert = certificates[slot], cert.isFresh() { return cert }

        // Ein manuell importiertes Zertifikat, das die Principals abdeckt, zählt auch.
        if let manual = certificates.values.first(where: { $0.manual && $0.covers(principals) && $0.isFresh() }) {
            return manual
        }

        guard settings.isConfigured else {
            if certificates.values.contains(where: { $0.covers(principals) }) { throw CertificateError.expired }
            throw CertificateError.notConfigured
        }
        return try await renew(principals: principals)
    }

    /// Lässt den Geräte-Key bei UCM neu signieren.
    @discardableResult
    func renew(principals: [String]) async throws -> StoredCertificate {
        let client = try settings.client()
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd-HHmm"
        let stamp = fmt.string(from: .now)
        let request = SignRequest(
            caID: settings.caID,
            principals: principals,
            validitySeconds: settings.validitySeconds,
            keyID: "\(DeviceKey.deviceSlug)-\(stamp)",
            descr: "Shellwave \(DeviceKey.deviceSlug)"
        )
        let issued = try await client.sign(publicKey: key.publicKeyLine, request: request)

        var line = issued.certificate?.trimmed ?? ""
        if line.isEmpty {
            line = try await client.export(certificateID: issued.id).certificate?.trimmed ?? ""
        }
        guard !line.isEmpty else { throw CertificateError.noCertificateInResponse }

        let stored = StoredCertificate(line: line, ucmID: issued.id, manual: false)
        try validate(stored)
        certificates[Self.slot(for: principals)] = stored
        persist()
        return stored
    }

    /// Importiert ein extern signiertes `-cert.pub` (z. B. aus ucm-remote).
    @discardableResult
    func importManual(_ text: String) throws -> StoredCertificate {
        let line = text.split(whereSeparator: \.isNewline).map(String.init)
            .first(where: { $0.contains("-cert-v01@openssh.com") })?.trimmed ?? text.trimmed
        let stored = StoredCertificate(line: line, ucmID: nil, manual: true)
        try validate(stored)
        certificates["manual:" + Self.slot(for: stored.principals)] = stored
        persist()
        return stored
    }

    func remove(slot: String) {
        certificates[slot] = nil
        persist()
    }

    private func validate(_ cert: StoredCertificate) throws {
        guard let parsed = cert.parsed, parsed.type == .user else { throw CertificateError.invalidCertificate }
        let certKey = String(openSSHPublicKey: parsed.key)
        let deviceKey = key.publicKeyLine.split(separator: " ").prefix(2).joined(separator: " ")
        guard certKey == deviceKey else { throw CertificateError.wrongKey }
    }

    private func persist() {
        JSONFile.save(certificates, to: "certificates.json")
    }
}
