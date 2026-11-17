import Foundation

/// Felder für `POST /api/v2/ssh/certificates` (übernommen aus ucm-remote,
/// Laufzeit hier frei in Sekunden statt als feste Vorgabe).
struct SignRequest {
    var caID: Int
    var certType: SSHCertType = .user
    var principals: [String]
    /// 0 = Standard der CA
    var validitySeconds: Int
    var keyID: String
    var descr: String = ""

    var body: [String: Any] {
        var b: [String: Any] = [
            "ca_id": caID,
            "cert_type": certType.rawValue,
            "principals": principals,
        ]
        if validitySeconds > 0 { b["validity_seconds"] = validitySeconds }
        if !keyID.trimmed.isEmpty { b["key_id"] = keyID.trimmed }
        if !descr.trimmed.isEmpty { b["descr"] = descr.trimmed }
        return b
    }

    static func parsePrincipals(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { String($0).trimmed }
            .filter { !$0.isEmpty }
    }
}
