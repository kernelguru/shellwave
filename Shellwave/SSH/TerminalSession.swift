import Citadel
import Foundation
import NIOCore
import NIOSSH
import SwiftTerm
import UIKit

/// Eine interaktive SSH-Session: Verbindung, PTY und der Datenfluss zwischen Server und Terminal.
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
    }

    let id = UUID()
    let host: Host
    @Published private(set) var state: State = .idle
    @Published private(set) var title: String = ""
    let startedAt = Date.now

    /// Die Terminal-View gehört zur Session, damit Bildschirm und Scrollback erhalten bleiben,
    /// wenn man die Session zuklappt und später wieder öffnet.
    lazy var terminalView: TerminalView = {
        let view = TerminalView(frame: .zero, font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        let background = UIColor(red: 0.02, green: 0.06, blue: 0.07, alpha: 1)
        view.backgroundColor = background
        view.nativeBackgroundColor = background
        view.nativeForegroundColor = UIColor(white: 0.92, alpha: 1)
        view.caretColor = UIColor(Theme.mint)
        view.optionAsMetaKey = true
        return view
    }()

    private let certificates: CertificateManager
    private let hosts: HostStore
    private var client: SSHClient?
    private var runTask: Task<Void, Never>?
    private var inputContinuation: AsyncStream<[UInt8]>.Continuation?
    private var size = (cols: 80, rows: 24)
    private var resizeHandler: ((Int, Int) async -> Void)?

    init(host: Host, certificates: CertificateManager, hosts: HostStore) {
        self.host = host
        self.certificates = certificates
        self.hosts = hosts
        self.title = host.displayName
    }

    // MARK: Steuerung

    func start() {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in
            await self?.run()
        }
    }

    func reconnect() {
        disconnect()
        state = .idle
        start()
    }

    func disconnect() {
        inputContinuation?.finish()
        inputContinuation = nil
        runTask?.cancel()
        runTask = nil
        let client = self.client
        self.client = nil
        Task { try? await client?.close() }
        if state == .connected || state == .connecting { state = .closed }
    }

    /// Tastatureingaben vom Terminal.
    func send(_ bytes: [UInt8]) {
        inputContinuation?.yield(bytes)
    }

    func send(text: String) {
        send(Array(text.utf8))
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        size = (cols, rows)
        if let handler = resizeHandler {
            Task { await handler(cols, rows) }
        }
    }

    func setTitle(_ t: String) {
        title = t.isEmpty ? host.displayName : t
    }

    // MARK: Ablauf

    private func run() async {
        do {
            let auth = try await makeAuthentication()
            state = .connecting

            let hostID = host.id
            let hostStore = hosts
            let validator = TOFUHostKeyValidator(known: host.knownHostKey) { key in
                Task { @MainActor in hostStore.learnHostKey(key, for: hostID) }
            }
            let settings = SSHClientSettings(
                host: host.hostname,
                port: host.port,
                authenticationMethod: { auth() },
                hostKeyValidator: .custom(validator)
            )
            let client = try await SSHClient.connect(to: settings)
            self.client = client

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
                // Größe nachziehen, falls sich das Terminal seit dem Request geändert hat.
                try? await outbound.changeSize(cols: self.size.cols, rows: self.size.rows, pixelWidth: 0, pixelHeight: 0)

                // Eingabe in genau einer Reihenfolge an den Server schreiben.
                let writer = Task {
                    for await chunk in stream {
                        try? await outbound.write(ByteBuffer(bytes: chunk))
                    }
                }
                defer { writer.cancel() }

                for try await event in inbound {
                    switch event {
                    case .stdout(let buffer), .stderr(let buffer):
                        let bytes = Array(buffer.readableBytesView)
                        self.terminalView.feed(byteArray: bytes[...])
                    }
                }
            }
            resizeHandler = nil
            if state == .connected { state = .closed }
        } catch is CancellationError {
            state = .closed
        } catch {
            resizeHandler = nil
            state = .failed(Self.describe(error))
        }
        try? await client?.close()
        client = nil
        runTask = nil
    }

    /// Baut die Anmeldemethode je nach Host-Einstellung.
    private func makeAuthentication() async throws -> @Sendable () -> SSHAuthenticationMethod {
        let username = host.username
        switch host.auth {
        case .password:
            let password = host.password
            guard !password.isEmpty else { throw SSHConnectError.missingPassword }
            return { .passwordBased(username: username, password: password) }

        case .key:
            let key = DeviceKey.shared.privateKey
            return { .ed25519(username: username, privateKey: key) }

        case .certificate:
            state = .renewingCertificate
            let cert = try await certificates.certificate(for: host.effectivePrincipals)
            guard let certified = cert.parsed else { throw CertificateError.invalidCertificate }
            let key = DeviceKey.shared.privateKey
            return {
                .custom(CertificateAuthDelegate(username: username, privateKey: key, certifiedKey: certified))
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? LocalizedError, let text = e.errorDescription { return text }
        if error is AuthenticationFailed || "\(error)".contains("allAuthenticationOptionsFailed") {
            return SSHConnectError.authenticationRejected.errorDescription ?? "\(error)"
        }
        return "\(error)"
    }
}
