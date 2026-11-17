import Citadel
import Foundation

/// Richtet einen Server für den Login mit UCM-Zertifikaten ein – ohne Aussperren:
/// Die Einrichtungs-Verbindung bleibt offen, bis ein Test-Login mit Zertifikat geklappt hat.
@MainActor
final class ServerSetup: ObservableObject {
    enum StepState: Equatable { case running, ok, failed, skipped }

    struct Step: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var detail: String = ""
        var state: StepState = .running
    }

    struct Options {
        var bootstrap: SSHConnector.AuthOverride
        var bootstrapPassword: String?
        var mappings: [PrincipalMapping]
        var installMosh: Bool
        var installClaude: Bool
    }

    struct SystemInfo {
        var uid = ""
        var osID = ""
        var isUnraid = false
        var hasDropIn = false
        var sshdVersion = ""
        var packageManager = ""
    }

    @Published private(set) var steps: [Step] = []
    @Published private(set) var running = false
    @Published private(set) var succeeded = false
    @Published private(set) var scriptPreview = ""

    private let ucm: UCMSettings
    private let certificates: CertificateManager
    private let hosts: HostStore

    init(ucm: UCMSettings, certificates: CertificateManager, hosts: HostStore) {
        self.ucm = ucm
        self.certificates = certificates
        self.hosts = hosts
    }

    func reset() {
        guard !running else { return }
        steps = []
        succeeded = false
        scriptPreview = ""
    }

    // MARK: Ablauf

    func run(host: Host, options: Options) async {
        guard !running else { return }
        running = true
        succeeded = false
        steps = []
        defer { running = false }

        var setupClient: SSHClient?
        do {
            // 1. Verbinden
            begin("Verbinden als \(host.username)")
            let client = try await SSHConnector.connect(to: host, certificates: certificates, hosts: hosts, override: options.bootstrap)
            setupClient = client
            done()

            // 2. System erkennen
            begin("System erkennen")
            let info = try await detect(on: client)
            done(info.isUnraid ? "Unraid" : (info.osID.isEmpty ? "Linux" : info.osID)
                 + (info.uid == "0" ? ", root" : ", sudo") + (info.hasDropIn ? ", sshd_config.d" : ""))

            // 3. CA-Key aus UCM
            begin("CA-Public-Key von UCM holen")
            let caKey = try await fetchCAKey()
            done(TOFUHostKeyValidator.fingerprint(of: caKey))

            // 4. Einrichten
            begin("sshd konfigurieren")
            let script = Self.makeScript(caKey: caKey, mappings: options.mappings, info: info, installMosh: options.installMosh)
            scriptPreview = script
            let result = try await runAsRoot(script, info: info, password: options.bootstrapPassword, on: client)
            guard result.output.contains("SW_RESULT=OK") else {
                throw SetupError.scriptFailed(Self.tail(result.output))
            }
            done(Self.summary(of: result.output))

            // 5. Test-Login mit Zertifikat
            begin("Test-Login mit Zertifikat")
            let loginPrincipals = options.mappings.first { $0.user == host.username }?.principals ?? host.effectivePrincipals
            var testHost = host
            testHost.auth = .certificate
            testHost.principals = loginPrincipals
            do {
                try await certificates.renew(principals: loginPrincipals)
                let test = try await SSHConnector.connect(to: testHost, certificates: certificates, hosts: hosts)
                let check = try await SSHConnector.runCapturing("echo SW_LOGIN_OK", on: test)
                try? await test.close()
                guard check.output.contains("SW_LOGIN_OK") else { throw SetupError.loginTestFailed("keine Antwort") }
                done("Login als \(host.username) mit \(loginPrincipals.joined(separator: ", "))")
            } catch {
                fail(TerminalSession.describe(error))
                begin("Änderungen zurücknehmen")
                let rollback = try await runAsRoot(Self.rollbackScript(info: info), info: info, password: options.bootstrapPassword, on: client)
                done(rollback.output.contains("SW_RESULT=OK") ? "Alte Konfiguration wiederhergestellt" : Self.tail(rollback.output))
                try? await client.close()
                return
            }

            // 6. Claude Code (optional, als Login-Benutzer)
            if options.installClaude {
                begin("Claude Code installieren")
                let claude = try await SSHConnector.runCapturing(Self.claudeInstallCommand, on: client)
                if claude.output.contains("SW_CLAUDE_OK") {
                    done(Self.tail(claude.output, lines: 1).replacingOccurrences(of: "SW_CLAUDE_OK", with: "").trimmed)
                } else {
                    fail(Self.tail(claude.output))
                }
            }

            // 7. Host übernehmen
            var updated = hosts.hosts.first { $0.id == host.id } ?? host
            updated.auth = .certificate
            updated.principals = loginPrincipals
            updated.principalMap = options.mappings
            updated.setupDone = true
            hosts.upsert(updated)
            begin("Host auf Zertifikats-Login umgestellt")
            done()
            succeeded = true
        } catch {
            fail(TerminalSession.describe(error))
        }
        try? await setupClient?.close()
    }

    /// Nur das Skript erzeugen (für die Vorschau), ohne zu verbinden.
    func preview(host: Host, mappings: [PrincipalMapping], installMosh: Bool) async {
        let caKey = (try? await fetchCAKey()) ?? "<CA-Public-Key aus UCM>"
        var info = SystemInfo()
        info.hasDropIn = true
        scriptPreview = Self.makeScript(caKey: caKey, mappings: mappings, info: info, installMosh: installMosh)
    }

    // MARK: Schritte

    private func begin(_ title: String) {
        steps.append(Step(title: title))
    }

    private func done(_ detail: String = "") {
        guard !steps.isEmpty else { return }
        steps[steps.count - 1].state = .ok
        if !detail.isEmpty { steps[steps.count - 1].detail = detail }
    }

    private func fail(_ detail: String) {
        guard !steps.isEmpty else { return }
        steps[steps.count - 1].state = .failed
        steps[steps.count - 1].detail = detail
    }

    // MARK: Server-Seite

    private func detect(on client: SSHClient) async throws -> SystemInfo {
        let cmd = """
        echo "UID=$(id -u)"; \
        . /etc/os-release 2>/dev/null; echo "OS=${ID:-}"; \
        test -f /etc/unraid-version && echo UNRAID; \
        if [ -d /etc/ssh/sshd_config.d ] && grep -Eiq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d' /etc/ssh/sshd_config 2>/dev/null; then echo DROPIN; fi; \
        echo "SSHD=$( (sshd -V 2>&1 || /usr/sbin/sshd -V 2>&1) | head -1)"; \
        for p in apt-get dnf yum apk pacman zypper; do command -v $p >/dev/null 2>&1 && { echo "PKG=$p"; break; }; done
        """
        let out = try await SSHConnector.runCapturing(cmd, on: client).output
        var info = SystemInfo()
        for line in out.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("UID=") { info.uid = String(line.dropFirst(4)) }
            else if line.hasPrefix("OS=") { info.osID = String(line.dropFirst(3)) }
            else if line == "UNRAID" { info.isUnraid = true }
            else if line == "DROPIN" { info.hasDropIn = true }
            else if line.hasPrefix("SSHD=") { info.sshdVersion = String(line.dropFirst(5)) }
            else if line.hasPrefix("PKG=") { info.packageManager = String(line.dropFirst(4)) }
        }
        if info.isUnraid { info.hasDropIn = false }
        return info
    }

    private func fetchCAKey() async throws -> String {
        guard ucm.caID > 0 else { throw SetupError.noCA }
        let cas = try await ucm.client().listCAs()
        guard let ca = cas.first(where: { $0.id == ucm.caID }), let key = ca.publicKey?.trimmed, !key.isEmpty else {
            throw SetupError.noCA
        }
        return key
    }

    private func runAsRoot(_ script: String, info: SystemInfo, password: String?, on client: SSHClient) async throws -> (output: String, exitCode: Int) {
        let b64 = Data(script.utf8).base64EncodedString()
        let file = "/tmp/shellwave-setup-$$.sh"
        let runner: String
        if info.uid == "0" {
            runner = "sh \(file)"
        } else if let password, !password.isEmpty {
            runner = "printf '%s\\n' \(SSHConnector.quote(password)) | sudo -S -p '' sh \(file)"
        } else {
            runner = "sudo -n sh \(file)"
        }
        let command = "echo \(b64) | base64 -d > \(file) && \(runner); rc=$?; rm -f \(file); exit $rc"
        return try await SSHConnector.runCapturing(command, on: client)
    }

    // MARK: Skripte

    static let marker = "shellwave-ucm"

    static func makeScript(caKey: String, mappings: [PrincipalMapping], info: SystemInfo, installMosh: Bool) -> String {
        var s = """
        #!/bin/sh
        # Shellwave: Login mit UCM-SSH-Zertifikaten einrichten
        set -u
        CA_FILE=/etc/ssh/ucm_user_ca.pub
        PRIN_DIR=/etc/ssh/auth_principals
        CONF=/etc/ssh/sshd_config
        BACKUP=/etc/ssh/sshd_config.shellwave.bak
        DROPIN=/etc/ssh/sshd_config.d/50-\(marker).conf

        cp "$CONF" "$BACKUP" || { echo "SW_RESULT=NO_BACKUP"; exit 1; }
        printf '%s\\n' \(SSHConnector.quote(caKey)) > "$CA_FILE"
        chmod 644 "$CA_FILE"
        mkdir -p "$PRIN_DIR"
        chmod 755 "$PRIN_DIR"

        """

        for m in mappings where !m.user.trimmed.isEmpty {
            let user = m.user.trimmed
            let lines = m.principals.map { SSHConnector.quote($0) }.joined(separator: " ")
            s += "printf '%s\\n' \(lines) > \"$PRIN_DIR/\(user)\"\n"
            s += "chmod 644 \"$PRIN_DIR/\(user)\"\n"
            s += "echo \"principals \(user): \(m.principals.joined(separator: ", "))\"\n"
        }

        let block = """
        # >>> \(marker)
        TrustedUserCAKeys /etc/ssh/ucm_user_ca.pub
        AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u
        # <<< \(marker)
        """

        if info.hasDropIn {
            s += """

            cat > "$DROPIN" <<'SWEOF'
            \(block)
            SWEOF
            chmod 644 "$DROPIN"
            echo "config: $DROPIN"

            """
        } else {
            s += """

            sed -i '/# >>> \(marker)/,/# <<< \(marker)/d' "$CONF"
            # Am Anfang einfügen, damit kein Match-Block die Optionen verschluckt
            { cat <<'SWEOF'
            \(block)
            SWEOF
            cat "$BACKUP" | sed '/# >>> \(marker)/,/# <<< \(marker)/d'; } > "$CONF.shellwave.new" && cat "$CONF.shellwave.new" > "$CONF" && rm -f "$CONF.shellwave.new"
            echo "config: $CONF"

            """
        }

        s += """

        SSHD=$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)
        if ! "$SSHD" -t 2>/tmp/shellwave-sshd.err; then
          cat /tmp/shellwave-sshd.err
          cp "$BACKUP" "$CONF"
          rm -f "$DROPIN"
          echo "SW_RESULT=CONFIG_INVALID"
          exit 1
        fi

        """

        if info.isUnraid {
            s += """
            # Unraid: /etc/ssh liegt im RAM -> auf dem USB-Stick sichern und beim Booten wiederherstellen
            PERSIST=/boot/config/ssh/shellwave
            mkdir -p "$PERSIST"
            cp "$CA_FILE" "$PERSIST/"
            rm -rf "$PERSIST/auth_principals" && cp -r "$PRIN_DIR" "$PERSIST/auth_principals"
            printf '%s\\n' '# >>> \(marker)' 'TrustedUserCAKeys /etc/ssh/ucm_user_ca.pub' 'AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u' '# <<< \(marker)' > "$PERSIST/sshd_block"
            GO=/boot/config/go
            sed -i '/# >>> \(marker)/,/# <<< \(marker)/d' "$GO"
            cat >> "$GO" <<'SWEOF'
            # >>> \(marker)
            cp /boot/config/ssh/shellwave/ucm_user_ca.pub /etc/ssh/ && rm -rf /etc/ssh/auth_principals && cp -r /boot/config/ssh/shellwave/auth_principals /etc/ssh/
            grep -q '\(marker)' /etc/ssh/sshd_config || { cat /boot/config/ssh/shellwave/sshd_block /etc/ssh/sshd_config > /tmp/sshd_config.sw && cat /tmp/sshd_config.sw > /etc/ssh/sshd_config; }
            /etc/rc.d/rc.sshd reload >/dev/null 2>&1 || /etc/rc.d/rc.sshd restart
            # <<< \(marker)
            SWEOF
            echo "unraid: persistiert in $PERSIST und /boot/config/go"
            /etc/rc.d/rc.sshd reload >/dev/null 2>&1 || /etc/rc.d/rc.sshd restart

            """
        } else {
            s += """
            if command -v systemctl >/dev/null 2>&1; then
              systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl restart sshd
            elif command -v rc-service >/dev/null 2>&1; then
              rc-service sshd reload || rc-service sshd restart
            elif [ -f /var/run/sshd.pid ]; then
              kill -HUP "$(cat /var/run/sshd.pid)"
            fi
            echo "sshd neu geladen"

            """
        }

        if installMosh && !info.isUnraid {
            s += """
            if ! command -v mosh-server >/dev/null 2>&1; then
              if command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get install -y mosh >/dev/null 2>&1
              elif command -v dnf >/dev/null 2>&1; then dnf install -y mosh >/dev/null 2>&1
              elif command -v yum >/dev/null 2>&1; then yum install -y mosh >/dev/null 2>&1
              elif command -v apk >/dev/null 2>&1; then apk add mosh >/dev/null 2>&1
              elif command -v pacman >/dev/null 2>&1; then pacman -S --noconfirm mosh >/dev/null 2>&1
              elif command -v zypper >/dev/null 2>&1; then zypper -n in mosh >/dev/null 2>&1
              fi
            fi
            command -v mosh-server >/dev/null 2>&1 && echo "mosh: $(mosh-server --version 2>&1 | head -1)" || echo "mosh: nicht installiert"

            """
        }

        s += "echo SW_RESULT=OK\n"
        return s
    }

    static func rollbackScript(info: SystemInfo) -> String {
        """
        #!/bin/sh
        CONF=/etc/ssh/sshd_config
        BACKUP=/etc/ssh/sshd_config.shellwave.bak
        [ -f "$BACKUP" ] && cp "$BACKUP" "$CONF"
        rm -f /etc/ssh/sshd_config.d/50-\(marker).conf
        \(info.isUnraid ? "sed -i '/# >>> \(marker)/,/# <<< \(marker)/d' /boot/config/go; /etc/rc.d/rc.sshd reload" : "systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || rc-service sshd reload 2>/dev/null || kill -HUP \"$(cat /var/run/sshd.pid)\"")
        echo SW_RESULT=OK
        """
    }

    static let claudeInstallCommand = """
    export PATH="$HOME/.local/bin:$PATH"; \
    if command -v claude >/dev/null 2>&1; then echo "SW_CLAUDE_OK bereits installiert: $(claude --version 2>&1 | head -1)"; \
    elif command -v curl >/dev/null 2>&1; then curl -fsSL https://claude.ai/install.sh | bash >/tmp/shellwave-claude.log 2>&1; \
      if command -v claude >/dev/null 2>&1 || [ -x "$HOME/.local/bin/claude" ]; then echo "SW_CLAUDE_OK installiert: $("$HOME/.local/bin/claude" --version 2>&1 | head -1)"; else tail -5 /tmp/shellwave-claude.log; fi; \
    else echo "curl fehlt"; fi
    """

    static func tail(_ text: String, lines: Int = 6) -> String {
        text.split(whereSeparator: \.isNewline).suffix(lines).joined(separator: "\n")
    }

    static func summary(of output: String) -> String {
        output.split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.hasPrefix("SW_RESULT") && !$0.trimmed.isEmpty }
            .suffix(6)
            .joined(separator: "\n")
    }
}

enum SetupError: LocalizedError {
    case noCA
    case scriptFailed(String)
    case loginTestFailed(String)

    var errorDescription: String? {
        switch self {
        case .noCA: return "Keine User-CA in UCM gewählt oder ohne Public Key. Bitte in den Einstellungen CAs laden."
        case .scriptFailed(let out): return "Einrichtung fehlgeschlagen:\n\(out)"
        case .loginTestFailed(let why): return "Test-Login fehlgeschlagen: \(why)"
        }
    }
}
