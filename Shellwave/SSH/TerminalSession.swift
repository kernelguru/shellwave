import Citadel
import Darwin
import Foundation
import MoshKit
import NIOCore
import NIOSSH
import SwiftTerm
import UIKit

/// Eine interaktive Session: SSH oder Mosh, PTY und der Datenfluss zwischen Server und Terminal.
@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    enum State: Equatable {
        case idle
        case renewingCertificate
        case connecting
        case connected
        case closed
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "Bereit"
            case .renewingCertificate: return "Zertifikat wird erneuert …"
            case .connecting: return "Verbinde …"
            case .connected: return "Verbunden"
            case .closed: return "Getrennt"
            case .failed: return "Fehler"
            }
        }

        var isActive: Bool {
            switch self {
            case .renewingCertificate, .connecting, .connected: return true
            default: return false
            }
        }
    }

    let id = UUID()
    private let initialHost: Host
    /// Immer die aktuell gespeicherte Fassung des Hosts (Änderungen gelten beim nächsten Verbinden).
    var host: Host { hosts.hosts.first { $0.id == initialHost.id } ?? initialHost }
    @Published private(set) var state: State = .idle {
        didSet { if oldValue != state { onStateChange?(self) } }
    }
    @Published private(set) var title: String = ""
    /// Tatsächlich genutzter Transport (Mosh fällt bei Problemen auf SSH zurück).
    @Published private(set) var activeTransport: Transport = .ssh
    @Published private(set) var startedAt = Date.now

    /// Wird bei jedem Statuswechsel gerufen (Live Activity, Keep-alive).
    var onStateChange: ((TerminalSession) -> Void)?

    /// Die Terminal-View gehört zur Session, damit Bildschirm und Scrollback erhalten bleiben,
    /// wenn man die Session zuklappt und später wieder öffnet.
    lazy var terminalView: TerminalView = {
        let view = TerminalView(frame: .zero, font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        view.optionAsMetaKey = true
        TerminalThemeStore.apply(TerminalThemeStore.current, to: view)
        return view
    }()

    /// Claude-Assistent dieser Session (wird beim ersten Öffnen erzeugt).
    lazy var claude: ClaudeAgent = ClaudeAgent(session: self)

    let certificates: CertificateManager
    let hosts: HostStore
    private var client: SSHClient?
    private var mosh: MoshRunner?
    private var runTask: Task<Void, Never>?
    private var inputContinuation: AsyncStream<[UInt8]>.Continuation?
    private var size = (cols: 80, rows: 24)
    private var resizeHandler: ((Int, Int) async -> Void)?

    init(host: Host, certificates: CertificateManager, hosts: HostStore) {
        self.initialHost = host
        self.certificates = certificates
        self.hosts = hosts
        self.title = host.displayName
        self.activeTransport = host.transport
    }

    // MARK: Steuerung

    func start() {
        guard runTask == nil else { return }
        startedAt = .now
        runTask = Task { [weak self] in
            await self?.run()
        }
    }

    func reconnect() {
        teardown()
        state = .idle
        start()
    }

    func disconnect() {
        teardown()
        if state.isActive { state = .closed }
        // Getrennt: das NetBird-Overlay wird für diese Sitzung nicht mehr gebraucht.
        NetBirdManager.shared.release(id)
    }

    private func teardown() {
        inputContinuation?.finish()
        inputContinuation = nil
        mosh?.stop()
        mosh = nil
        runTask?.cancel()
        runTask = nil
        resizeHandler = nil
        let client = self.client
        self.client = nil
        if let client { SharedConnections.shared.unregister(client, for: initialHost.id) }
        Task { try? await client?.close() }
    }

    /// Tastatureingaben vom Terminal.
    func send(_ bytes: [UInt8]) {
        if let mosh {
            mosh.write(bytes)
        } else {
            inputContinuation?.yield(bytes)
        }
    }

    func send(text: String) {
        send(Array(text.utf8))
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        size = (cols, rows)
        mosh?.resize(cols: cols, rows: rows)
        if let handler = resizeHandler {
            Task { await handler(cols, rows) }
        }
    }

    func setTitle(_ t: String) {
        title = t.isEmpty ? host.displayName : t
    }

    /// Letzte Ausgaben als Rohdaten (für Claude-Kontext), auf 24 KB begrenzt.
    private var recentOutput: [UInt8] = []

    private func record(_ bytes: [UInt8]) {
        recentOutput.append(contentsOf: bytes)
        if recentOutput.count > 24_000 {
            recentOutput.removeFirst(recentOutput.count - 24_000)
        }
    }

    /// Ausgabe ins Terminal schreiben und für den Kontext merken.
    private func display(_ bytes: [UInt8]) {
        terminalView.feed(byteArray: bytes[...])
        record(bytes)
    }

    /// Letzte Zeilen der Ausgabe als Klartext ohne Steuerzeichen (Kontext für Claude).
    func screenText(lines: Int = 40) -> String {
        let text = ANSIStripper.strip(String(decoding: recentOutput, as: UTF8.self))
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        return all.suffix(lines).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Ablauf

    private func run() async {
        if host.isNetBird {
            NetBirdManager.shared.acquire(id)
        } else if host.transport == .mosh {
            do {
                try await runMosh()
                return
            } catch is CancellationError {
                state = .closed
                runTask = nil
                return
            } catch {
                // Mosh nicht verfügbar: sichtbar machen und mit SSH weiter.
                let note = "\r\n\u{1B}[33m[Shellwave] Mosh nicht möglich: \(Self.describe(error)) – weiter mit SSH.\u{1B}[0m\r\n"
                terminalView.feed(text: note)
            }
        }
        await runSSH()
    }

    private func runSSH() async {
        activeTransport = host.isNetBird ? .netbird : .ssh
        do {
            state = host.auth == .certificate && !host.isNetBird ? .renewingCertificate : .connecting
            let client = try await SSHConnector.connect(to: host, certificates: certificates, hosts: hosts)
            state = .connecting
            self.client = client
            SharedConnections.shared.register(client, for: initialHost.id)

            let (stream, continuation) = AsyncStream<[UInt8]>.makeStream()
            inputContinuation = continuation

            let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: "xterm-256color",
                terminalCharacterWidth: size.cols,
                terminalRowHeight: size.rows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: SSHTerminalModes([:])
            )

            state = .connected
            try await client.withPTY(pty) { inbound, outbound in
                self.resizeHandler = { cols, rows in
                    try? await outbound.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
                }
                try? await outbound.changeSize(cols: self.size.cols, rows: self.size.rows, pixelWidth: 0, pixelHeight: 0)

                let writer = Task {
                    for await chunk in stream {
                        try? await outbound.write(ByteBuffer(bytes: chunk))
                    }
                }
                defer { writer.cancel() }

                if let attach = self.tmuxAttachCommand {
                    try? await outbound.write(ByteBuffer(string: attach + "\r"))
                }

                for try await event in inbound {
                    switch event {
                    case .stdout(let buffer), .stderr(let buffer):
                        self.display(Array(buffer.readableBytesView))
                    }
                }
            }
            resizeHandler = nil
            if state == .connected { state = .closed }
        } catch is CancellationError {
            state = .closed
        } catch {
            resizeHandler = nil
            if runTask != nil { state = .failed(Self.describe(error)) }
        }
        if let client { SharedConnections.shared.unregister(client, for: initialHost.id) }
        try? await client?.close()
        client = nil
        runTask = nil
    }

    /// Befehl für tmux-Auto-Attach; fällt auf die normale Shell zurück, wenn tmux fehlt.
    private var tmuxAttachCommand: String? {
        let name = host.tmuxSession.trimmed
        guard !name.isEmpty else { return nil }
        let q = SSHConnector.quote(name)
        return "command -v tmux >/dev/null 2>&1 && exec tmux new-session -A -s \(q)"
    }

    // MARK: Mosh

    private func runMosh() async throws {
        activeTransport = .mosh
        state = host.auth == .certificate ? .renewingCertificate : .connecting
        let bootstrapClient = try await SSHConnector.connect(to: host, certificates: certificates, hosts: hosts)
        state = .connecting

        var command = "PATH=\"$PATH:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin\" mosh-server new -s -c 256 -l LANG=en_US.UTF-8"
        let name = host.tmuxSession.trimmed
        if !name.isEmpty {
            let q = SSHConnector.quote(name)
            let inner = "command -v tmux >/dev/null 2>&1 && exec tmux new-session -A -s \(q) || exec ${SHELL:-/bin/sh} -l"
            command += " -- sh -c \(SSHConnector.quote(inner))"
        }
        let result = try await SSHConnector.runCapturing(command, on: bootstrapClient)
        try? await bootstrapClient.close()

        guard let (port, key) = Self.parseMoshConnect(result.output) else {
            if result.output.contains("not found") || result.exitCode == 127 {
                throw MoshError.serverMissing
            }
            throw MoshError.bootstrapFailed(result.output.trimmed)
        }
        let ip = try await Self.resolve(host.hostname)

        let runner = MoshRunner(
            parameters: .init(ip: ip, port: port, key: key),
            cols: size.cols,
            rows: size.rows
        )
        runner.onOutput = { [weak self] bytes in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.display(bytes) } }
        }
        runner.onExit = { [weak self] code in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.mosh = nil
                    if self.state == .connected {
                        self.state = code == 0 ? .closed : .failed("Mosh wurde beendet (Code \(code)).")
                    }
                    self.runTask = nil
                }
            }
        }
        mosh = runner
        state = .connected
        runner.start()
    }

    static func parseMoshConnect(_ text: String) -> (String, String)? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ")
            if parts.count >= 4, parts[0] == "MOSH", parts[1] == "CONNECT" {
                return (String(parts[2]), String(parts[3]))
            }
        }
        return nil
    }

    /// Hostname → IP (Mosh braucht eine numerische Adresse).
    nonisolated static func resolve(_ hostname: String) async throws -> String {
        try await Task.detached {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_DGRAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(hostname, nil, &hints, &result) == 0, let first = result else {
                throw MoshError.resolveFailed(hostname)
            }
            defer { freeaddrinfo(result) }

            var candidates: [(Int32, String)] = []
            var ptr: UnsafeMutablePointer<addrinfo>? = first
            while let ai = ptr {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    candidates.append((ai.pointee.ai_family, String(cString: buffer)))
                }
                ptr = ai.pointee.ai_next
            }
            if let v4 = candidates.first(where: { $0.0 == AF_INET }) { return v4.1 }
            if let any = candidates.first { return any.1 }
            throw MoshError.resolveFailed(hostname)
        }.value
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? LocalizedError, let text = e.errorDescription { return text }
        if error is AuthenticationFailed || "\(error)".contains("allAuthenticationOptionsFailed") {
            return SSHConnectError.authenticationRejected.errorDescription ?? "\(error)"
        }
        return "\(error)"
    }
}

enum MoshError: LocalizedError {
    case serverMissing
    case bootstrapFailed(String)
    case resolveFailed(String)

    var errorDescription: String? {
        switch self {
        case .serverMissing: return "mosh-server ist auf dem Server nicht installiert"
        case .bootstrapFailed(let out): return "mosh-server lieferte keine Verbindungsdaten\(out.isEmpty ? "" : ": \(out.prefix(200))")"
        case .resolveFailed(let h): return "Adresse von \(h) nicht auflösbar"
        }
    }
}
