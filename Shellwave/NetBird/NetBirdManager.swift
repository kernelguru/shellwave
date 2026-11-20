import Citadel
import Foundation
import NBKit
import NIOCore
import NIOSSH

/// Machbarkeitstest: NetBird eingebettet (ohne VPN-Profil). Der Login läuft über
/// den originalen NetBird-Code (PKCE im Browser, Parameter vom Management-Server),
/// NetBird SSH bekommt das Token als Passwort.
@MainActor
final class NetBirdManager: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case running
        case failed(String)
    }

    struct Peer: Identifiable, Hashable, Decodable {
        var id: String { ip }
        let fqdn: String
        let ip: String
        let status: String
    }

    /// Offener Browser-Login.
    struct LoginPrompt: Identifiable, Equatable {
        var id: URL { url }
        let url: URL
        let userCode: String
    }

    static let shared = NetBirdManager()

    /// So lange wird ein Token wiederverwendet (NetBird SSH akzeptiert höchstens 10 Minuten).
    static let tokenCacheSeconds: TimeInterval = 300

    @Published var managementURL: String = UserDefaults.standard.string(forKey: "netbird.managementURL") ?? "" {
        didSet { UserDefaults.standard.set(managementURL, forKey: "netbird.managementURL") }
    }
    @Published private(set) var state: State = .idle
    @Published private(set) var log: [String] = []
    @Published private(set) var peers: [Peer] = []
    @Published private(set) var ownIP = ""
    /// Ist dieses Gerät schon als Peer registriert (Login über den Overlay-Start)?
    @Published private(set) var peerRegistered = UserDefaults.standard.bool(forKey: "netbird.registered") {
        didSet { UserDefaults.standard.set(peerRegistered, forKey: "netbird.registered") }
    }
    /// Läuft gerade ein Login (bis der Browser-Link da ist)?
    @Published private(set) var loginBusy = false
    @Published var loginPrompt: LoginPrompt?
    /// Bis wann das zwischengespeicherte Token benutzt wird.
    @Published private(set) var tokenValidUntil: Date?
    /// Startzeitpunkt des Overlay-Starts, für den Zähler in der Ansicht.
    @Published private(set) var startingSince: Date?
    /// Absturzmeldung des Go-Teils aus dem letzten Lauf.
    @Published private(set) var lastCrash = ""
    /// Ende des NetBird-Logs (go.log), auf Anfrage geladen.
    @Published private(set) var goLog = ""

    private var node: NbkitNode?
    private var token: String?
    private var tokenTask: Task<String, Error>?
    private var proxies: [String: Int] = [:]
    private let pending = PendingNode()

    static var directory: URL {
        JSONFile.directory.appendingPathComponent("netbird", isDirectory: true)
    }

    private static var appLogURL: URL { directory.appendingPathComponent("app.log") }

    private init() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        // Protokoll des letzten Laufs übernehmen, damit es einen Absturz überlebt.
        if let text = try? String(contentsOf: Self.appLogURL, encoding: .utf8) {
            log = text.split(separator: "\n").suffix(150).map(String.init)
        }
        // Alte Daten aus dem eigenen Device-Flow entfernen
        KeychainStore.delete(service: "netbird", account: "refresh")
        loadDiagnostics()
    }

    // MARK: Diagnose

    /// Liest die Go-Absturzmeldung des letzten Laufs.
    func loadDiagnostics() {
        let crash = NbkitLastCrash(Self.directory.path)
        if !crash.isEmpty, crash != lastCrash {
            lastCrash = crash
            note("Go-Absturz im letzten Lauf gefunden (siehe oben)")
        }
    }

    func clearCrash() {
        NbkitClearCrash(Self.directory.path)
        lastCrash = ""
    }

    func loadGoLog() {
        goLog = NbkitLogTail(Self.directory.path, 12_000)
        if goLog.isEmpty { goLog = "(leer – der Go-Teil wurde noch nicht gestartet)" }
    }

    // MARK: Protokoll

    func note(_ text: String) {
        let stamp = Date.now.formatted(date: .omitted, time: .standard)
        let line = "\(stamp)  \(text)"
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
        appendToFile(line)
    }

    private func appendToFile(_ line: String) {
        let data = Data((line.replacingOccurrences(of: "\n", with: " ") + "\n").utf8)
        let url = Self.appLogURL
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    func clearLog() {
        log = []
        try? FileManager.default.removeItem(at: Self.appLogURL)
    }

    /// Kurze, verständliche Fehlermeldung statt der langen NSError-Beschreibung.
    static func describe(_ error: Error) -> String {
        if let url = error as? URLError {
            switch url.code {
            case .timedOut: return "Server antwortet nicht"
            case .networkConnectionLost: return "Server hat die Verbindung abgebrochen"
            case .cannotConnectToHost: return "Server nicht erreichbar"
            case .cannotFindHost: return "Hostname nicht gefunden"
            case .notConnectedToInternet: return "Keine Internetverbindung"
            case .cancelled: return "Abgebrochen"
            default: return "Netzwerkfehler \(url.code.rawValue)"
            }
        }
        let text = TerminalSession.describe(error)
        if text.localizedCaseInsensitiveContains("context canceled") { return "Abgebrochen" }
        if text.localizedCaseInsensitiveContains("deadline exceeded") { return "Zeitlimit überschritten: \(text)" }
        return text
    }

    // MARK: Login (originaler NetBird-Ablauf)

    /// Zwischengespeichertes Token, solange es jung genug ist.
    private var cachedToken: String? {
        guard let token, let until = tokenValidUntil, until > .now else { return nil }
        return token
    }

    /// Token holen: aus dem Cache oder per Browser-Login. Läuft höchstens einmal gleichzeitig.
    func obtainToken() async throws -> String {
        if let cachedToken { return cachedToken }
        if let tokenTask { return try await tokenTask.value }
        let task = Task { try await requestToken() }
        tokenTask = task
        defer { tokenTask = nil }
        return try await task.value
    }

    /// Nur für die Schaltfläche „Anmelden“.
    func login() {
        Task {
            do { _ = try await obtainToken() } catch { report(error) }
        }
    }

    private func requestToken() async throws -> String {
        let url = managementURL.trimmed
        guard URL(string: url) != nil, !url.isEmpty else { throw NetBirdError.badURL }
        loginBusy = true
        defer { loginBusy = false }
        note("Login über NetBird (\(url)) …")

        let opener = LoginOpener { [weak self] link, code in
            Task { @MainActor in
                guard let self else { return }
                self.loginBusy = false
                if let target = URL(string: link) {
                    self.loginPrompt = LoginPrompt(url: target, userCode: code)
                    self.note(code.isEmpty ? "Browser-Login geöffnet" : "Browser-Login geöffnet, Code \(code)")
                } else {
                    self.note("Ungültiger Login-Link: \(link)")
                }
            }
        }
        defer { loginPrompt = nil }

        let jwt: String = try await Task.detached {
            var err: NSError?
            let t = NbkitRequestJWT(url, opener, 300, &err)
            if let err { throw err }
            return t
        }.value

        guard jwt.split(separator: ".").count == 3 else { throw NetBirdError.http("Kein JWT erhalten") }
        token = jwt
        let iat = (Self.claims(of: jwt)?["iat"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? .now
        tokenValidUntil = iat.addingTimeInterval(Self.tokenCacheSeconds)
        if let claims = Self.claims(of: jwt) {
            note("Angemeldet: \(claims["email"] ?? claims["sub"] ?? "?"), aud=\(claims["aud"] ?? "?")")
        }
        return jwt
    }

    /// Bricht den Browser-Login ab (gibt auch localhost:53000 wieder frei).
    func cancelLogin() {
        loginPrompt = nil
        Task.detached { NbkitCancelJWTRequest() }
        note("Login abgebrochen")
    }

    /// Verwirft das zwischengespeicherte Token.
    func forgetToken() {
        token = nil
        tokenValidUntil = nil
        note("Token verworfen")
    }

    private func report(_ error: Error) {
        let text = Self.describe(error)
        if text == "Abgebrochen" { return }
        note("Fehler: \(text)")
    }

    static func claims(of jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: Overlay

    func startOverlay() async {
        guard node == nil else { refreshPeers(); return }
        guard state != .starting else { return }
        state = .starting
        startingSince = .now
        defer { startingSince = nil }
        do {
            // Erstes Mal: Peer per Token registrieren. Danach reicht der gespeicherte Peer-Schlüssel.
            var jwt = cachedToken ?? ""
            if !peerRegistered && jwt.isEmpty {
                jwt = try await obtainToken()
                startingSince = .now
            }
            do {
                try await launch(jwt: jwt)
            } catch let error where jwt.isEmpty && Self.needsLogin(error) {
                note("Peer braucht eine neue Anmeldung …")
                let fresh = try await obtainToken()
                startingSince = .now
                try await launch(jwt: fresh)
            }
            peerRegistered = true
            state = .running
            note("Overlay läuft")
            refreshPeers()
        } catch is CancellationError {
            state = .idle
            note("Overlay-Start abgebrochen")
        } catch {
            state = .failed(Self.describe(error))
            note("Fehler: \(Self.describe(error))")
            loadDiagnostics()
        }
    }

    private func launch(jwt: String) async throws {
        let dir = Self.directory
        let url = managementURL.trimmed
        let name = "shellwave-" + DeviceKey.deviceSlug
        note("Starte Peer \(name)\(jwt.isEmpty ? "" : " mit Token") …")
        let pending = self.pending

        let node: NbkitNode = try await Task.detached {
            var err: NSError?
            guard let n = NbkitNewNode(url, "", jwt, name, dir.path, &err) else {
                throw err ?? NetBirdError.http("Peer konnte nicht angelegt werden")
            }
            pending.set(n)
            defer { pending.set(nil) }
            do {
                try n.start(40)
            } catch {
                if pending.wasCancelled { throw CancellationError() }
                throw error
            }
            if pending.wasCancelled {
                try? n.stop()
                throw CancellationError()
            }
            return n
        }.value
        self.node = node
    }

    private static func needsLogin(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return ["permission", "login", "expired", "unauthenticated", "jwt", "sso"].contains { text.contains($0) }
    }

    /// Bricht einen laufenden Overlay-Start ab.
    func cancelOverlayStart() {
        guard state == .starting else { return }
        note("Breche Overlay-Start ab …")
        if loginPrompt != nil { cancelLogin() }
        let pending = self.pending
        Task.detached { pending.cancel() }
    }

    func stopOverlay() async {
        guard let node else { return }
        self.node = nil
        proxies = [:]
        peers = []
        ownIP = ""
        _ = await Task.detached { try? node.stop() }.value
        state = .idle
        note("Overlay gestoppt")
    }

    /// Stoppt das Overlay und löscht Peer-Konfiguration, Logs und Absturzmeldungen.
    /// Beim nächsten Start meldet sich die App als neuer Peer an.
    func resetData() async {
        await stopOverlay()
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil) {
            for item in items { try? fm.removeItem(at: item) }
        }
        peerRegistered = false
        token = nil
        tokenValidUntil = nil
        lastCrash = ""
        goLog = ""
        state = .idle
        log = []
        note("NetBird-Daten zurückgesetzt. Den alten Peer „shellwave-…“ bitte im Dashboard löschen.")
    }

    func refreshPeers() {
        guard let node else { return }
        let json = node.statusJSON(nil)
        struct Status: Decodable { let ip: String; let fqdn: String; let peers: [Peer]? }
        if let status = try? JSONDecoder().decode(Status.self, from: Data(json.utf8)) {
            ownIP = status.ip
            peers = (status.peers ?? []).sorted { $0.fqdn < $1.fqdn }
        }
    }

    // MARK: NetBird SSH

    /// Lokaler Port, der über das Overlay zu peerIP:22022 (NetBird SSH) führt.
    private func proxyPort(for peerIP: String) throws -> Int {
        if let port = proxies[peerIP] { return port }
        guard let node else { throw NetBirdError.notRunning }
        var port = 0
        try node.startProxy("\(peerIP):22022", ret0_: &port)
        proxies[peerIP] = port
        return port
    }

    /// Verbindet per NetBird SSH und führt einen Befehl aus.
    func runTest(peer: Peer, username: String, command: String) async -> String {
        do {
            let token = try await obtainToken()
            let port = try proxyPort(for: peer.ip)
            note("SSH \(username)@\(peer.fqdn) über 127.0.0.1:\(port)")
            let validator = NetBirdHostKeyValidator(node: node, peerAddress: peer.ip) { [weak self] text in
                Task { @MainActor in self?.note(text) }
            }
            let settings = SSHClientSettings(
                host: "127.0.0.1",
                port: port,
                authenticationMethod: { .passwordBased(username: username, password: token) },
                hostKeyValidator: .custom(validator)
            )
            let client = try await SSHClient.connect(to: settings)
            let result = try await SSHConnector.runCapturing(command, on: client)
            try? await client.close()
            note("Exit \(result.exitCode)")
            return result.output
        } catch {
            note("Fehler: \(Self.describe(error))")
            return "Fehler: \(Self.describe(error))"
        }
    }
}

/// Brücke für den Go-Callback „Browser öffnen“.
final class LoginOpener: NSObject, NbkitURLOpenerProtocol, @unchecked Sendable {
    private let handler: @Sendable (String, String) -> Void

    init(handler: @escaping @Sendable (String, String) -> Void) {
        self.handler = handler
    }

    func open(_ url: String?, userCode: String?) {
        handler(url ?? "", userCode ?? "")
    }
}

/// Hält den Peer, solange er startet, damit ein Abbrechen ihn stoppen kann.
final class PendingNode: @unchecked Sendable {
    private let lock = NSLock()
    private var node: NbkitNode?
    private var cancelled = false

    func set(_ node: NbkitNode?) {
        lock.lock()
        self.node = node
        if node != nil { cancelled = false }
        lock.unlock()
    }

    var wasCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let node = self.node
        lock.unlock()
        try? node?.stop()
    }
}

/// Prüft den Host-Key des Peers gegen den Schlüssel, den NetBird verteilt hat.
final class NetBirdHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let node: NbkitNode?
    private let peerAddress: String
    private let report: @Sendable (String) -> Void

    init(node: NbkitNode?, peerAddress: String, report: @escaping @Sendable (String) -> Void) {
        self.node = node
        self.peerAddress = peerAddress
        self.report = report
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let line = String(openSSHPublicKey: hostKey)
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])), let node else {
            validationCompletePromise.fail(NetBirdError.hostKey("Host-Key nicht lesbar"))
            return
        }
        do {
            try node.verifySSHHostKey(peerAddress, key: blob)
            report("Host-Key von NetBird bestätigt (\(TOFUHostKeyValidator.fingerprint(of: line)))")
            validationCompletePromise.succeed(())
        } catch {
            // Für den Test nicht hart abbrechen, sondern sichtbar machen
            report("Host-Key NICHT bestätigt: \(error.localizedDescription) – Test läuft trotzdem weiter")
            validationCompletePromise.succeed(())
        }
    }
}

enum NetBirdError: LocalizedError {
    case badURL, noDeviceFlow, notLoggedIn, notRunning
    case http(String)
    case hostKey(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Ungültige Management-URL."
        case .noDeviceFlow: return "Der IdP bietet keinen Device-Flow an."
        case .notLoggedIn: return "Nicht angemeldet."
        case .notRunning: return "Overlay läuft nicht."
        case .http(let m): return m
        case .hostKey(let m): return m
        }
    }
}
