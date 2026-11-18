import SwiftUI
import UIKit

/// Editor für Konfigurationsdateien im SFTP-Browser: Highlighting, Prüfung beim Tippen,
/// optionale Prüfung auf dem Server und Speichern mit Sicherungskopie.
struct ConfigEditorView: View {
    @ObservedObject var model: SFTPModel
    let file: RemoteFile

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var original = ""
    @State private var language: ConfigLanguage = .plain
    @State private var diagnostics: [Diagnostic] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var saving = false
    @State private var checking = false
    @State private var serverResult: ServerCheck?
    @State private var showDiagnostics = true
    @State private var confirmSaveWithErrors = false
    @State private var confirmDiscard = false
    @State private var jumpTo: Int?
    @State private var savedMessage: String?
    @AppStorage("editor.backup") private var backup = true

    struct ServerCheck: Equatable {
        let ok: Bool
        let output: String
        let command: String
    }

    private var errors: [Diagnostic] { diagnostics.filter { $0.severity == .error } }
    private var warnings: [Diagnostic] { diagnostics.filter { $0.severity == .warning } }
    private var dirty: Bool { text != original }

    var body: some View {
        ZStack {
            Color(red: 0.02, green: 0.06, blue: 0.07).ignoresSafeArea()
            if loading {
                ProgressView()
            } else if let loadError {
                ContentUnavailableView("Datei lässt sich nicht öffnen", systemImage: "doc.questionmark", description: Text(loadError))
            } else {
                CodeTextView(text: $text, language: language, diagnostics: $diagnostics, jumpTo: $jumpTo)
                    .ignoresSafeArea(.container, edges: .bottom)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !loading, loadError == nil { statusPanel }
        }
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Schließen", systemImage: "xmark") {
                    if dirty { confirmDiscard = true } else { dismiss() }
                }
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(file.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(language.label + (dirty ? " · geändert" : "")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    if serverCheckCommand != nil {
                        Button("Auf dem Server prüfen", systemImage: "checkmark.shield") { Task { await checkOnServer() } }
                    }
                    Toggle("Sicherungskopie (.bak)", isOn: $backup)
                    Menu("Dateityp") {
                        ForEach([ConfigLanguage.compose, .yaml, .conf, .nginx, .sshd, .json, .env, .shell, .plain], id: \.self) { lang in
                            Button(lang.label) {
                                language = lang
                                diagnostics = ConfigValidator.validate(text, language: lang)
                            }
                        }
                    }
                    if dirty {
                        Button("Änderungen verwerfen", systemImage: "arrow.uturn.backward", role: .destructive) { text = original }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                Button {
                    if errors.isEmpty { Task { await save() } } else { confirmSaveWithErrors = true }
                } label: {
                    if saving { ProgressView() } else { Text("Sichern").fontWeight(.semibold) }
                }
                .disabled(!dirty || saving)
            }
        }
        .confirmationDialog("Die Datei enthält \(errors.count) Fehler. Trotzdem speichern?", isPresented: $confirmSaveWithErrors, titleVisibility: .visible) {
            Button("Trotzdem speichern", role: .destructive) { Task { await save() } }
            Button("Abbrechen", role: .cancel) {}
        }
        .confirmationDialog("Ungespeicherte Änderungen verwerfen?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Verwerfen", role: .destructive) { dismiss() }
            Button("Weiter bearbeiten", role: .cancel) {}
        }
        .task { await load() }
        .onChange(of: text) { serverResult = nil; savedMessage = nil }
    }

    // MARK: Statusleiste mit Fehlerliste

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.smooth) { showDiagnostics.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        if errors.isEmpty && warnings.isEmpty {
                            Label("Keine Fehler", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            if !errors.isEmpty {
                                Label("\(errors.count)", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                            }
                            if !warnings.isEmpty {
                                Label("\(warnings.count)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            }
                        }
                        if !diagnostics.isEmpty {
                            Image(systemName: showDiagnostics ? "chevron.down" : "chevron.up").font(.caption2)
                        }
                    }
                    .font(.footnote.weight(.semibold))
                }
                .tint(.primary)

                Spacer()

                if checking {
                    ProgressView().controlSize(.small)
                } else if let serverResult {
                    Label(serverResult.ok ? "Server: OK" : "Server: Fehler", systemImage: serverResult.ok ? "checkmark.shield.fill" : "xmark.shield.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(serverResult.ok ? .green : .red)
                } else if serverCheckCommand != nil {
                    Button("Auf Server prüfen", systemImage: "checkmark.shield") { Task { await checkOnServer() } }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.glass)
                }
            }

            if let savedMessage {
                Text(savedMessage).font(.caption).foregroundStyle(.secondary)
            }

            if showDiagnostics && (!diagnostics.isEmpty || (serverResult.map { !$0.ok } ?? false)) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(diagnostics) { d in
                            Button {
                                jumpTo = d.line
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: d.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(d.severity == .error ? .red : .orange)
                                    Text("Z. \(d.line)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                    Text(d.message).font(.caption).multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }
                            }
                            .tint(.primary)
                        }
                        if let serverResult, !serverResult.ok {
                            Text(serverResult.command).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            Text(serverResult.output)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    // MARK: Laden, Prüfen, Speichern

    private func load() async {
        do {
            let content = try await model.readText(at: file.path)
            text = content
            original = content
            language = ConfigLanguage.detect(filename: file.name, content: content)
            diagnostics = ConfigValidator.validate(content, language: language)
        } catch {
            loadError = TerminalSession.describe(error)
        }
        loading = false
    }

    private var directory: String { (file.path as NSString).deletingLastPathComponent }
    private var tempPath: String { SFTPModel.join(directory, ".shellwave-check-\(file.name)") }

    /// Befehl, mit dem der Server selbst die Datei prüft (nil = keine Server-Prüfung möglich).
    private var serverCheckCommand: String? {
        let q = SSHConnector.quote(tempPath)
        switch language {
        case .compose:
            return "cd \(SSHConnector.quote(directory)) && if docker compose version >/dev/null 2>&1; then docker compose -f \(q) config -q; else docker-compose -f \(q) config -q; fi"
        case .sshd:
            return "SSHD=$(command -v sshd || echo /usr/sbin/sshd); $SSHD -t -f \(q) || sudo -n $SSHD -t -f \(q)"
        case .nginx where file.name == "nginx.conf":
            return "nginx -t -c \(q) || sudo -n nginx -t -c \(q)"
        default:
            return nil
        }
    }

    private func checkOnServer() async {
        guard let command = serverCheckCommand else { return }
        checking = true
        defer { checking = false }
        do {
            try await model.writeText(text, to: tempPath)
            let result = try await model.run(command)
            await model.removeFile(at: tempPath)
            let output = result.output
                .replacingOccurrences(of: tempPath, with: file.name)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            serverResult = ServerCheck(ok: result.exitCode == 0, output: output.isEmpty ? "Exit-Code \(result.exitCode)" : output, command: command)
            if result.exitCode != 0 { showDiagnostics = true }
        } catch {
            await model.removeFile(at: tempPath)
            serverResult = ServerCheck(ok: false, output: TerminalSession.describe(error), command: command)
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            if backup, original != text {
                try await model.writeText(original, to: file.path + ".bak")
            }
            try await model.writeText(text, to: file.path)
            original = text
            savedMessage = "Gespeichert\(backup ? ", Sicherung: \(file.name).bak" : "")."
            await model.list(model.path)
        } catch {
            savedMessage = "Speichern fehlgeschlagen: \(TerminalSession.describe(error))"
        }
    }
}

// MARK: - Textansicht mit Highlighting

struct CodeTextView: UIViewRepresentable {
    @Binding var text: String
    let language: ConfigLanguage
    @Binding var diagnostics: [Diagnostic]
    @Binding var jumpTo: Int?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = SyntaxHighlighter.font
        view.textColor = SyntaxHighlighter.Palette.text
        view.tintColor = UIColor(hex: "73F2CC")
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.keyboardType = .asciiCapable
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 220, right: 8)
        view.inputAccessoryView = context.coordinator.makeAccessory()
        view.text = text
        context.coordinator.textView = view
        context.coordinator.highlight(view)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text {
            let selected = view.selectedRange
            view.text = text
            view.selectedRange = NSRange(location: min(selected.location, (text as NSString).length), length: 0)
            context.coordinator.highlight(view)
        } else if context.coordinator.lastLanguage != language || context.coordinator.lastDiagnostics != diagnostics {
            context.coordinator.highlight(view)
        }
        if let line = jumpTo {
            DispatchQueue.main.async {
                context.coordinator.jump(to: line)
                jumpTo = nil
            }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeTextView
        weak var textView: UITextView?
        var lastLanguage: ConfigLanguage?
        var lastDiagnostics: [Diagnostic] = []
        private var pending: DispatchWorkItem?

        init(parent: CodeTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            pending?.cancel()
            let work = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                let diags = ConfigValidator.validate(textView.text, language: self.parent.language)
                self.parent.diagnostics = diags
                self.highlight(textView, diagnostics: diags)
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }

        func highlight(_ view: UITextView, diagnostics: [Diagnostic]? = nil) {
            let diags = diagnostics ?? parent.diagnostics
            lastLanguage = parent.language
            lastDiagnostics = diags
            SyntaxHighlighter.apply(to: view.textStorage, language: parent.language, diagnostics: diags)
            view.typingAttributes = [.font: SyntaxHighlighter.font, .foregroundColor: SyntaxHighlighter.Palette.text]
        }

        func jump(to line: Int) {
            guard let view = textView else { return }
            let ranges = SyntaxHighlighter.lineRanges(in: view.text as NSString)
            guard line >= 1, line <= ranges.count else { return }
            let range = ranges[line - 1]
            view.becomeFirstResponder()
            view.selectedRange = NSRange(location: range.location, length: 0)
            view.scrollRangeToVisible(range)
        }

        // MARK: Zusatzleiste über der Tastatur

        func makeAccessory() -> UIView {
            let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
            bar.sizeToFit()
            let items: [(String, String)] = [("⇥", "  "), ("-", "- "), (":", ": "), ("#", "# "), ("\"", "\""), ("'", "'"), ("{", "{"), ("}", "}"), ("$", "${")]
            var buttons: [UIBarButtonItem] = items.map { title, insert in
                UIBarButtonItem(title: title, primaryAction: UIAction { [weak self] _ in self?.insert(insert) })
            }
            buttons.append(UIBarButtonItem(systemItem: .flexibleSpace))
            buttons.append(UIBarButtonItem(image: UIImage(systemName: "arrow.uturn.backward"), primaryAction: UIAction { [weak self] _ in
                self?.textView?.undoManager?.undo()
            }))
            buttons.append(UIBarButtonItem(image: UIImage(systemName: "keyboard.chevron.compact.down"), primaryAction: UIAction { [weak self] _ in
                self?.textView?.resignFirstResponder()
            }))
            bar.items = buttons
            return bar
        }

        private func insert(_ string: String) {
            guard let view = textView else { return }
            view.insertText(string)
        }

        /// Neue Zeile übernimmt die Einrückung der vorherigen (und rückt nach „:“ in YAML ein).
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n" else { return true }
            let ns = textView.text as NSString
            let lineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
            let line = ns.substring(with: NSRange(location: lineRange.location, length: range.location - lineRange.location))
            var indent = String(line.prefix { $0 == " " || $0 == "\t" })
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if [.yaml, .compose].contains(parent.language), trimmed.hasSuffix(":") {
                indent += "  "
            } else if parent.language == .nginx, trimmed.hasSuffix("{") {
                indent += "    "
            }
            textView.insertText("\n" + indent)
            return false
        }
    }
}
