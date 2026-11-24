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

    /// Höchstens so viele Befehle pro Frage, dann muss das Modell antworten.
    static let maxSteps = 4

    static func instructions(host: String, os: String?) -> String {
        """
        Du bist ein knapper Linux-Admin-Assistent in der iOS-App Shellwave. Server: \(host)\(os.map { " (\($0))" } ?? ""). \
        Du antwortest immer mit genau einem Schritt: entweder action command mit einem Shell-Befehl, den die App auf dem \
        Server ausführt (du bekommst danach die Ausgabe), oder action answer mit der Antwort an den Benutzer. \
        Brauchst du Informationen vom Server, wähle command – kündige nichts an, führe es aus. \
        Ein Befehl pro Schritt, mit kurzer Ausgabe (z. B. head, tail, grep). Schreibende Befehle muss der Benutzer freigeben. \
        Wenn du die Ausgabe hast, antworte mit den konkreten Werten. Antworte kurz auf Deutsch.
        """
    }
}

/// Ein Schritt des On-Device-Modells: entweder Befehl ausführen oder antworten (Guided Generation).
@Generable
enum AppleAction {
    case command
    case answer
}

@Generable
struct AppleStep {
    @Guide(description: "command: einen Shell-Befehl auf dem Server ausführen. answer: dem Benutzer antworten.")
    var action: AppleAction
    @Guide(description: "Nur bei command: der Shell-Befehl, z. B. df -h. Sonst leer.")
    var command: String
    @Guide(description: "Nur bei answer: die Antwort an den Benutzer auf Deutsch, mit konkreten Werten. Sonst leer.")
    var answer: String
}
