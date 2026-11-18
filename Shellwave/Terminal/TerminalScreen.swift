import SwiftTerm
import SwiftUI
import UIKit

/// SwiftTerm-Terminal als SwiftUI-View, verbunden mit einer `TerminalSession`.
struct TerminalScreen: UIViewRepresentable {
    @ObservedObject var session: TerminalSession
    @Binding var fontSize: Double

    static let minFontSize: Double = 7
    static let maxFontSize: Double = 28

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, fontSize: $fontSize)
    }

    func makeUIView(context: Context) -> TerminalView {
        let view = session.terminalView
        view.terminalDelegate = context.coordinator
        view.font = Self.font(size: fontSize)

        // Zoomen mit zwei Fingern: Die View wird zwischen Sessions wiederverwendet,
        // daher alte Pinch-Gesten von früheren Coordinators entfernen.
        for gesture in view.gestureRecognizers ?? [] where gesture.name == "shellwave.pinch" {
            view.removeGestureRecognizer(gesture)
        }
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        pinch.name = "shellwave.pinch"
        pinch.delegate = context.coordinator
        view.addGestureRecognizer(pinch)

        DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        context.coordinator.fontSize = $fontSize
        if abs(Double(view.font.pointSize) - fontSize) > 0.1 {
            view.font = Self.font(size: fontSize)
        }
    }

    static func dismantleUIView(_ view: TerminalView, coordinator: Coordinator) {
        _ = view.resignFirstResponder()
        view.removeFromSuperview()
    }

    static func font(size: Double) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
    }

    final class Coordinator: NSObject, TerminalViewDelegate, UIGestureRecognizerDelegate {
        let session: TerminalSession
        var fontSize: Binding<Double>
        private var pinchStart: Double = 13

        init(session: TerminalSession, fontSize: Binding<Double>) {
            self.session = session
            self.fontSize = fontSize
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:
                pinchStart = fontSize.wrappedValue
            case .changed:
                // In halben Punkten schalten, damit der Server nicht bei jedem Pixel eine neue Größe bekommt
                let raw = pinchStart * Double(gesture.scale)
                let stepped = (raw * 2).rounded() / 2
                let clamped = min(max(stepped, TerminalScreen.minFontSize), TerminalScreen.maxFontSize)
                if clamped != fontSize.wrappedValue {
                    fontSize.wrappedValue = clamped
                    UISelectionFeedbackGenerator().selectionChanged()
                }
            default:
                break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            false
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
