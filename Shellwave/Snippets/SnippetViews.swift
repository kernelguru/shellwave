import SwiftUI

/// Tab mit allen Snippets: anlegen, bearbeiten, auf mehreren Hosts ausführen.
struct SnippetListView: View {
    @EnvironmentObject private var snippets: SnippetStore
    @State private var editing: Snippet?
    @State private var running: Snippet?
    @State private var search = ""

    private var filtered: [Snippet] {
        let q = search.trimmed.lowercased()
        guard !q.isEmpty else { return snippets.snippets }
        return snippets.snippets.filter {
            $0.title.lowercased().contains(q) || $0.command.lowercased().contains(q) || $0.tags.contains { $0.lowercased().contains(q) }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(filtered) { snippet in
                    SnippetCard(snippet: snippet)
                        .onTapGesture { running = snippet }
                        .contextMenu {
                            Button("Auf Hosts ausführen", systemImage: "play.fill") { running = snippet }
                            Button("Bearbeiten", systemImage: "pencil") { editing = snippet }
                            Button("Kopieren", systemImage: "doc.on.doc") { UIPasteboard.general.string = snippet.command }
                            Divider()
                            Button("Löschen", systemImage: "trash", role: .destructive) { snippets.delete(snippet) }
                        }
                }
            }
            .padding(16)
        }
        .appBackground()
        .navigationTitle("Snippets")
        .searchable(text: $search, prompt: "Titel, Befehl oder Tag")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Snippet hinzufügen", systemImage: "plus") { editing = Snippet() }
            }
        }
        .sheet(item: $editing) { s in
            NavigationStack { SnippetEditorView(snippet: s) }
        }
        .sheet(item: $running) { s in
            NavigationStack { SnippetRunView(snippet: s) }
        }
    }
}

struct SnippetCard: View {
    let snippet: Snippet

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(snippet.title.isEmpty ? "Ohne Titel" : snippet.title).font(.headline)
                Spacer()
                ForEach(snippet.tags.prefix(3), id: \.self) { Badge(text: $0, symbol: "tag") }
            }
            Text(snippet.command)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .glassCard(cornerRadius: 20)
    }
}

struct SnippetEditorView: View {
    @EnvironmentObject private var snippets: SnippetStore
    @EnvironmentObject private var hosts: HostStore
    @Environment(\.dismiss) private var dismiss

    @State private var snippet: Snippet
    @State private var tagsText: String

    init(snippet: Snippet) {
        _snippet = State(initialValue: snippet)
        _tagsText = State(initialValue: snippet.tags.joined(separator: ", "))
    }

    var body: some View {
        Form {
            Section("Snippet") {
                TextField("Titel", text: $snippet.title)
                TextField("Befehl", text: $snippet.command, axis: .vertical)
                    .font(.body.monospaced())
                    .lineLimit(3...10)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Tags, durch Komma getrennt", text: $tagsText)
                    .textInputAutocapitalization(.never)
            }
            if !snippet.variables.isEmpty {
                Section("Variablen") {
                    Text(snippet.variables.map { "{{\($0)}}" }.joined(separator: "  "))
                        .font(.footnote.monospaced())
                }
            }
            Section {
                ForEach(hosts.hosts) { host in
                    Toggle(host.displayName, isOn: Binding(
                        get: { snippet.hostIDs.contains(host.id) },
                        set: { on in
                            if on { snippet.hostIDs.append(host.id) } else { snippet.hostIDs.removeAll { $0 == host.id } }
                        }
                    ))
                }
            } header: {
                Text("Nur für bestimmte Hosts")
            } footer: {
                Text("Keine Auswahl = für alle Hosts. Platzhalter schreibst du als {{name}}.")
            }
        }
        .appBackground()
        .navigationTitle(snippet.title.isEmpty ? "Neues Snippet" : snippet.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Abbrechen", systemImage: "xmark") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Sichern", systemImage: "checkmark") {
                    snippet.tags = SignRequest.parsePrincipals(tagsText)
                    snippets.upsert(snippet)
                    dismiss()
                }
                .disabled(snippet.command.trimmed.isEmpty)
            }
        }
    }
}

/// Variablen ausfüllen und auf einem oder mehreren Hosts ausführen.
struct SnippetRunView: View {
    let snippet: Snippet

    @EnvironmentObject private var hosts: HostStore
    @EnvironmentObject private var certificates: CertificateManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var runner = SnippetRunner()
    @State private var values: [String: String] = [:]
    @State private var selected: Set<UUID> = []
    @State private var started = false

    var body: some View {
        Form {
            if !snippet.variables.isEmpty {
                Section("Variablen") {
                    ForEach(snippet.variables, id: \.self) { name in
                        TextField(name, text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
            }
            Section("Befehl") {
                Text(snippet.render(values))
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
            Section("Hosts") {
                ForEach(hosts.hosts.filter { snippet.applies(to: $0) }) { host in
                    Toggle(host.displayName, isOn: Binding(
                        get: { selected.contains(host.id) },
                        set: { if $0 { selected.insert(host.id) } else { selected.remove(host.id) } }
                    ))
                }
            }
            if started {
                Section("Ergebnis") {
                    ForEach(runner.results) { r in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(r.hostName).font(.subheadline.weight(.semibold))
                                Spacer()
                                if r.running { ProgressView().controlSize(.small) }
                                else if let code = r.exitCode {
                                    Image(systemName: code == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(code == 0 ? .green : .red)
                                }
                            }
                            if !r.output.isEmpty {
                                ScrollView(.horizontal) {
                                    Text(r.output)
                                        .font(.caption2.monospaced())
                                        .textSelection(.enabled)
                                }
                                .frame(maxHeight: 220)
                            }
                        }
                    }
                }
            }
        }
        .appBackground()
        .navigationTitle(snippet.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Schließen", systemImage: "xmark") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Ausführen", systemImage: "play.fill") {
                    started = true
                    let targets = hosts.hosts.filter { selected.contains($0.id) }
                    let command = snippet.render(values)
                    Task { await runner.run(command, on: targets, certificates: certificates, hosts: hosts) }
                }
                .disabled(selected.isEmpty)
            }
        }
    }
}

/// Snippet-Auswahl innerhalb einer Session: füllt Variablen und tippt den Befehl ins Terminal.
struct SessionSnippetPicker: View {
    let session: TerminalSession
    @EnvironmentObject private var snippets: SnippetStore
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Snippet?
    @State private var values: [String: String] = [:]

    var body: some View {
        List {
            if let chosen {
                Section(chosen.title) {
                    ForEach(chosen.variables, id: \.self) { name in
                        TextField(name, text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Text(chosen.render(values)).font(.footnote.monospaced())
                    Button("Einfügen", systemImage: "text.insert") { insert(chosen, execute: false) }
                    Button("Ausführen", systemImage: "return") { insert(chosen, execute: true) }
                }
            } else {
                ForEach(snippets.snippets.filter { $0.applies(to: session.host) }) { s in
                    Button {
                        if s.variables.isEmpty { insert(s, execute: true) } else { chosen = s }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.title).font(.subheadline.weight(.semibold))
                            Text(s.command).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .tint(.primary)
                }
            }
        }
        .navigationTitle("Snippets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Schließen", systemImage: "xmark") { dismiss() } }
        }
    }

    private func insert(_ s: Snippet, execute: Bool) {
        session.send(text: s.render(values) + (execute ? "\r" : ""))
        dismiss()
    }
}
