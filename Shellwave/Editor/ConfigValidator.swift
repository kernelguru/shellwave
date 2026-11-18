import Foundation
import Yams

struct Diagnostic: Identifiable, Hashable {
    enum Severity: Hashable { case error, warning }
    let id = UUID()
    let line: Int
    let column: Int
    let message: String
    let severity: Severity
}

/// Prüft Konfigurationsdateien lokal (ohne Server).
enum ConfigValidator {
    static func validate(_ text: String, language: ConfigLanguage) -> [Diagnostic] {
        var result: [Diagnostic]
        switch language {
        case .compose:
            result = validateYAML(text, compose: true)
        case .yaml:
            result = validateYAML(text, compose: false)
        case .json:
            result = validateJSON(text)
        case .conf:
            result = validateINI(text)
        case .nginx:
            result = validateBraces(text, requireSemicolons: true)
        case .sshd:
            result = validateSSHD(text)
        case .env:
            result = validateEnv(text)
        case .shell, .plain:
            result = []
        }
        return result.sorted { ($0.line, $0.column) < ($1.line, $1.column) }
    }

    // MARK: YAML

    private static func validateYAML(_ text: String, compose isCompose: Bool) -> [Diagnostic] {
        var diags: [Diagnostic] = []

        // Tabs zur Einrückung sind in YAML verboten – häufigster Fehler beim Bearbeiten am Handy
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            if indent.contains("\t") {
                diags.append(.init(line: i + 1, column: 1, message: "Tabulator in der Einrückung – YAML erlaubt nur Leerzeichen.", severity: .error))
            }
        }

        let root: Node?
        do {
            root = try Yams.compose(yaml: text)
        } catch let error as YamlError {
            diags.append(diagnostic(from: error))
            return diags
        } catch {
            diags.append(.init(line: 1, column: 1, message: error.localizedDescription, severity: .error))
            return diags
        }

        if isCompose {
            diags += ComposeChecker.check(root)
        }
        return diags
    }

    private static func diagnostic(from error: YamlError) -> Diagnostic {
        switch error {
        case let .scanner(context, problem, mark, _),
             let .parser(context, problem, mark, _),
             let .composer(context, problem, mark, _):
            var message = translate(problem)
            if let context { message += " (\(translate(context.text)) ab Zeile \(context.mark.line))" }
            return .init(line: mark.line, column: mark.column, message: message, severity: .error)
        case let .duplicatedKeysInMapping(duplicates, context):
            return .init(line: context.mark.line, column: context.mark.column,
                         message: "Doppelter Schlüssel: \(duplicates.joined(separator: ", "))", severity: .error)
        case let .reader(problem, _, _, _):
            return .init(line: 1, column: 1, message: problem, severity: .error)
        default:
            return .init(line: 1, column: 1, message: "\(error)", severity: .error)
        }
    }

    /// Die häufigsten libyaml-Meldungen auf Deutsch.
    private static func translate(_ text: String) -> String {
        let map: [(String, String)] = [
            ("mapping values are not allowed in this context", "Doppelpunkt an dieser Stelle nicht erlaubt (Einrückung oder fehlende Anführungszeichen?)"),
            ("did not find expected key", "Schlüssel erwartet – Einrückung prüfen"),
            ("did not find expected '-' indicator", "Listeneintrag mit „-“ erwartet – Einrückung prüfen"),
            ("found character that cannot start any token", "Zeichen kann hier nicht stehen (Tab oder Sonderzeichen?)"),
            ("found unexpected end of stream", "Unerwartetes Dateiende (Anführungszeichen nicht geschlossen?)"),
            ("could not find expected ':'", "Doppelpunkt fehlt"),
            ("found undefined alias", "Unbekannter Anker-Verweis"),
            ("while parsing a block mapping", "in diesem Block"),
            ("while parsing a block collection", "in dieser Liste"),
            ("while scanning a simple key", "bei diesem Schlüssel"),
            ("while scanning a quoted scalar", "in diesem Text in Anführungszeichen"),
        ]
        for (en, de) in map where text.contains(en) { return de }
        return text
    }

    // MARK: JSON

    private static func validateJSON(_ text: String) -> [Diagnostic] {
        guard !text.trimmed.isEmpty else { return [] }
        do {
            _ = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
            return []
        } catch let error as NSError {
            // NSJSONSerialization nennt die Zeichenposition im Debug-Text
            let detail = (error.userInfo[NSDebugDescriptionErrorKey] as? String) ?? error.localizedDescription
            var line = 1
            if let range = detail.range(of: #"line (\d+)"#, options: .regularExpression),
               let n = Int(detail[range].dropFirst(5)) { line = n }
            return [.init(line: line, column: 1, message: detail, severity: .error)]
        }
    }

    // MARK: INI / conf

    private static func validateINI(_ text: String) -> [Diagnostic] {
        var diags: [Diagnostic] = []
        var section = ""
        var seen: [String: Int] = [:]
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let n = i + 1
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") {
                if !line.hasSuffix("]") {
                    diags.append(.init(line: n, column: 1, message: "Abschnitt ohne schließende „]“", severity: .error))
                }
                section = line
                continue
            }
            diags += quoteCheck(line, lineNumber: n)
            if let eq = line.firstIndex(of: "=") {
                let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                if key.isEmpty {
                    diags.append(.init(line: n, column: 1, message: "Wert ohne Schlüssel", severity: .error))
                } else if let first = seen["\(section)|\(key)"] {
                    diags.append(.init(line: n, column: 1, message: "„\(key)“ ist schon in Zeile \(first) gesetzt – der spätere Wert gewinnt.", severity: .warning))
                } else {
                    seen["\(section)|\(key)"] = n
                }
            }
        }
        return diags
    }

    // MARK: nginx & andere Klammer-Configs

    private static func validateBraces(_ text: String, requireSemicolons: Bool) -> [Diagnostic] {
        var diags: [Diagnostic] = []
        var stack: [Int] = []
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let n = i + 1
            let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            diags += quoteCheck(line, lineNumber: n)
            for ch in line {
                if ch == "{" { stack.append(n) }
                if ch == "}" {
                    if stack.popLast() == nil {
                        diags.append(.init(line: n, column: 1, message: "„}“ ohne passende „{“", severity: .error))
                    }
                }
            }
            if requireSemicolons, !line.hasSuffix(";"), !line.hasSuffix("{"), !line.hasSuffix("}") {
                diags.append(.init(line: n, column: line.count, message: "Anweisung endet nicht mit „;“", severity: .error))
            }
        }
        for open in stack {
            diags.append(.init(line: open, column: 1, message: "„{“ wird nicht geschlossen", severity: .error))
        }
        return diags
    }

    // MARK: sshd_config

    private static let sshdKeywords: Set<String> = [
        "acceptenv", "addressfamily", "allowagentforwarding", "allowgroups", "allowstreamlocalforwarding", "allowtcpforwarding",
        "allowusers", "authenticationmethods", "authorizedkeyscommand", "authorizedkeyscommanduser", "authorizedkeysfile",
        "authorizedprincipalscommand", "authorizedprincipalscommanduser", "authorizedprincipalsfile", "banner", "casignaturealgorithms",
        "channeltimeout", "chrootdirectory", "ciphers", "clientalivecountmax", "clientaliveinterval", "compression", "denygroups",
        "denyusers", "disableforwarding", "exposeauthinfo", "fingerprinthash", "forcecommand", "gatewayports", "gssapiauthentication",
        "gssapicleanupcredentials", "gssapikeyexchange", "gssapistrictacceptorcheck", "hostbasedacceptedalgorithms",
        "hostbasedauthentication", "hostbasedusesnamefrompacketonly", "hostcertificate", "hostkey", "hostkeyagent", "hostkeyalgorithms",
        "ignorerhosts", "ignoreuserknownhosts", "include", "ipqos", "kbdinteractiveauthentication", "kerberosauthentication",
        "kerberosorlocalpasswd", "kerberosticketcleanup", "kexalgorithms", "listenaddress", "logingracetime", "loglevel", "logverbose",
        "macs", "match", "maxauthtries", "maxsessions", "maxstartups", "modulifile", "passwordauthentication", "permitemptypasswords",
        "permitlisten", "permitopen", "permitrootlogin", "permittty", "permittunnel", "permituserenvironment", "permituserrc",
        "persourcemaxstartups", "persourcenetblocksize", "persourcepenalties", "persourcepenaltyexemptlist", "pidfile", "port",
        "printlastlog", "printmotd", "pubkeyacceptedalgorithms", "pubkeyauthentication", "pubkeyauthoptions", "rdomain", "rekeylimit",
        "requiredrsasize", "revokedkeys", "securitykeyprovider", "setenv", "streamlocalbindmask", "streamlocalbindunlink",
        "strictmodes", "subsystem", "syslogfacility", "tcpkeepalive", "trustedusercakeys", "unusedconnectiontimeout", "usedns",
        "usepam", "useprivilegeseparation", "versionaddendum", "x11displayoffset", "x11forwarding", "x11uselocalhost", "xauthlocation",
        "challengeresponseauthentication", "pubkeyacceptedkeytypes", "hostbasedacceptedkeytypes", "sshdsessionpath", "sshdauthpath",
        "refuseconnection", "gssapienablek5users", "kerberosgetafstoken", "kerberosusekuserok", "gssapistorecredentialsonrekey",
        "gssapikexalgorithms", "rsaminsize", "protocol", "useroaming", "keyregenerationinterval", "serverkeybits", "rhostsrsaauthentication",
    ]

    private static func validateSSHD(_ text: String) -> [Diagnostic] {
        var diags: [Diagnostic] = []
        var inMatch = false
        let globalOnly: Set<String> = ["port", "listenaddress", "hostkey", "usepam", "pidfile", "protocol", "addressfamily", "subsystem"]
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let n = i + 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard let keyword = parts.first.map({ String($0).lowercased() }) else { continue }
            if !sshdKeywords.contains(keyword) {
                diags.append(.init(line: n, column: 1, message: "Unbekannte Option „\(parts[0])“ – sshd startet damit nicht.", severity: .error))
                continue
            }
            if parts.count < 2 {
                diags.append(.init(line: n, column: 1, message: "„\(parts[0])“ ohne Wert", severity: .error))
            }
            if keyword == "match" { inMatch = true }
            if inMatch, globalOnly.contains(keyword) {
                diags.append(.init(line: n, column: 1, message: "„\(parts[0])“ ist in einem Match-Block nicht erlaubt.", severity: .error))
            }
        }
        return diags
    }

    // MARK: .env

    private static func validateEnv(_ text: String) -> [Diagnostic] {
        var diags: [Diagnostic] = []
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let n = i + 1
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let eq = line.firstIndex(of: "=") else {
                diags.append(.init(line: n, column: 1, message: "Zeile ohne „=“", severity: .error))
                continue
            }
            let key = line[..<eq]
            if key.contains(" ") || key.isEmpty {
                diags.append(.init(line: n, column: 1, message: "Ungültiger Variablenname „\(key)“", severity: .error))
            }
            diags += quoteCheck(String(line[line.index(after: eq)...]), lineNumber: n)
        }
        return diags
    }

    // MARK: Hilfen

    private static func stripComment(_ line: String) -> String {
        var inSingle = false, inDouble = false
        for (idx, ch) in line.enumerated() {
            if ch == "'" && !inDouble { inSingle.toggle() }
            if ch == "\"" && !inSingle { inDouble.toggle() }
            if ch == "#" && !inSingle && !inDouble { return String(line.prefix(idx)) }
        }
        return line
    }

    private static func quoteCheck(_ line: String, lineNumber: Int) -> [Diagnostic] {
        var doubles = 0
        var escaped = false
        for ch in line {
            if escaped { escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "\"" { doubles += 1 }
        }
        return doubles % 2 == 1
            ? [.init(line: lineNumber, column: 1, message: "Anführungszeichen nicht geschlossen", severity: .error)]
            : []
    }
}

/// Inhaltliche Prüfung von Compose-Dateien (Struktur, Verweise, typische Fehler).
enum ComposeChecker {
    private static let topLevel: Set<String> = ["version", "name", "services", "networks", "volumes", "configs", "secrets", "include", "models"]

    private static let serviceKeys: Set<String> = [
        "annotations", "attach", "blkio_config", "build", "cap_add", "cap_drop", "cgroup", "cgroup_parent", "command", "configs",
        "container_name", "cpu_count", "cpu_percent", "cpu_period", "cpu_quota", "cpu_rt_period", "cpu_rt_runtime", "cpu_shares",
        "cpus", "cpuset", "credential_spec", "depends_on", "deploy", "develop", "device_cgroup_rules", "devices", "dns", "dns_opt",
        "dns_search", "domainname", "driver_opts", "entrypoint", "env_file", "environment", "expose", "extends", "external_links",
        "extra_hosts", "gpus", "group_add", "healthcheck", "hostname", "image", "init", "ipc", "isolation", "label_file", "labels",
        "links", "logging", "mac_address", "mem_limit", "mem_reservation", "mem_swappiness", "memswap_limit", "models", "network_mode",
        "networks", "oom_kill_disable", "oom_score_adj", "pid", "pids_limit", "platform", "ports", "post_start", "pre_stop",
        "privileged", "profiles", "provider", "pull_policy", "read_only", "restart", "runtime", "scale", "secrets", "security_opt",
        "shm_size", "stdin_open", "stop_grace_period", "stop_signal", "storage_opt", "sysctls", "tmpfs", "tty", "ulimits",
        "use_api_socket", "user", "userns_mode", "uts", "volumes", "volumes_from", "working_dir",
    ]

    static func check(_ root: Node?) -> [Diagnostic] {
        guard let root else {
            return [.init(line: 1, column: 1, message: "Leere Compose-Datei", severity: .error)]
        }
        guard let top = root.mapping else {
            return [diag(root, "Die Datei muss mit Schlüsseln wie „services:“ beginnen.", .error)]
        }
        var d: [Diagnostic] = []

        for (key, _) in top {
            let k = key.string ?? ""
            if k == "version" {
                d.append(diag(key, "„version“ ist veraltet und wird von Docker Compose ignoriert.", .warning))
            } else if !topLevel.contains(k) && !k.hasPrefix("x-") {
                d.append(diag(key, "Unbekannter Schlüssel „\(k)“ auf oberster Ebene.", .error))
            }
        }

        let definedNetworks = Set(top["networks"]?.mapping?.keys.compactMap(\.string) ?? [])
        let definedVolumes = Set(top["volumes"]?.mapping?.keys.compactMap(\.string) ?? [])
        let definedSecrets = Set(top["secrets"]?.mapping?.keys.compactMap(\.string) ?? [])
        let definedConfigs = Set(top["configs"]?.mapping?.keys.compactMap(\.string) ?? [])

        guard let servicesNode = top["services"] else {
            if top["include"] == nil {
                d.append(.init(line: 1, column: 1, message: "Es fehlt „services:“.", severity: .error))
            }
            return d
        }
        guard let services = servicesNode.mapping else {
            d.append(diag(servicesNode, "„services“ muss eine Zuordnung von Dienstnamen sein.", .error))
            return d
        }
        let serviceNames = Set(services.keys.compactMap(\.string))
        var containerNames: [String: Node] = [:]

        for (nameNode, service) in services {
            let name = nameNode.string ?? "?"
            guard let s = service.mapping else {
                d.append(diag(service, "Dienst „\(name)“ muss eine Zuordnung sein.", .error))
                continue
            }

            for (key, _) in s {
                let k = key.string ?? ""
                if !serviceKeys.contains(k) && !k.hasPrefix("x-") {
                    d.append(diag(key, "Unbekannte Option „\(k)“ bei „\(name)“ (Tippfehler?).", .warning))
                }
            }

            if s["image"] == nil && s["build"] == nil && s["extends"] == nil {
                d.append(diag(nameNode, "Dienst „\(name)“ braucht „image“ oder „build“.", .error))
            }

            if let restart = s["restart"]?.string {
                let ok = ["no", "always", "unless-stopped", "on-failure"].contains(restart)
                    || restart.range(of: #"^on-failure:\d+$"#, options: .regularExpression) != nil
                if !ok, let node = s["restart"] {
                    d.append(diag(node, "Ungültiger restart-Wert „\(restart)“ (no, always, unless-stopped, on-failure).", .error))
                }
            }

            if let cn = s["container_name"], let value = cn.string {
                if let other = containerNames[value] {
                    d.append(diag(cn, "container_name „\(value)“ wird schon in Zeile \(other.mark?.line ?? 0) verwendet.", .error))
                } else {
                    containerNames[value] = cn
                }
            }

            // ports
            if let ports = s["ports"] {
                if let list = ports.sequence {
                    for p in list {
                        guard let scalar = p.scalar else { continue }  // Lange Syntax ist eine Zuordnung
                        let value = scalar.string
                        if !isValidPort(value) {
                            d.append(diag(p, "Ungültige Port-Angabe „\(value)“.", .error))
                        } else if value.contains(":"), scalar.style == .plain {
                            d.append(diag(p, "Port „\(value)“ in Anführungszeichen setzen – sonst kann YAML ihn als Zahl lesen.", .warning))
                        }
                    }
                } else {
                    d.append(diag(ports, "„ports“ muss eine Liste sein.", .error))
                }
            }

            // depends_on
            if let dep = s["depends_on"] {
                let names: [Node] = dep.sequence.map { Array($0) } ?? dep.mapping.map { Array($0.keys) } ?? []
                for n in names {
                    if let ref = n.string, !serviceNames.contains(ref) {
                        d.append(diag(n, "depends_on: Dienst „\(ref)“ gibt es nicht.", .error))
                    } else if n.string == name {
                        d.append(diag(n, "Dienst hängt von sich selbst ab.", .error))
                    }
                }
            }

            // networks
            if let nets = s["networks"] {
                if s["network_mode"] != nil {
                    d.append(diag(nets, "„networks“ und „network_mode“ schließen sich aus.", .error))
                }
                let names: [Node] = nets.sequence.map { Array($0) } ?? nets.mapping.map { Array($0.keys) } ?? []
                for n in names {
                    if let ref = n.string, ref != "default", !definedNetworks.contains(ref) {
                        d.append(diag(n, "Netzwerk „\(ref)“ ist unter „networks:“ nicht definiert.", .error))
                    }
                }
            }

            // volumes (Kurzsyntax: quelle:ziel[:modus])
            if let vols = s["volumes"]?.sequence {
                for v in vols {
                    guard let value = v.string, v.scalar != nil else { continue }
                    let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                    if parts.count >= 2 {
                        let source = parts[0]
                        let isPath = source.hasPrefix("/") || source.hasPrefix(".") || source.hasPrefix("~") || source.hasPrefix("$")
                        if !isPath, !source.isEmpty, !definedVolumes.contains(source) {
                            d.append(diag(v, "Benanntes Volume „\(source)“ ist unter „volumes:“ nicht definiert (für einen Ordner mit ./ oder / beginnen).", .error))
                        }
                        if parts.count >= 3, !["ro", "rw", "z", "Z", "cached", "delegated", "consistent", "nocopy", "ro,z", "ro,Z", "rw,z", "rw,Z"].contains(parts[2]) {
                            d.append(diag(v, "Unbekannter Volume-Modus „\(parts[2])“.", .warning))
                        }
                    }
                }
            }

            // secrets / configs
            for (key, defined) in [("secrets", definedSecrets), ("configs", definedConfigs)] {
                guard let list = s[key]?.sequence else { continue }
                for item in list {
                    let ref = item.string ?? item.mapping?["source"]?.string
                    if let ref, !defined.contains(ref) {
                        d.append(diag(item, "\(key == "secrets" ? "Secret" : "Config") „\(ref)“ ist oben nicht definiert.", .error))
                    }
                }
            }

            // environment
            if let env = s["environment"]?.sequence {
                for e in env {
                    if let value = e.string, value.hasPrefix("="), value.count > 1 {
                        d.append(diag(e, "Variable ohne Namen.", .error))
                    }
                }
            }
        }
        return d
    }

    private static func isValidPort(_ value: String) -> Bool {
        let pattern = #"^((\[[0-9a-fA-F:.]+\]|[0-9.]+|\$\{[^}]+\}):)?((\d+(-\d+)?|\$\{[^}]+\}):)?(\d+(-\d+)?|\$\{[^}]+\})(/(tcp|udp|sctp))?$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func diag(_ node: Node, _ message: String, _ severity: Diagnostic.Severity) -> Diagnostic {
        Diagnostic(line: node.mark?.line ?? 1, column: node.mark?.column ?? 1, message: message, severity: severity)
    }
}
