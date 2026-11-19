import Citadel
import Foundation
import NBKit
import NIOCore
import NIOSSH

/// Machbarkeitstest: NetBird eingebettet (ohne VPN-Profil), Login über den eingebauten
/// IdP (Device-Flow mit Client „netbird-cli“) und NetBird SSH mit dem Token als Passwort.
@MainActor
final class NetBirdManager: ObservableObject {
    enum State: Equatable {
        case idle
        case loggingIn(userCode: String, url: URL)
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

    static let shared = NetBirdManager()

    @Published var managementURL: String = UserDefaults.standard.string(forKey: "netbird.managementURL") ?? "" {
        didSet { UserDefaults.standard.set(managementURL, forKey: "netbird.managementURL") }
    }
    @Published private(set) var state: State = .idle
    @Published private(set) var log: [String] = []
    @Published private(set) var peers: [Peer] = []
    @Published private(set) var ownIP = ""
    @Published private(set) var loggedIn = KeychainStore.get(service: "netbird", account: "refresh") != nil
    /// Läuft gerade eine Anfrage an den IdP (Discovery, Device-Code, Token)?
    @Published private(set) var loginBusy = false
    /// Startzeitpunkt des Overlay-Starts, für den Zähler in der Ansicht.
    @Published private(set) var startingSince: Date?
    /// Absturzmeldung des Go-Teils aus dem letzten Lauf.
    @Published private(set) var lastCrash = ""
    /// Ende des NetBird-Logs (go.log), auf Anfrage geladen.
    @Published private(set) var goLog = ""

    private var node: NbkitNode?
    private var accessToken: String?
    private var proxies: [String: Int] = [:]
    private var loginTask: Task<Void, Never>?
    private let pending = PendingNode()

    /// Kurze Zeitlimits, damit ein hängender IdP sofort auffällt.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

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
        loadDiagnostics()
    }

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

    private static let clientID = "netbird-cli"
    private static let scopes = "openid profile email groups offline_access"

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
            let host = url.failingURL?.path ?? ""
            switch url.code {
            case .timedOut: return "Server antwortet nicht innerhalb von 20 s (\(host))"
            case .networkConnectionLost: return "Server hat die Verbindung abgebrochen (\(host))"
            case .cannotConnectToHost: return "Server nicht erreichbar (\(host))"
            case .cannotFindHost: return "Hostname nicht gefunden"
            case .notConnectedToInternet: return "Keine Internetverbindung"
            case .cancelled: return "Abgebrochen"
            default: return "Netzwerkfehler \(url.code.rawValue) (\(host))"
            }
        }
        return TerminalSession.describe(error)
    }

    // MARK: OIDC (eingebauter IdP von NetBird = Dex unter <management>/oauth2)

    private struct Discovery: Decodable {
        let issuer: String
        let token_endpoint: String
        let device_authorization_endpoint: String?
    }

    private var issuer: String {
        var base = managementURL.trimmed
        while base.hasSuffix("/") { base.removeLast() }
        return base + "/oauth2"
    }

    private func discover() async throws -> Discovery {
        guard let url = URL(string: issuer + "/.well-known/openid-configuration") else { throw NetBirdError.badURL }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NetBirdError.http("OIDC-Discovery unter \(url.absoluteString) fehlgeschlagen")
        }
        return try JSONDecoder().decode(Discovery.self, from: data)
    }

    private func post(_ endpoint: String, _ form: [String: String]) async throws -> (Int, [String: Any]) {
        guard let url = URL(string: endpoint) else { throw NetBirdError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, response) = try await session.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, json)
    }

    /// Device-Flow: Code anzeigen, Browser öffnen, Token abholen.
    func startLogin() {
        // Kein Abbrechen bei erneutem Tippen: das erzeugte nur verwaiste Anfragen am IdP.
        guard loginTask == nil else { return }
        loginTask = Task {
            await login()
            loginTask = nil
        }
    }

    func cancelLogin() {
        loginTask?.cancel()
        loginTask = nil
        if case .loggingIn = state { state = .idle }
    }

    private func login() async {
        loginBusy = true
        defer { loginBusy = false }
        do {
            let d = try await discover()
            note("Issuer: \(d.issuer)")
            guard let deviceEndpoint = d.device_authorization_endpoint else { throw NetBirdError.noDeviceFlow }
            let (code, start) = try await post(deviceEndpoint, ["client_id": Self.clientID, "scope": Self.scopes])
            guard code == 200, let deviceCode = start["device_code"] as? String,
                  let userCode = start["user_code"] as? String else {
                throw NetBirdError.http("Device-Flow abgelehnt: \(start["error_description"] ?? start["error"] ?? code)")
            }
            let verify = (start["verification_uri_complete"] as? String) ?? (start["verification_uri"] as? String) ?? ""
            guard let verifyURL = URL(string: verify) else { throw NetBirdError.badURL }
            var interval = UInt64((start["interval"] as? Int) ?? 5)
            state = .loggingIn(userCode: userCode, url: verifyURL)
            loginBusy = false
            note("Login gestartet, Code \(userCode)")

            while true {
                try await Task.sleep(nanoseconds: interval * 1_000_000_000)
                let (status, body) = try await post(d.token_endpoint, [
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                    "device_code": deviceCode,
                    "client_id": Self.clientID,
                ])
                if status == 200 {
                    try storeTokens(body)
                    state = .idle
                    note("Angemeldet. Refresh-Token: \(body["refresh_token"] != nil ? "ja" : "NEIN")")
                    return
                }
                switch body["error"] as? String {
                case "authorization_pending": continue
                case "slow_down": interval += 5
                default: throw NetBirdError.http("Token-Abruf: \(body["error_description"] ?? body["error"] ?? status)")
                }
            }
        } catch is CancellationError {
            note("Login abgebrochen")
        } catch {
            state = .failed(Self.describe(error))
            note("Fehler: \(Self.describe(error))")
        }
    }

    private func storeTokens(_ body: [String: Any]) throws {
        let access = body["access_token"] as? String
        let id = body["id_token"] as? String
        // NetBird prüft ein JWT; Dex liefert Access-Tokens als JWT, sonst ID-Token nehmen.
        if let access, access.split(separator: ".").count == 3 {
            accessToken = access
        } else if let id {
            accessToken = id
        } else {
            throw NetBirdError.http("Kein JWT in der Antwort")
        }
        if let refresh = body["refresh_token"] as? String {
            KeychainStore.setString(refresh, service: "netbird", account: "refresh")
        }
        loggedIn = true
        if let claims = Self.claims(of: accessToken ?? "") {
            note("Token: sub=\(claims["sub"] ?? "?"), aud=\(claims["aud"] ?? "?"), email=\(claims["email"] ?? "-")")
        }
    }

    /// Frisches Token (jünger als 5 Minuten, NetBird SSH akzeptiert höchstens 10).
    func freshToken() async throws -> String {
        if let token = accessToken, let iat = Self.claims(of: token)?["iat"] as? Double,
           Date.now.timeIntervalSince1970 - iat < 300 {
            return token
        }
        let refresh = KeychainStore.string(service: "netbird", account: "refresh")
        guard !refresh.isEmpty else { throw NetBirdError.notLoggedIn }
        let d = try await discover()
        let (status, body) = try await post(d.token_endpoint, [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": Self.clientID,
        ])
        guard status == 200 else {
            throw NetBirdError.http("Refresh fehlgeschlagen: \(body["error_description"] ?? body["error"] ?? status)")
        }
        try storeTokens(body)
        note("Token still erneuert")
        return accessToken!
    }

    func logout() {
        KeychainStore.delete(service: "netbird", account: "refresh")
        accessToken = nil
        loggedIn = false
        note("Abgemeldet")
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
            let token = try await freshToken()
            let dir = Self.directory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = managementURL.trimmed
            let name = "shellwave-" + DeviceKey.deviceSlug
            note("Starte Peer \(name) …")
            let pending = self.pending

            let node: NbkitNode = try await Task.detached {
                var err: NSError?
                guard let n = NbkitNewNode(url, "", token, name, dir.path, &err) else {
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

    /// Bricht einen laufenden Overlay-Start ab.
    func cancelOverlayStart() {
        guard state == .starting else { return }
        note("Breche Overlay-Start ab …")
        let pending = self.pending
        Task.detached { pending.cancel() }
    }

    /// Stoppt das Overlay und löscht Peer-Konfiguration, Logs und Absturzmeldungen.
    /// Beim nächsten Start meldet sich die App als neuer Peer an.
    func resetData() async {
        await stopOverlay()
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil) {
            for item in items { try? fm.removeItem(at: item) }
        }
        lastCrash = ""
        goLog = ""
        state = .idle
        log = []
        note("NetBird-Daten zurückgesetzt. Den alten Peer „shellwave-…“ bitte im Dashboard löschen.")
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
            let token = try await freshToken()
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
