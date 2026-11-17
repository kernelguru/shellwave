import ActivityKit
import Foundation

/// Live Activity einer Session (App und Widget-Extension teilen diese Datei).
struct SessionActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// "connected", "connecting", "closed", "failed"
        var status: String
        /// "SSH" oder "Mosh"
        var transport: String
        var startedAt: Date
        /// Claude wartet auf eine Freigabe
        var pendingApproval: Bool
        var approvalSummary: String?
    }

    var hostID: String
    var hostName: String
    var address: String
    /// Farbe als Hex, passend zur Host-Karte
    var colorHex: String
}
