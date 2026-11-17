import Citadel
import Foundation
import NIOCore
import SwiftUI
import UniformTypeIdentifiers

/// Ein Eintrag im Dateibrowser.
struct RemoteFile: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let isDirectory: Bool
    let isLink: Bool
    let size: UInt64?
    let modified: Date?
    let permissions: UInt32?

    var symbol: String {
        if isDirectory { return "folder.fill" }
        if isLink { return "link" }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "heic", "webp": return "photo"
        case "mp4", "mkv", "mov", "avi": return "film"
        case "mp3", "flac", "wav", "m4a": return "music.note"
        case "zip", "gz", "tgz", "xz", "bz2", "7z", "tar": return "archivebox"
        case "sh", "py", "swift", "js", "ts", "go", "rs", "c", "h", "json", "yml", "yaml", "toml", "conf", "cfg", "ini":
            return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }

    var permissionString: String {
        guard let p = permissions else { return "" }
        let chars: [(UInt32, Character)] = [(0o400, "r"), (0o200, "w"), (0o100, "x"), (0o040, "r"), (0o020, "w"), (0o010, "x"), (0o004, "r"), (0o002, "w"), (0o001, "x")]
        return String(chars.map { p & $0.0 != 0 ? $0.1 : "-" })
    }
}

/// SFTP-Verbindung zu einem Host mit Verzeichnis-Navigation, Up- und Download.
@MainActor
final class SFTPModel: ObservableObject {
    @Published private(set) var path = ""
    @Published private(set) var files: [RemoteFile] = []
    @Published private(set) var loading = false
    @Published var error: String?
    @Published private(set) var transfer: String?

    let host: Host
    private let certificates: CertificateManager
    private let hosts: HostStore
    private var client: SSHClient?
    private var sftp: SFTPClient?

    init(host: Host, certificates: CertificateManager, hosts: HostStore) {
        self.host = host
        self.certificates = certificates
        self.hosts = hosts
    }

    func open() async {
        guard sftp == nil else { return }
        loading = true
        defer { loading = false }
        do {
            let client = try await SSHConnector.connect(to: host, certificates: certificates, hosts: hosts)
            self.client = client
            let sftp = try await client.openSFTP()
            self.sftp = sftp
            let home = try await sftp.getRealPath(atPath: ".")
            await list(home)
        } catch {
            self.error = TerminalSession.describe(error)
        }
    }

    func close() {
        let sftp = self.sftp, client = self.client
        self.sftp = nil
        self.client = nil
        Task {
            try? await sftp?.close()
            try? await client?.close()
        }
    }

    func list(_ newPath: String) async {
        guard let sftp else { return }
        loading = true
        defer { loading = false }
        do {
            let names = try await sftp.listDirectory(atPath: newPath)
            var result: [RemoteFile] = []
            for name in names {
                for component in name.components where component.filename != "." && component.filename != ".." {
                    let attrs = component.attributes
                    let mode = attrs.permissions
                    let type = (mode ?? 0) & 0o170000
                    let isDir = type == 0o040000 || (mode == nil && component.longname.hasPrefix("d"))
                    let isLink = type == 0o120000 || component.longname.hasPrefix("l")
                    result.append(RemoteFile(
                        name: component.filename,
                        path: Self.join(newPath, component.filename),
                        isDirectory: isDir,
                        isLink: isLink,
                        size: attrs.size,
                        modified: attrs.accessModificationTime?.modificationTime,
                        permissions: mode.map { $0 & 0o777 }
                    ))
                }
            }
            files = result.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            path = newPath
        } catch {
            self.error = TerminalSession.describe(error)
        }
    }

    func enter(_ file: RemoteFile) async {
        if file.isDirectory || file.isLink {
            await list(file.path)
        }
    }

    func up() async {
        guard path != "/" else { return }
        let parent = (path as NSString).deletingLastPathComponent
        await list(parent.isEmpty ? "/" : parent)
    }

    /// Lädt eine Datei in einen temporären Ordner und liefert die lokale URL.
    func download(_ file: RemoteFile) async -> URL? {
        guard let sftp else { return nil }
        transfer = "Lade \(file.name) …"
        defer { transfer = nil }
        do {
            let handle = try await sftp.openFile(filePath: file.path, flags: .read)
            var data = Data()
            var offset: UInt64 = 0
            let chunk: UInt32 = 32 * 1024
            while true {
                let buffer = try await handle.read(from: offset, length: chunk)
                if buffer.readableBytes == 0 { break }
                data.append(contentsOf: buffer.readableBytesView)
                offset += UInt64(buffer.readableBytes)
                if let size = file.size {
                    transfer = "Lade \(file.name) … \(Int(Double(offset) / Double(max(size, 1)) * 100)) %"
                }
            }
            try await handle.close()
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sftp", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(file.name)
            try? FileManager.default.removeItem(at: url)
            try data.write(to: url)
            return url
        } catch {
            self.error = TerminalSession.describe(error)
            return nil
        }
    }

    func upload(_ url: URL) async {
        guard let sftp else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        transfer = "Lade \(url.lastPathComponent) hoch …"
        defer { transfer = nil }
        do {
            let data = try Data(contentsOf: url)
            let target = Self.join(path, url.lastPathComponent)
            let handle = try await sftp.openFile(filePath: target, flags: [.write, .create, .truncate])
            var offset = 0
            let chunk = 32 * 1024
            while offset < data.count {
                let end = min(offset + chunk, data.count)
                try await handle.write(ByteBuffer(bytes: data[offset..<end]), at: UInt64(offset))
                offset = end
                transfer = "Lade \(url.lastPathComponent) hoch … \(offset * 100 / max(data.count, 1)) %"
            }
            try await handle.close()
            await list(path)
        } catch {
            self.error = TerminalSession.describe(error)
        }
    }

    func makeDirectory(_ name: String) async {
        guard let sftp, !name.trimmed.isEmpty else { return }
        do {
            try await sftp.createDirectory(atPath: Self.join(path, name.trimmed))
            await list(path)
        } catch {
            self.error = TerminalSession.describe(error)
        }
    }

    func delete(_ file: RemoteFile) async {
        guard let sftp else { return }
        do {
            if file.isDirectory {
                try await sftp.rmdir(at: file.path)
            } else {
                try await sftp.remove(at: file.path)
            }
            await list(path)
        } catch {
            self.error = TerminalSession.describe(error)
        }
    }

    func rename(_ file: RemoteFile, to name: String) async {
        guard let sftp, !name.trimmed.isEmpty else { return }
        do {
            try await sftp.rename(at: file.path, to: Self.join(path, name.trimmed))
            await list(path)
        } catch {
            self.error = TerminalSession.describe(error)
        }
    }

    static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }
}

struct SFTPBrowserView: View {
    @StateObject private var model: SFTPModel
    @Environment(\.dismiss) private var dismiss
    @State private var shareURL: URL?
    @State private var showImporter = false
    @State private var newFolder = ""
    @State private var showNewFolder = false
    @State private var renaming: RemoteFile?
    @State private var renameText = ""

    init(host: Host, certificates: CertificateManager, hosts: HostStore) {
        _model = StateObject(wrappedValue: SFTPModel(host: host, certificates: certificates, hosts: hosts))
    }

    var body: some View {
        List {
            if model.path != "/" && !model.path.isEmpty {
                Button {
                    Task { await model.up() }
                } label: {
                    Label("..", systemImage: "arrow.turn.left.up")
                }
                .tint(.primary)
            }
            ForEach(model.files) { file in
                Button {
                    Task {
                        if file.isDirectory || file.isLink {
                            await model.enter(file)
                        } else if let url = await model.download(file) {
                            shareURL = url
                        }
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: file.symbol)
                            .foregroundStyle(file.isDirectory ? Theme.mint : .secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name).lineLimit(1)
                            HStack(spacing: 8) {
                                if let size = file.size, !file.isDirectory {
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                }
                                if let date = file.modified {
                                    Text(date.formatted(date: .abbreviated, time: .shortened))
                                }
                                Text(file.permissionString).monospaced()
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .tint(.primary)
                .swipeActions {
                    Button("Löschen", systemImage: "trash", role: .destructive) {
                        Task { await model.delete(file) }
                    }
                    Button("Umbenennen", systemImage: "pencil") {
                        renameText = file.name
                        renaming = file
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .overlay {
            if model.loading && model.files.isEmpty { ProgressView() }
        }
        .safeAreaInset(edge: .bottom) {
            if let transfer = model.transfer {
                Text(transfer)
                    .font(.footnote)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 8)
            }
        }
        .navigationTitle(model.path.isEmpty ? model.host.displayName : (model.path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Schließen", systemImage: "xmark") { model.close(); dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Datei hochladen", systemImage: "square.and.arrow.up") { showImporter = true }
                    Button("Neuer Ordner", systemImage: "folder.badge.plus") { showNewFolder = true }
                    Button("Aktualisieren", systemImage: "arrow.clockwise") { Task { await model.list(model.path) } }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task { await model.open() }
        .refreshable { await model.list(model.path) }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { for url in urls { await model.upload(url) } }
        }
        .sheet(item: $shareURL) { url in
            ShareSheet(items: [url])
        }
        .alert("Neuer Ordner", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolder)
            Button("Anlegen") { Task { await model.makeDirectory(newFolder); newFolder = "" } }
            Button("Abbrechen", role: .cancel) { newFolder = "" }
        }
        .alert("Umbenennen", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Umbenennen") {
                if let file = renaming { Task { await model.rename(file, to: renameText) } }
                renaming = nil
            }
            Button("Abbrechen", role: .cancel) { renaming = nil }
        }
        .alert("Fehler", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// UIActivityViewController für „Teilen“ und „In Dateien sichern“.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
