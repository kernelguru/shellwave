import SwiftTerm
import SwiftUI
import UIKit

/// SwiftTerm-Terminal als SwiftUI-View, verbunden mit einer `TerminalSession`.
struct TerminalScreen: UIViewRepresentable {
    @ObservedObject var session: TerminalSession
    var fontSize: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeUIView(context: Context) -> TerminalView {
        let view = session.terminalView
        view.terminalDelegate = context.coordinator
        view.font = Self.font(size: fontSize)
        DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        if abs(view.font.pointSize - fontSize) > 0.1 {
            view.font = Self.font(size: fontSize)
        }
    }

    static func dismantleUIView(_ view: TerminalView, coordinator: Coordinator) {
        _ = view.resignFirstResponder()
        view.removeFromSuperview()
    }

    static func font(size: CGFloat) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: TerminalSession

        init(session: TerminalSession) {
            self.session = session
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Array(data)
            MainActor.assumeIsolated { session.send(bytes) }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated { session.resize(cols: newCols, rows: newRows) }
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            MainActor.assumeIsolated { session.setTitle(title) }
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func scrolled(source: TerminalView, position: Double) {}

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) {
                UIApplication.shared.open(url)
            }
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                UIPasteboard.general.string = text
            }
        }

        func clipboardRead(source: TerminalView) -> Data? {
            UIPasteboard.general.string.map { Data($0.utf8) }
        }
    }
}
