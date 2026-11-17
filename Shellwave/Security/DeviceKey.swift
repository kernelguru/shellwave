import CryptoKit
import Foundation
import UIKit

/// Der Ed25519-Schlüssel dieses Geräts. Er wird einmal erzeugt und liegt nur im
/// Schlüsselbund; nach außen geht ausschließlich der Public Key (zum Signieren bei UCM).
@MainActor
final class DeviceKey {
    static let shared = DeviceKey()

    private static let service = "devicekey"
    private static let account = "ed25519"

    let privateKey: Curve25519.Signing.PrivateKey
    let comment: String

    private init() {
        comment = "shellwave@" + DeviceKey.deviceSlug
        if let raw = KeychainStore.get(service: Self.service, account: Self.account),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            privateKey = key
        } else {
            let key = Curve25519.Signing.PrivateKey()
            KeychainStore.set(key.rawRepresentation, service: Self.service, account: Self.account)
            privateKey = key
        }
    }

    /// Gerätename als Kennung, z. B. für die Key-ID in UCM ("marcs-iphone").
    static var deviceSlug: String {
        let name = UIDevice.current.name.lowercased()
        let allowed = name.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let slug = String(allowed).split(separator: "-").joined(separator: "-")
        return slug.isEmpty ? "iphone" : slug
    }

    /// SSH-Wire-Format: string "ssh-ed25519" + string pub(32)
    private var publicBlob: Data {
        var d = Data()
        d.appendSSHString("ssh-ed25519")
        d.appendSSHString(privateKey.publicKey.rawRepresentation)
        return d
    }

    /// Zeile im Format von `id_ed25519.pub`.
    var publicKeyLine: String {
        "ssh-ed25519 \(publicBlob.base64EncodedString()) \(comment)"
    }

    /// SHA256-Fingerprint wie bei `ssh-keygen -l`.
    var fingerprint: String {
        let hash = SHA256.hash(data: publicBlob)
        let b64 = Data(hash).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(b64)"
    }
}

extension Data {
    mutating func appendUInt32(_ v: UInt32) {
        append(contentsOf: [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)])
    }

    mutating func appendSSHString(_ s: String) {
        appendSSHString(Data(s.utf8))
    }

    mutating func appendSSHString(_ d: Data) {
        appendUInt32(UInt32(d.count))
        append(d)
    }
}
