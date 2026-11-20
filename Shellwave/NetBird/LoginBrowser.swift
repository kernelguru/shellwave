import SafariServices
import UIKit

/// Zeigt den NetBird-Login im In-App-Browser über allem anderen an – egal ob gerade
/// ein Terminal, ein Editor oder eine Einstellungsseite offen ist.
@MainActor
final class LoginBrowser: NSObject, SFSafariViewControllerDelegate {
    static let shared = LoginBrowser()

    private weak var controller: SFSafariViewController?
    /// Wird gerufen, wenn der Nutzer den Browser selbst schließt.
    var onUserDismiss: (() -> Void)?

    func show(_ url: URL) {
        dismiss()
        guard let top = Self.topController() else { return }
        let safari = SFSafariViewController(url: url)
        safari.delegate = self
        safari.dismissButtonStyle = .cancel
        safari.modalPresentationStyle = .pageSheet
        controller = safari
        top.present(safari, animated: true)
    }

    func dismiss() {
        guard let controller else { return }
        self.controller = nil
        controller.dismiss(animated: true)
    }

    nonisolated func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        MainActor.assumeIsolated {
            guard self.controller === controller else { return }
            self.controller = nil
            onUserDismiss?()
        }
    }

    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
