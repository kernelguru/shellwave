import SwiftUI
import UIKit

/// Terminal-Inhalt als normaler iOS-Text: markieren mit Lupe und Anfassern, kopieren.
struct TextSelectView: View {
    let text: String
    let visible: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied: String?

    var body: some View {
        NavigationStack {
            SelectableText(text: text)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Text auswählen")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Fertig") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Alles kopieren", systemImage: "doc.on.doc") { copy(text, label: "Alles kopiert") }
                            Button("Sichtbaren Bildschirm kopieren", systemImage: "rectangle.on.rectangle") {
                                copy(visible, label: "Bildschirm kopiert")
                            }
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                        }
                    }
                }
                .overlay(alignment: .bottom) {
                    if let copied {
                        Label(copied, systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .glassEffect(.regular, in: .capsule)
                            .padding(.bottom, 30)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
        }
    }

    private func copy(_ value: String, label: String) {
        UIPasteboard.general.string = value
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation { copied = label }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { copied = nil }
        }
    }
}

/// Nicht editierbare, auswählbare Textansicht, startet am Ende (neueste Ausgabe).
private struct SelectableText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 40, right: 10)
        view.alwaysBounceVertical = true
        view.text = text
        DispatchQueue.main.async {
            let bottom = max(0, view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
            view.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}
