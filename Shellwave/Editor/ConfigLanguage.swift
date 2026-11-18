import Foundation
import UIKit

/// Dateityp für Editor, Highlighting und Prüfung.
enum ConfigLanguage: String {
    case compose, yaml, conf, nginx, sshd, json, env, shell, plain

    var label: String {
        switch self {
        case .compose: return "Docker Compose"
        case .yaml: return "YAML"
        case .conf: return "Konfiguration"
        case .nginx: return "nginx"
        case .sshd: return "sshd_config"
        case .json: return "JSON"
        case .env: return ".env"
        case .shell: return "Shell"
        case .plain: return "Text"
        }
    }

    /// Erkennung über den Dateinamen (und bei .conf über den Inhalt).
    static func detect(filename: String, content: String? = nil) -> ConfigLanguage {
        let name = filename.lowercased()
        let ext = (name as NSString).pathExtension

        if ext == "yml" || ext == "yaml" {
            let isCompose = name.hasPrefix("docker-compose") || name.hasPrefix("compose")
                || (content.map { $0.range(of: #"(?m)^services\s*:"#, options: .regularExpression) != nil } ?? false)
            return isCompose ? .compose : .yaml
        }
        if name == "sshd_config" || name == "ssh_config" || name.hasSuffix("sshd_config") || (name.hasSuffix(".conf") && name.contains("sshd")) {
            return .sshd
        }
        if ext == "json" { return .json }
        if name == ".env" || ext == "env" || name.hasPrefix(".env.") { return .env }
        if ext == "sh" || ext == "bash" || name == ".bashrc" || name == ".profile" || name == "go" { return .shell }
        if ext == "conf" || ext == "cfg" || ext == "ini" || ext == "cnf" || ext == "toml" || ext == "properties" {
            if let content, content.range(of: #"(?m)^\s*(server|http|location|upstream|events)\b[^\n]*\{"#, options: .regularExpression) != nil {
                return .nginx
            }
            return .conf
        }
        return .plain
    }

    /// Dateien, die der Editor öffnet (Rest wird geteilt/heruntergeladen).
    static func isEditable(filename: String) -> Bool {
        let name = filename.lowercased()
        let ext = (name as NSString).pathExtension
        let textExtensions: Set<String> = [
            "yml", "yaml", "conf", "cfg", "ini", "cnf", "toml", "properties", "json", "env", "sh", "bash",
            "txt", "md", "service", "timer", "socket", "rules", "list", "xml", "py", "js", "log", "csv", "plist", "lua",
        ]
        if textExtensions.contains(ext) { return true }
        let knownNames: Set<String> = [
            "sshd_config", "ssh_config", "authorized_keys", "known_hosts", "hosts", "fstab", "crontab", "go",
            "dockerfile", "makefile", ".env", ".bashrc", ".profile", ".gitignore", "resolv.conf", "exports",
        ]
        return knownNames.contains(name) || name.hasPrefix(".env") || name.hasPrefix("dockerfile")
    }
}

/// Einfaches Syntax-Highlighting über reguläre Ausdrücke.
enum SyntaxHighlighter {
    struct Palette {
        static let text = UIColor(white: 0.9, alpha: 1)
        static let key = UIColor(hex: "73F2CC")
        static let string = UIColor(hex: "F7D774")
        static let number = UIColor(hex: "C397F2")
        static let comment = UIColor(white: 0.5, alpha: 1)
        static let section = UIColor(hex: "6CB6FF")
        static let punctuation = UIColor(hex: "FF9A62")
        static let variable = UIColor(hex: "5FD7D7")
        static let errorBackground = UIColor(red: 1, green: 0.25, blue: 0.25, alpha: 0.22)
        static let warningBackground = UIColor(red: 1, green: 0.75, blue: 0.2, alpha: 0.16)
    }

    static let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let boldFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .semibold)

    private struct Rule {
        let regex: NSRegularExpression
        let group: Int
        let color: UIColor
        var bold = false
    }

    private static func rule(_ pattern: String, _ color: UIColor, group: Int = 0, bold: Bool = false) -> Rule {
        Rule(regex: try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]), group: group, color: color, bold: bold)
    }

    private static let strings = rule(#""(?:[^"\\\n]|\\.)*"|'[^'\n]*'"#, Palette.string)
    private static let envVars = rule(#"\$\{[^}\n]+\}|\$[A-Za-z_][A-Za-z0-9_]*"#, Palette.variable)

    private static let yamlRules: [Rule] = [
        rule(#"^\s*(?:-\s+)?([^\s#:"'][^:#\n]*?|"[^"\n]*"|'[^'\n]*')\s*:(?=\s|$)"#, Palette.key, group: 1),
        rule(#"^\s*(-)(?=\s|$)"#, Palette.punctuation, group: 1),
        rule(#"(?<=:\s|-\s)(true|false|yes|no|on|off|null|~|-?\d+(?:\.\d+)?)\s*$"#, Palette.number, group: 1),
        rule(#"[&*][A-Za-z0-9_\-]+"#, Palette.punctuation),
        rule(#"^---\s*$|^\.\.\.\s*$"#, Palette.section),
        strings,
        envVars,
        rule(#"(?:^|\s)(#.*)$"#, Palette.comment, group: 1),
    ]

    private static let confRules: [Rule] = [
        rule(#"^\s*(\[[^\]\n]+\])"#, Palette.section, group: 1, bold: true),
        rule(#"^\s*([A-Za-z0-9_.\-]+)(?=\s*=|\s+\S)"#, Palette.key, group: 1),
        rule(#"(?<=[=\s])(true|false|yes|no|on|off|-?\d+(?:\.\d+)?[kKmMgG]?)\s*;?\s*$"#, Palette.number, group: 1),
        strings,
        envVars,
        rule(#"^\s*([#;].*)$"#, Palette.comment, group: 1),
    ]

    private static let nginxRules: [Rule] = [
        rule(#"^\s*([a-z_]+)(?=\s|;)"#, Palette.key, group: 1),
        rule(#"[{};]"#, Palette.punctuation),
        rule(#"\b\d+[kKmMsShd]?\b"#, Palette.number),
        strings,
        envVars,
        rule(#"(?:^|\s)(#.*)$"#, Palette.comment, group: 1),
    ]

    private static let sshdRules: [Rule] = [
        rule(#"^\s*(Match)\b"#, Palette.section, group: 1, bold: true),
        rule(#"^\s*([A-Za-z]+)(?=\s)"#, Palette.key, group: 1),
        rule(#"\b(yes|no|prohibit-password|without-password|forced-commands-only|any|none|\d+)\b"#, Palette.number),
        rule(#"%[a-zA-Z%]"#, Palette.variable),
        strings,
        rule(#"^\s*(#.*)$"#, Palette.comment, group: 1),
    ]

    private static let jsonRules: [Rule] = [
        rule(#""(?:[^"\\\n]|\\.)*""#, Palette.string),
        rule(#"("(?:[^"\\\n]|\\.)*")\s*:"#, Palette.key, group: 1),
        rule(#"\b(true|false|null)\b|-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, Palette.number),
        rule(#"[{}\[\]]"#, Palette.punctuation),
    ]

    private static let envRules: [Rule] = [
        rule(#"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)(?==)"#, Palette.key, group: 1),
        strings,
        envVars,
        rule(#"^\s*(#.*)$"#, Palette.comment, group: 1),
    ]

    private static let shellRules: [Rule] = [
        rule(#"\b(if|then|else|elif|fi|for|while|do|done|case|esac|in|function|return|export|local|exit)\b"#, Palette.section, bold: true),
        rule(#"^\s*([A-Za-z_][A-Za-z0-9_]*)(?==)"#, Palette.key, group: 1),
        strings,
        envVars,
        rule(#"(?:^|\s)(#.*)$"#, Palette.comment, group: 1),
    ]

    private static func rules(for language: ConfigLanguage) -> [Rule] {
        switch language {
        case .compose, .yaml: return yamlRules
        case .conf: return confRules
        case .nginx: return nginxRules
        case .sshd: return sshdRules
        case .json: return jsonRules
        case .env: return envRules
        case .shell: return shellRules
        case .plain: return []
        }
    }

    /// Färbt den Text im TextStorage ein, ohne Text oder Auswahl zu verändern.
    static func apply(to storage: NSTextStorage, language: ConfigLanguage, diagnostics: [Diagnostic]) {
        let text = storage.string
        let full = NSRange(location: 0, length: (text as NSString).length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: Palette.text], range: full)

        // Große Dateien nur grob einfärben, damit das Tippen flüssig bleibt
        if full.length < 300_000 {
            for rule in rules(for: language) {
                rule.regex.enumerateMatches(in: text, range: full) { match, _, _ in
                    guard let match else { return }
                    let range = match.range(at: rule.group)
                    guard range.location != NSNotFound else { return }
                    storage.addAttribute(.foregroundColor, value: rule.color, range: range)
                    if rule.bold { storage.addAttribute(.font, value: boldFont, range: range) }
                }
            }
        }

        // Zeilen mit Fehlern/Warnungen hinterlegen
        let lineRanges = lineRanges(in: text as NSString)
        for d in diagnostics {
            guard d.line >= 1, d.line <= lineRanges.count else { continue }
            let color = d.severity == .error ? Palette.errorBackground : Palette.warningBackground
            storage.addAttribute(.backgroundColor, value: color, range: lineRanges[d.line - 1])
        }
        storage.endEditing()
    }

    static func lineRanges(in text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var location = 0
        while location <= text.length {
            let range = text.lineRange(for: NSRange(location: location, length: 0))
            ranges.append(range)
            if range.length == 0 || NSMaxRange(range) >= text.length { break }
            location = NSMaxRange(range)
        }
        return ranges
    }
}
