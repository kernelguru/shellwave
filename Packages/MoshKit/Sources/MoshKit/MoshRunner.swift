import Darwin
import Foundation
import mosh

/// Startet den Mosh-Client (aus Blinks mosh.xcframework) in einem eigenen Thread.
/// Ein- und Ausgabe laufen über Pipes, damit jede Terminal-View angeschlossen werden kann.
public final class MoshRunner: @unchecked Sendable {
    public struct Parameters: Sendable {
        public var ip: String
        public var port: String
        public var key: String
        public var predictMode: String

        public init(ip: String, port: String, key: String, predictMode: String = "adaptive") {
            self.ip = ip
            self.port = port
            self.key = key
            self.predictMode = predictMode
        }
    }

    /// Wird auf einem Hintergrund-Thread aufgerufen.
    public var onOutput: (([UInt8]) -> Void)?
    /// Exit-Code von mosh_main; ebenfalls Hintergrund-Thread.
    public var onExit: ((Int32) -> Void)?

    private let params: Parameters
    private let window: UnsafeMutablePointer<winsize>
    private var inputWrite: Int32 = -1
    private var thread: Thread?
    private let lock = NSLock()
    private var running = false

    public init(parameters: Parameters, cols: Int, rows: Int) {
        self.params = parameters
        window = .allocate(capacity: 1)
        window.initialize(to: winsize(ws_row: UInt16(max(rows, 1)), ws_col: UInt16(max(cols, 1)), ws_xpixel: 0, ws_ypixel: 0))
    }

    deinit {
        window.deallocate()
    }

    /// Einmalig beim App-Start: Mosh braucht eine UTF-8-Locale, die iOS nicht mitbringt.
    public static func prepareLocale(bundlePath: String?) {
        if let bundlePath {
            setenv("PATH_LOCALE", bundlePath, 1)
        }
        setenv("LANG", "en_US.UTF-8", 1)
        setenv("TERM", "xterm-256color", 1)
    }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }

        var inPipe: [Int32] = [0, 0]
        var outPipe: [Int32] = [0, 0]
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0 else {
            onExit?(-1)
            return
        }
        inputWrite = inPipe[1]
        running = true

        let inRead = inPipe[0]
        let outRead = outPipe[0]
        let outWrite = outPipe[1]

        // Ausgabe lesen
        let reader = Thread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let n = buffer.withUnsafeMutableBytes { read(outRead, $0.baseAddress, $0.count) }
                if n <= 0 { break }
                self?.onOutput?(Array(buffer[0..<n]))
            }
            close(outRead)
        }
        reader.name = "mosh-reader"
        reader.start()

        // mosh_main blockiert, bis die Session endet.
        let params = self.params
        let window = self.window
        let worker = Thread { [weak self] in
            let fIn = fdopen(inRead, "r")
            let fOut = fdopen(outWrite, "w")
            if let fOut { setvbuf(fOut, nil, _IONBF, 0) }

            let code: Int32 = params.ip.withCString { ip in
                params.port.withCString { port in
                    params.key.withCString { key in
                        params.predictMode.withCString { predict in
                            "no".withCString { overwrite in
                                mosh_main(fIn, fOut, window, nil, nil, ip, port, key, predict, nil, 0, overwrite)
                            }
                        }
                    }
                }
            }

            if let fIn { fclose(fIn) } else { close(inRead) }
            if let fOut { fclose(fOut) } else { close(outWrite) }
            self?.finish(code)
        }
        worker.name = "mosh-main"
        worker.stackSize = 16 * 1024 * 1024
        thread = worker
        worker.start()
    }

    private func finish(_ code: Int32) {
        lock.lock()
        running = false
        if inputWrite >= 0 { close(inputWrite); inputWrite = -1 }
        lock.unlock()
        onExit?(code)
    }

    public func write(_ bytes: [UInt8]) {
        lock.lock(); let fd = inputWrite; lock.unlock()
        guard fd >= 0, !bytes.isEmpty else { return }
        bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }

    public func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        window.pointee.ws_col = UInt16(cols)
        window.pointee.ws_row = UInt16(rows)
        // mosh lauscht auf SIGWINCH und liest dann die neue Größe aus `window`.
        kill(getpid(), SIGWINCH)
    }

    /// Beendet die Session: EOF auf der Eingabe lässt mosh sauber aussteigen.
    public func stop() {
        lock.lock()
        if inputWrite >= 0 { close(inputWrite); inputWrite = -1 }
        lock.unlock()
    }
}
