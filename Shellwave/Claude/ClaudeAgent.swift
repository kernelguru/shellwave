import Citadel
import Foundation
import LocalAuthentication
import NIOCore

/// Ein Eintrag im Claude-Chat.
struct ChatItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case user(String)
        case assistant(String)
        case tool(name: String, summary: String, output: String, done: Bool, failed: Bool)
        case notice(String)
        case error(String)
    }
    let id: String
    var kind: Kind
}

/// Eine Freigabe-Anfrage von Claude.
struct ApprovalRequest: Identifiable, Equatable {
    let id: String          // request_id (Claude Code) bzw. tool_use_id (API)
    let tool: String
    let summary: String
    let detail: String
    let rawInput: [String: AnyHashable]

    static func == (a: ApprovalRequest, b: ApprovalRequest) -> Bool { a.id == b.id }
}

/// Claude als Assistent einer Session: entweder Claude Code headless auf dem Server
/// (stream-json über einen SSH-Exec-Kanal) oder direkt die Claude-API mit einem
/// `run_command`-Werkzeug, das per SSH ausgeführt wird.
@MainActor
final class ClaudeAgent: ObservableObject {
    enum Status: Equatable {
        case idle, connecting, ready, working, failed(String)
    }

    @Published private(set) var items: [ChatItem] = []
    @Published private(set) var status: Status = .idle
    @Published private(set) var pending: ApprovalRequest?
    @Published private(set) var modeInUse: ClaudeMode = .claudeCode

    /// Freigabe-Status geändert (für die Live Activity).
    var onApprovalChange: ((ApprovalRequest?) -> Void)?

    private unowned let session: TerminalSession
    private var settings: ClaudeSettings { ClaudeSettings.shared }
    /// Originale Eingaben der offenen Freigaben (für die Antwort an Claude Code).
    private var permissionInputs: [String: [String: Any]] = [:]

    // Claude Code
    private var client: SSHClient?
    private var writer: TTYStdinWriter?
    /// Ausgehende JSON-Zeilen, in Reihenfolge geschrieben.
    private var outbox: AsyncStream<String>.Continuation?
    private var channelTask: Task<Void, Never>?
    private var lineBuffer = Data()
    private var pendingInputs: [String: [String: Any]] = [:]
    private var didSendContext = false
    private var requestCounter = 0

    // API
    private var apiMessages: [[String: Any]] = []
    /// Verlauf im Gemini-Format (getrennt, weil die Formate verschieden sind)
    private var geminiContents: [[String: Any]] = []
    private var apiTask: Task<Void, Never>?
    private var approvalContinuation: CheckedContinuation<Bool, Never>?

    init(session: TerminalSession) {
        self.session = session
    }

    // MARK: Öffentliche Steuerung

    func send(_ text: String) {
        let text = text.trimmed
        guard !text.isEmpty else { return }
        items.append(ChatItem(id: UUID().uuidString, kind: .user(text)))
        let prompt = didSendContext ? text : contextPrefix() + text
        didSendContext = true

        switch settings.mode {
        case .claudeCode:
            modeInUse = .claudeCode
            Task { await sendToClaudeCode(prompt) }
        case .api:
            modeInUse = .api
            apiMessages.append(["role": "user", "content": prompt])
            geminiContents.append(["role": "user", "parts": [["text": prompt]]])
            runAPILoop()
        }
    }

    func approve(_ allow: Bool) async {
        guard let request = pending else { return }
        if allow, settings.requireBiometrics, !ReadOnlyPolicy.isReadOnly(tool: request.tool, input: request.rawInput) {
            guard await Self.authenticate(reason: "Claude-Aktion freigeben: \(request.summary)") else { return }
        }
        pending = nil
        onApprovalChange?(nil)

        if let cont = approvalContinuation {
            approvalContinuation = nil
            cont.resume(returning: allow)
            return
        }
        await respondPermission(requestID: request.id, allow: allow)
    }

    func interrupt() {
        if modeInUse == .api {
            apiTask?.cancel()
            apiTask = nil
            approvalContinuation?.resume(returning: false)
            approvalContinuation = nil
            pending = nil
            status = .ready
            return
        }
        requestCounter += 1
        writeJSON(["type": "control_request", "request_id": "sw_int_\(requestCounter)", "request": ["subtype": "interrupt"]])
    }

    func reset() {
        stop()
        items = []
        apiMessages = []
        geminiContents = []
        didSendContext = false
        ClaudeSessionIDs.set(nil, for: session.host.id)
    }

    func stop() {
        channelTask?.cancel()
        channelTask = nil
        apiTask?.cancel()
        apiTask = nil
        writer = nil
        outbox?.finish()
        outbox = nil
        let c = client
        client = nil
        Task { try? await c?.close() }
        if pending != nil { pending = nil; onApprovalChange?(nil) }
        status = .idle
    }

    // MARK: Kontext

    private func contextPrefix() -> String {
        let host = session.host
        let screen = session.screenText(lines: 30)
        var s = "[Kontext von Shellwave: Host \(host.displayName) (\(host.address)), angemeldet als \(host.username).]\n"
        if !screen.isEmpty {
            s += "[Letzte Terminal-Ausgabe:]\n```\n\(screen)\n```\n"
        }
        return s + "\n"
    }

    // MARK: Claude Code (stream-json)

    private func sendToClaudeCode(_ prompt: String) async {
        if writer == nil {
            await connectClaudeCode()
        }
        guard writer != nil else { return }
        status = .working
        writeJSON([
            "type": "user",
            "session_id": "",
            "message": ["role": "user", "content": prompt],
            "parent_tool_use_id": NSNull(),
        ])
    }

    private func connectClaudeCode(resumeAllowed: Bool = true) async {
        status = .connecting
        do {
            let client = try await SSHConnector.connect(to: session.host, certificates: session.certificates, hosts: session.hosts)
            self.client = client

            let hostID = session.host.id
            var sessionArg: String
            if resumeAllowed, let existing = ClaudeSessionIDs.get(hostID) {
                sessionArg = "--resume=\(existing)"
            } else {
                let fresh = UUID().uuidString.lowercased()
                ClaudeSessionIDs.set(fresh, for: hostID)
                sessionArg = "--session-id \(fresh)"
            }

            var env = ""
            if settings.passKeyToServer, !settings.apiKey.isEmpty {
                env = "ANTHROPIC_API_KEY=\(SSHConnector.quote(settings.apiKey)) "
            }
            let command = """
            export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:$PATH"; cd ~; \
            command -v claude >/dev/null 2>&1 || { echo '{"type":"shellwave_error","message":"Claude Code ist auf diesem Server nicht installiert."}'; exit 127; }; \
            \(env)exec claude -p --input-format stream-json --output-format stream-json --verbose \
            --permission-prompt-tool stdio --permission-mode default \(sessionArg)
            """

            let ready = AsyncStream<TTYStdinWriter>.makeStream()
            channelTask = Task { [weak self] in
                do {
                    try await client.withExec(command) { inbound, outbound in
                        ready.continuation.yield(outbound)
                        ready.continuation.finish()
                        for try await event in inbound {
                            switch event {
                            case .stdout(let buffer):
                                self?.consume(Data(buffer.readableBytesView))
                            case .stderr(let buffer):
                                self?.consumeStderr(String(buffer: buffer))
                            }
                        }
                    }
                } catch {
                    self?.channelEnded(error: error)
                    return
                }
                self?.channelEnded(error: nil)
            }

            var iterator = ready.stream.makeAsyncIterator()
            guard let w = await iterator.next() else { throw ClaudeError.channelFailed }
            writer = w
            let (lines, continuation) = AsyncStream<String>.makeStream()
            outbox = continuation
            Task {
                for await line in lines {
                    try? await w.write(ByteBuffer(string: line))
                }
            }
            status = .ready
            requestCounter += 1
            writeJSON(["type": "control_request", "request_id": "sw_init_\(requestCounter)", "request": ["subtype": "initialize", "hooks": NSNull()]])
        } catch {
            status = .failed(TerminalSession.describe(error))
            items.append(ChatItem(id: UUID().uuidString, kind: .error(TerminalSession.describe(error))))
        }
    }

    private func channelEnded(error: Error?) {
        writer = nil
        outbox?.finish()
        outbox = nil
        channelTask = nil
        if case .failed = status { return }
        if let error {
            status = .failed(TerminalSession.describe(error))
        } else if status == .working || status == .connecting {
            status = .failed("Claude Code wurde beendet.")
        } else {
            status = .idle
        }
    }

    private func consumeStderr(_ text: String) {
        let t = text.trimmed
        guard !t.isEmpty else { return }
        if t.contains("No conversation found") {
            // Alte Session gibt es nicht mehr: neu starten
            ClaudeSessionIDs.set(nil, for: session.host.id)
            items.append(ChatItem(id: UUID().uuidString, kind: .notice("Vorherige Unterhaltung nicht gefunden – neue Session gestartet.")))
            return
        }
        items.append(ChatItem(id: UUID().uuidString, kind: .error(String(t.prefix(500)))))
    }

    private func consume(_ data: Data) {
        lineBuffer.append(data)
        while let nl = lineBuffer.firstIndex(of: 0x0A) {
            let line = lineBuffer[lineBuffer.startIndex..<nl]
            lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(obj)
        }
    }

    private func handle(_ msg: [String: Any]) {
        switch msg["type"] as? String {
        case "system":
            if (msg["subtype"] as? String) == "init" {
                if let model = msg["model"] as? String {
                    items.append(ChatItem(id: UUID().uuidString, kind: .notice("Claude Code bereit (\(model))")))
                }
            }

        case "assistant":
            guard let message = msg["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String, !text.trimmed.isEmpty {
                        appendAssistant(text, id: (message["id"] as? String) ?? UUID().uuidString)
                    }
                case "tool_use":
                    let id = block["id"] as? String ?? UUID().uuidString
                    let name = block["name"] as? String ?? "Tool"
                    let input = block["input"] as? [String: Any] ?? [:]
                    pendingInputs[id] = input
                    items.append(ChatItem(id: id, kind: .tool(name: name, summary: Self.summarize(tool: name, input: input), output: "", done: false, failed: false)))
                default:
                    break
                }
            }

        case "user":
            guard let message = msg["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
            for block in content where (block["type"] as? String) == "tool_result" {
                guard let id = block["tool_use_id"] as? String else { continue }
                let failed = (block["is_error"] as? Bool) ?? false
                finishTool(id: id, output: Self.text(of: block["content"]), failed: failed)
            }

        case "result":
            status = .ready
            if (msg["is_error"] as? Bool) == true {
                let text = (msg["result"] as? String) ?? (msg["subtype"] as? String) ?? "Fehler"
                items.append(ChatItem(id: UUID().uuidString, kind: .error(text)))
            }

        case "control_request":
            guard let requestID = msg["request_id"] as? String,
                  let request = msg["request"] as? [String: Any] else { return }
            if (request["subtype"] as? String) == "can_use_tool" {
                let tool = request["tool_name"] as? String ?? "Tool"
                let input = request["input"] as? [String: Any] ?? [:]
                handlePermission(requestID: requestID, tool: tool, input: input)
            } else {
                writeJSON(["type": "control_response", "response": ["subtype": "error", "request_id": requestID, "error": "Nicht unterstützt"]])
            }

        case "shellwave_error":
            let text = msg["message"] as? String ?? "Fehler"
            status = .failed(text)
            items.append(ChatItem(id: UUID().uuidString, kind: .error(text + " Installiere es über „Server einrichten“ oder nutze in den Einstellungen die Claude-API.")))

        default:
            break
        }
    }

    private func handlePermission(requestID: String, tool: String, input: [String: Any]) {
        let hashable = Self.hashable(input)
        permissionInputs[requestID] = input
        if settings.autoApproveReadOnly, ReadOnlyPolicy.isReadOnly(tool: tool, input: input) {
            Task { await respondPermission(requestID: requestID, allow: true) }
            return
        }
        let request = ApprovalRequest(
            id: requestID,
            tool: tool,
            summary: Self.summarize(tool: tool, input: input),
            detail: Self.detail(tool: tool, input: input),
            rawInput: hashable
        )
        pending = request
        onApprovalChange?(request)
    }

    private func respondPermission(requestID: String, allow: Bool) async {
        let input = permissionInputs.removeValue(forKey: requestID) ?? [:]
        let response: [String: Any] = allow
            ? ["behavior": "allow", "updatedInput": input]
            : ["behavior": "deny", "message": "Vom Benutzer in Shellwave abgelehnt."]
        writeJSON([
            "type": "control_response",
            "response": ["subtype": "success", "request_id": requestID, "response": response],
        ])
    }

    private func writeJSON(_ obj: [String: Any]) {
        guard let outbox,
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let line = String(data: data, encoding: .utf8) else { return }
        outbox.yield(line + "\n")
    }

    private func appendAssistant(_ text: String, id: String) {
        if let last = items.last, last.id == id, case .assistant(let previous) = last.kind {
            items[items.count - 1].kind = .assistant(previous + "\n\n" + text)
        } else {
            items.append(ChatItem(id: id, kind: .assistant(text)))
        }
    }

    private func finishTool(id: String, output: String, failed: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }),
              case .tool(let name, let summary, _, _, _) = items[i].kind else { return }
        items[i].kind = .tool(name: name, summary: summary, output: String(output.prefix(4000)), done: true, failed: failed)
    }

    // MARK: Claude-API (Fallback ohne Claude Code auf dem Server)

    private func runAPILoop() {
        guard apiTask == nil else { return }
        let provider = settings.apiProvider
        apiTask = Task { [weak self] in
            switch provider {
            case .anthropic: await self?.apiLoop()
            case .google: await self?.geminiLoop()
            }
            self?.apiTask = nil
        }
    }

    private func apiLoop() async {
        guard !settings.apiKey.isEmpty else {
            items.append(ChatItem(id: UUID().uuidString, kind: .error("Kein Claude-API-Schlüssel gesetzt (Einstellungen → Assistent).")))
            return
        }
        status = .working
        do {
            if client == nil {
                client = try await SSHConnector.connect(to: session.host, certificates: session.certificates, hosts: session.hosts)
            }
            for _ in 0..<25 {
                try Task.checkCancellation()
                let response = try await callAPI()
                guard let content = response["content"] as? [[String: Any]] else { break }
                apiMessages.append(["role": "assistant", "content": content])

                var toolResults: [[String: Any]] = []
                for block in content {
                    switch block["type"] as? String {
                    case "text":
                        if let text = block["text"] as? String, !text.trimmed.isEmpty {
                            items.append(ChatItem(id: UUID().uuidString, kind: .assistant(text)))
                        }
                    case "tool_use":
                        let id = block["id"] as? String ?? UUID().uuidString
                        let input = block["input"] as? [String: Any] ?? [:]
                        let command = input["command"] as? String ?? ""
                        items.append(ChatItem(id: id, kind: .tool(name: "run_command", summary: command, output: "", done: false, failed: false)))

                        let result = try await executeTool(id: id, command: command, input: input)
                        if let result {
                            toolResults.append([
                                "type": "tool_result", "tool_use_id": id,
                                "content": "exit code \(result.exitCode)\n\(String(result.output.suffix(12000)))",
                            ])
                        } else {
                            toolResults.append(["type": "tool_result", "tool_use_id": id, "content": "Der Benutzer hat diesen Befehl abgelehnt.", "is_error": true])
                        }
                    default:
                        break
                    }
                }

                if toolResults.isEmpty || (response["stop_reason"] as? String) != "tool_use" { break }
                apiMessages.append(["role": "user", "content": toolResults])
            }
            status = .ready
        } catch is CancellationError {
            status = .ready
        } catch {
            status = .failed(TerminalSession.describe(error))
            items.append(ChatItem(id: UUID().uuidString, kind: .error(TerminalSession.describe(error))))
        }
    }

    /// Freigabe prüfen und Befehl per SSH ausführen. `nil` = vom Benutzer abgelehnt.
    private func executeTool(id: String, command: String, input: [String: Any]) async throws -> (output: String, exitCode: Int)? {
        var allowed = settings.autoApproveReadOnly && ReadOnlyPolicy.isReadOnly(command: command)
        if !allowed {
            let request = ApprovalRequest(id: id, tool: "run_command", summary: command, detail: command, rawInput: Self.hashable(input))
            allowed = await waitForApproval(request)
        }
        guard allowed, let client else {
            finishTool(id: id, output: "Abgelehnt", failed: true)
            return nil
        }
        let result = try await SSHConnector.runCapturing(command, on: client)
        let output = ANSIStripper.strip(result.output)
        finishTool(id: id, output: output, failed: result.exitCode != 0)
        return (output, result.exitCode)
    }

    private var systemPrompt: String {
        """
        Du bist ein Linux-Administrationsassistent in der iOS-App Shellwave und arbeitest auf dem Server \
        \(session.host.displayName) (\(session.host.address)). Befehle führst du mit dem Werkzeug run_command aus; \
        jeder schreibende Befehl muss vom Benutzer freigegeben werden. Prüfe erst den Zustand, dann ändere. \
        Antworte knapp auf Deutsch.
        """
    }

    // MARK: Google Gemini (optional)

    private func geminiLoop() async {
        guard !settings.geminiKey.isEmpty else {
            items.append(ChatItem(id: UUID().uuidString, kind: .error("Kein Gemini-API-Schlüssel gesetzt (Einstellungen → Assistent).")))
            return
        }
        status = .working
        do {
            if client == nil {
                client = try await SSHConnector.connect(to: session.host, certificates: session.certificates, hosts: session.hosts)
            }
            for _ in 0..<25 {
                try Task.checkCancellation()
                let response = try await callGeminiWithRetry()
                guard let candidates = response["candidates"] as? [[String: Any]],
                      let content = candidates.first?["content"] as? [String: Any],
                      let parts = content["parts"] as? [[String: Any]] else {
                    if let feedback = response["promptFeedback"] as? [String: Any], let reason = feedback["blockReason"] as? String {
                        throw ClaudeError.api("Gemini hat die Anfrage blockiert (\(reason)).")
                    }
                    break
                }
                // Antwort unverändert in den Verlauf (enthält ggf. Thought Signatures, die Gemini zurück braucht)
                geminiContents.append(["role": "model", "parts": parts])

                var responses: [[String: Any]] = []
                for part in parts {
                    if let text = part["text"] as? String, (part["thought"] as? Bool) != true, !text.trimmed.isEmpty {
                        items.append(ChatItem(id: UUID().uuidString, kind: .assistant(text)))
                    }
                    if let call = part["functionCall"] as? [String: Any] {
                        let name = call["name"] as? String ?? "run_command"
                        let args = call["args"] as? [String: Any] ?? [:]
                        let callID = call["id"] as? String
                        let id = callID ?? UUID().uuidString
                        let command = args["command"] as? String ?? ""
                        items.append(ChatItem(id: id, kind: .tool(name: name, summary: command, output: "", done: false, failed: false)))

                        var payload: [String: Any] = ["name": name]
                        if let callID { payload["id"] = callID }
                        if let result = try await executeTool(id: id, command: command, input: args) {
                            payload["response"] = ["exit_code": result.exitCode, "output": String(result.output.suffix(12000))]
                        } else {
                            payload["response"] = ["error": "Der Benutzer hat diesen Befehl abgelehnt."]
                        }
                        responses.append(["functionResponse": payload])
                    }
                }

                if responses.isEmpty { break }
                geminiContents.append(["role": "user", "parts": responses])
            }
            status = .ready
        } catch is CancellationError {
            status = .ready
        } catch {
            status = .failed(TerminalSession.describe(error))
            items.append(ChatItem(id: UUID().uuidString, kind: .error(TerminalSession.describe(error))))
        }
    }

    /// Gemini ist in der Gratis-Stufe oft überlastet (503/429). Dann mit Pause erneut versuchen
    /// und notfalls auf ältere Flash-Modelle ausweichen, die weniger gefragt sind.
    private func callGeminiWithRetry() async throws -> [String: Any] {
        let primary = settings.geminiModel.trimmed.isEmpty ? "gemini-3.8-flash" : settings.geminiModel.trimmed
        var models = [primary]
        for fallback in ["gemini-3.7-flash", "gemini-3.5-flash", "gemini-3.5-flash-lite"] where !models.contains(fallback) {
            models.append(fallback)
        }

        var lastError: Error = ClaudeError.gemini("Keine Antwort")
        for (index, model) in models.enumerated() {
            for (attempt, delay) in [0, 3, 8].enumerated() {
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                do {
                    let result = try await callGemini(model: model)
                    if index > 0 {
                        items.append(ChatItem(id: UUID().uuidString, kind: .notice("\(primary) ist überlastet – Antwort kam von \(model).")))
                    }
                    return result
                } catch GeminiFailure.overloaded(let message) {
                    lastError = ClaudeError.gemini(message)
                    if attempt == 0 && index == 0 {
                        items.append(ChatItem(id: UUID().uuidString, kind: .notice("Gemini ist gerade überlastet, versuche es erneut …")))
                    }
                    continue
                } catch GeminiFailure.unknownModel {
                    break   // Modell gibt es (für diesen Schlüssel) nicht: nächstes versuchen
                } catch let error as URLError where error.code == .timedOut {
                    lastError = ClaudeError.gemini("Zeitüberschreitung")
                    continue
                }
            }
        }
        throw lastError
    }

    private enum GeminiFailure: Error {
        case overloaded(String)
        case unknownModel
    }

    private func callGemini(model: String) async throws -> [String: Any] {
        let encoded = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        var req = URLRequest(
            url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encoded):generateContent")!,
            timeoutInterval: 90
        )
        req.httpMethod = "POST"
        req.setValue(settings.geminiKey, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "contents": geminiContents,
            "tools": [[
                "functionDeclarations": [[
                    "name": "run_command",
                    "description": "Führt einen Shell-Befehl auf dem Server aus (nicht interaktiv) und liefert Exit-Code und Ausgabe.",
                    "parameters": [
                        "type": "object",
                        "properties": ["command": ["type": "string", "description": "Der auszuführende Befehl"]],
                        "required": ["command"],
                    ],
                ]],
            ]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(http.statusCode)"
            switch http.statusCode {
            case 429, 500, 503, 504: throw GeminiFailure.overloaded(message)
            case 404: throw GeminiFailure.unknownModel
            default: throw ClaudeError.gemini(message)
            }
        }
        return json
    }

    private func waitForApproval(_ request: ApprovalRequest) async -> Bool {
        pending = request
        onApprovalChange?(request)
        return await withCheckedContinuation { cont in
            approvalContinuation = cont
        }
    }

    private func callAPI() async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": settings.model,
            "max_tokens": 4096,
            "system": systemPrompt,
            "tools": [[
                "name": "run_command",
                "description": "Führt einen Shell-Befehl auf dem Server aus (nicht interaktiv) und liefert Exit-Code und Ausgabe.",
                "input_schema": [
                    "type": "object",
                    "properties": ["command": ["type": "string", "description": "Der auszuführende Befehl"]],
                    "required": ["command"],
                ],
            ]],
            "messages": apiMessages,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(http.statusCode)"
            throw ClaudeError.api(message)
        }
        return json
    }

    // MARK: Hilfen

    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    static func summarize(tool: String, input: [String: Any]) -> String {
        if let command = input["command"] as? String { return command }
        if let path = input["file_path"] as? String { return "\(tool) \(path)" }
        if let pattern = input["pattern"] as? String { return "\(tool) \(pattern)" }
        if let url = input["url"] as? String { return "\(tool) \(url)" }
        return tool
    }

    static func detail(tool: String, input: [String: Any]) -> String {
        if let command = input["command"] as? String { return command }
        if let path = input["file_path"] as? String {
            var s = path
            if let old = input["old_string"] as? String, let new = input["new_string"] as? String {
                s += "\n\n− " + String(old.prefix(600)) + "\n+ " + String(new.prefix(600))
            } else if let content = input["content"] as? String {
                s += "\n\n" + String(content.prefix(1200))
            }
            return s
        }
        if let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted]),
           let text = String(data: data, encoding: .utf8) { return text }
        return tool
    }

    static func text(of content: Any?) -> String {
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    /// JSON-Werte in eine Equatable-taugliche Form bringen (für die Freigabe-Karte).
    static func hashable(_ dict: [String: Any]) -> [String: AnyHashable] {
        var out: [String: AnyHashable] = [:]
        for (k, v) in dict { out[k] = toHashable(v) }
        return out
    }

    private static func toHashable(_ value: Any) -> AnyHashable {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n
        case let d as [String: Any]: return hashable(d)
        case let a as [Any]: return a.map { toHashable($0) }
        default: return String(describing: value)
        }
    }
}

enum ClaudeError: LocalizedError {
    case channelFailed
    case api(String)
    case gemini(String)

    var errorDescription: String? {
        switch self {
        case .channelFailed: return "Kanal zu Claude Code konnte nicht geöffnet werden."
        case .api(let m): return "Claude-API: \(m)"
        case .gemini(let m): return "Gemini-API: \(m)"
        }
    }
}
