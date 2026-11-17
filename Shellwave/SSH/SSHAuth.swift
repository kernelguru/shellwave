import CryptoKit
import Foundation
import NIOCore
import NIOSSH

/// Bietet dem Server genau einmal den Geräte-Key zusammen mit dem UCM-Zertifikat an.
final class CertificateAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let privateKey: Curve25519.Signing.PrivateKey
    private let certifiedKey: NIOSSHCertifiedPublicKey
    private var offered = false

    init(username: String, privateKey: Curve25519.Signing.PrivateKey, certifiedKey: NIOSSHCertifiedPublicKey) {
        self.username = username
        self.privateKey = privateKey
        self.certifiedKey = certifiedKey
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !offered, availableMethods.contains(.publicKey) else {
            nextChallengePromise.fail(SSHConnectError.authenticationRejected)
            return
        }
        offered = true
        let offer = NIOSSHUserAuthenticationOffer.Offer.PrivateKey(
            privateKey: NIOSSHPrivateKey(ed25519Key: privateKey),
            certifiedKey: certifiedKey
        )
        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .privateKey(offer))
        )
    }
}

/// Trust on first use: Unbekannte Hosts werden gelernt, ein geänderter Host-Key bricht ab.
final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let known: String?
    private let onLearn: @Sendable (String) -> Void

    init(known: String?, onLearn: @escaping @Sendable (String) -> Void) {
        self.known = known
        self.onLearn = onLearn
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = String(openSSHPublicKey: hostKey)
        if let known {
            if Self.normalize(known) == Self.normalize(presented) {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(
                    SSHConnectError.hostKeyChanged(fingerprint: Self.fingerprint(of: presented))
                )
            }
        } else {
            onLearn(Self.normalize(presented))
            validationCompletePromise.succeed(())
        }
    }

    /// Nur Typ und Base64-Teil vergleichen, ohne Kommentar.
    static func normalize(_ line: String) -> String {
        line.split(separator: " ").prefix(2).joined(separator: " ")
    }

    static func fingerprint(of line: String) -> String {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return "?" }
        let b64 = Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(b64)"
    }
}

enum SSHConnectError: LocalizedError {
    case authenticationRejected
    case hostKeyChanged(fingerprint: String)
    case missingPassword

    var errorDescription: String? {
        switch self {
        case .authenticationRejected:
            return "Der Server hat die Anmeldung abgelehnt. Stimmen Benutzer und Principals, und vertraut der Server der UCM-CA?"
        case .hostKeyChanged(let fp):
            return "Achtung: Der Host-Key hat sich geändert!\nNeu: \(fp)\nWenn das gewollt ist, den gespeicherten Key in den Host-Einstellungen zurücksetzen."
        case .missingPassword:
            return "Für diesen Host ist kein Passwort gespeichert."
        }
    }
}
