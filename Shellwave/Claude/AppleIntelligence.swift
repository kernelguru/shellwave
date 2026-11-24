import Foundation
import FoundationModels

/// Apples On-Device-Modell (Apple Intelligence) als Assistent: kostenlos, privat, ohne Schlüssel.
enum AppleIntelligence {
    /// Rund 4.000 Tokens Kontext: Befehlsausgaben werden deshalb hart gekürzt.
    static let maxToolOutput = 1_500
    static let maxScreenContext = 1_200

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Verständlicher Status für Einstellungen und Fehlermeldungen.
    static var statusText: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return "Bereit"
        case .unavailable(.deviceNotEligible):
            return "Dieses Gerät unterstützt Apple Intelligence nicht."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence ist aus (Einstellungen → Apple Intelligence & Siri)."
        case .unavailable(.modelNotReady):
            return "Das Modell wird noch geladen. Bitte später erneut versuchen."
        case .unavailable:
            return "Apple Intelligence ist gerade nicht verfügbar."
        }
    }

    static func instructions(host: String, os: String?) -> String {
        """
        Du bist ein knapper Linux-Admin-Assistent in der iOS-App Shellwave. Server: \(host)\(os.map { " (\($0))" } ?? ""). \
        Mit dem Werkzeug run_command führst du einen Shell-Befehl auf diesem Server aus. Nutze es nur, wenn du Informationen \
        vom Server brauchst oder der Benutzer eine Aktion möchte. Ein Befehl pro Aufruf, möglichst kurze Ausgabe \
        (z. B. mit head, tail, grep). Schreibende Befehle muss der Benutzer freigeben. Antworte kurz auf Deutsch.
        """
    }
}

/// Werkzeug „run_command“ für das On-Device-Modell. Die Ausführung (inkl. Freigabe) übernimmt der Assistent.
struct RunCommandTool: Tool {
    let name = "run_command"
    let description = "Führt einen Shell-Befehl auf dem verbundenen Server aus und liefert Exit-Code und Ausgabe."
    let handler: @Sendable (String) async throws -> String

    @Generable
    struct Arguments {
        @Guide(description: "Der auszuführende Shell-Befehl, z. B. df -h")
        var command: String
    }

    func call(arguments: Arguments) async throws -> String {
        try await handler(arguments.command)
    }
}
