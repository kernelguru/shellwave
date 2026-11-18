import Foundation
import SwiftUI

enum ClaudeMode: String, CaseIterable, Identifiable {
    /// Claude Code läuft auf dem Server, die App ist Oberfläche und Freigabe
    case claudeCode
    /// Die App spricht direkt mit der Claude-API und führt Befehle per SSH aus
    case api
    var id: String { rawValue }
    var label: String { self == .claudeCode ? "Claude Code auf dem Server" : "API aus der App" }
}

/// Anbieter für den Modus „API aus der App“.
enum APIProvider: String, CaseIterable, Identifiable {
    case anthropic, google, openAICompatible
    var id: String { rawValue }
    var label: String {
        switch self {
        case .anthropic: return "Claude (Anthropic)"
        case .google: return "Gemini (Google)"
        case .openAICompatible: return "OpenAI-kompatibel"
        }
    }
}

/// Vorlagen für den OpenAI-kompatiblen Anbieter.
struct OpenAIPreset: Identifiable {
    let id: String
    let name: String
    let baseURL: String
    let model: String
    let needsKey: Bool

    static let all: [OpenAIPreset] = [
        OpenAIPreset(id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1", model: "llama-3.3-70b-versatile", needsKey: true),
        OpenAIPreset(id: "mistral", name: "Mistral", baseURL: "https://api.mistral.ai/v1", model: "mistral-small-latest", needsKey: true),
        OpenAIPreset(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", model: "meta-llama/llama-3.3-70b-instruct:free", needsKey: true),
        OpenAIPreset(id: "ollama", name: "Ollama (eigener Server)", baseURL: "http://192.168.1.10:11434/v1", model: "qwen3:8b", needsKey: false),
    ]
}

@MainActor
final class ClaudeSettings: ObservableObject {
    @AppStorage("claude.mode") var modeRaw: String = ClaudeMode.claudeCode.rawValue
    @AppStorage("claude.model") var model: String = "claude-sonnet-5-5"
    @AppStorage("claude.autoApproveReadOnly") var autoApproveReadOnly: Bool = true
    @AppStorage("claude.requireBiometrics") var requireBiometrics: Bool = true
    /// API-Key auch an Claude Code auf dem Server weitergeben (sonst nutzt der Server sein eigenes Login)
    @AppStorage("claude.passKeyToServer") var passKeyToServer: Bool = false
    @Published var apiKey: String = KeychainStore.string(service: "claude", account: "apikey")
    @AppStorage("assistant.apiProvider") var apiProviderRaw: String = APIProvider.anthropic.rawValue
    @AppStorage("gemini.model") var geminiModel: String = "gemini-3.8-flash"
    @Published var geminiKey: String = KeychainStore.string(service: "gemini", account: "apikey")

    var apiProvider: APIProvider {
        get { APIProvider(rawValue: apiProviderRaw) ?? .anthropic }
        set { apiProviderRaw = newValue.rawValue }
    }

    @AppStorage("openai.baseURL") var openAIBaseURL: String = "https://api.groq.com/openai/v1"
    @AppStorage("openai.model") var openAIModel: String = "llama-3.3-70b-versatile"
    @Published var openAIKey: String = KeychainStore.string(service: "openai", account: "apikey")

    func saveOpenAIKey(_ key: String) {
        openAIKey = key.trimmed
        KeychainStore.setString(openAIKey, service: "openai", account: "apikey")
    }

    func apply(_ preset: OpenAIPreset) {
        openAIBaseURL = preset.baseURL
        openAIModel = preset.model
    }

    func saveGeminiKey(_ key: String) {
        geminiKey = key.trimmed
        KeychainStore.setString(geminiKey, service: "gemini", account: "apikey")
    }

    var mode: ClaudeMode {
        get { ClaudeMode(rawValue: modeRaw) ?? .claudeCode }
        set { modeRaw = newValue.rawValue }
    }

    func saveAPIKey(_ key: String) {
        apiKey = key.trimmed
        KeychainStore.setString(apiKey, service: "claude", account: "apikey")
    }

    /// Geteilte Instanz, damit Agents ohne Environment darauf zugreifen können.
    static let shared = ClaudeSettings()
}

/// Merkt sich pro Host die Claude-Code-Session, damit ein Chat fortgesetzt werden kann.
enum ClaudeSessionIDs {
    private static let key = "claude.sessionIDs"

    static func get(_ hostID: UUID) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[hostID.uuidString]
    }

    static func set(_ id: String?, for hostID: UUID) {
        var dict = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        dict[hostID.uuidString] = id
        UserDefaults.standard.set(dict, forKey: key)
    }
}

/// Entscheidet, ob eine Aktion ohne Rückfrage laufen darf (nur lesende Befehle).
enum ReadOnlyPolicy {
    static let readOnlyTools: Set<String> = ["Read", "Grep", "Glob", "LS", "TodoWrite", "WebSearch", "WebFetch", "NotebookRead"]

    static let readOnlyCommands: Set<String> = [
        "ls", "cat", "head", "tail", "grep", "egrep", "fgrep", "rg", "find", "df", "du", "free", "uptime", "uname",
        "whoami", "id", "ps", "pwd", "echo", "env", "printenv", "stat", "wc", "sort", "uniq", "which", "hostname",
        "date", "lsblk", "ip", "ss", "netstat", "journalctl", "dmesg", "lscpu", "lsusb", "lspci", "nproc", "file",
        "type", "command", "test", "true", "tree", "realpath", "dirname", "basename", "md5sum", "sha256sum",
    ]

    static func isReadOnly(tool: String, input: [String: Any]) -> Bool {
        if readOnlyTools.contains(tool) { return true }
        guard tool == "Bash" || tool == "run_command", let command = input["command"] as? String else { return false }
        return isReadOnly(command: command)
    }

    static func isReadOnly(command: String) -> Bool {
        if command.contains(">") || command.contains("`") || command.contains("$(") { return false }
        if command.contains("-delete") || command.contains("-exec") || command.contains("-ok ") { return false }
        let segments = command
            .replacingOccurrences(of: "&&", with: ";")
            .replacingOccurrences(of: "||", with: ";")
            .replacingOccurrences(of: "|", with: ";")
            .split(separator: ";")
        guard !segments.isEmpty else { return false }
        for segment in segments {
            let words = segment.split(separator: " ").map(String.init).filter { !$0.contains("=") || $0.hasPrefix("-") }
            guard let first = words.first else { continue }
            if first == "sudo" { return false }
            switch first {
            case "systemctl":
                guard words.count > 1, ["status", "is-active", "is-enabled", "list-units", "list-timers", "show", "cat"].contains(words[1]) else { return false }
            case "docker", "podman":
                guard words.count > 1, ["ps", "logs", "inspect", "images", "stats", "info", "version", "top"].contains(words[1]) else { return false }
            case "git":
                guard words.count > 1, ["status", "log", "diff", "show", "branch", "remote"].contains(words[1]) else { return false }
            default:
                guard readOnlyCommands.contains(first) else { return false }
            }
        }
        return true
    }
}
