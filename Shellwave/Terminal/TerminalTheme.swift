import Foundation
import SwiftTerm
import UIKit

/// Farbschema fürs Terminal: Hintergrund, Vordergrund, Cursor und die 16 ANSI-Farben (hex).
struct TerminalTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let background: String
    let foreground: String
    let cursor: String
    let ansi: [String]

    static let all: [TerminalTheme] = [shellwave, solarizedDark, nord, dracula]

    static let shellwave = TerminalTheme(
        id: "shellwave", name: "Shellwave",
        background: "05100F", foreground: "E8EEEC", cursor: "73F2CC",
        ansi: ["0B1A1C", "F2777A", "73F2CC", "F7D774", "6CB6FF", "C397F2", "5FD7D7", "D0D8D6",
               "4A5C5E", "FF9A9C", "9AF7DB", "FFE59A", "99CCFF", "DDB8FF", "8CEDED", "FFFFFF"]
    )

    static let solarizedDark = TerminalTheme(
        id: "solarized", name: "Solarized Dark",
        background: "002B36", foreground: "839496", cursor: "93A1A1",
        ansi: ["073642", "DC322F", "859900", "B58900", "268BD2", "D33682", "2AA198", "EEE8D5",
               "002B36", "CB4B16", "586E75", "657B83", "839496", "6C71C4", "93A1A1", "FDF6E3"]
    )

    static let nord = TerminalTheme(
        id: "nord", name: "Nord",
        background: "2E3440", foreground: "D8DEE9", cursor: "88C0D0",
        ansi: ["3B4252", "BF616A", "A3BE8C", "EBCB8B", "81A1C1", "B48EAD", "88C0D0", "E5E9F0",
               "4C566A", "BF616A", "A3BE8C", "EBCB8B", "81A1C1", "B48EAD", "8FBCBB", "ECEFF4"]
    )

    static let dracula = TerminalTheme(
        id: "dracula", name: "Dracula",
        background: "282A36", foreground: "F8F8F2", cursor: "F8F8F2",
        ansi: ["21222C", "FF5555", "50FA7B", "F1FA8C", "BD93F9", "FF79C6", "8BE9FD", "F8F8F2",
               "6272A4", "FF6E6E", "69FF94", "FFFFA5", "D6ACFF", "FF92DF", "A4FFFF", "FFFFFF"]
    )
}

enum TerminalThemeStore {
    private static let key = "terminal.theme"

    static var current: TerminalTheme {
        let id = UserDefaults.standard.string(forKey: key) ?? TerminalTheme.shellwave.id
        return TerminalTheme.all.first { $0.id == id } ?? .shellwave
    }

    static func select(_ theme: TerminalTheme) {
        UserDefaults.standard.set(theme.id, forKey: key)
    }

    @MainActor
    static func apply(_ theme: TerminalTheme, to view: TerminalView) {
        let bg = UIColor(hex: theme.background)
        view.backgroundColor = bg
        view.nativeBackgroundColor = bg
        view.nativeForegroundColor = UIColor(hex: theme.foreground)
        view.caretColor = UIColor(hex: theme.cursor)
        view.installColors(theme.ansi.map { SwiftTerm.Color(hex: $0) })
    }
}

extension UIColor {
    convenience init(hex: String) {
        let v = UInt32(hex, radix: 16) ?? 0
        self.init(
            red: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension SwiftTerm.Color {
    convenience init(hex: String) {
        let v = UInt32(hex, radix: 16) ?? 0
        self.init(
            red: UInt16((v >> 16) & 0xFF) * 257,
            green: UInt16((v >> 8) & 0xFF) * 257,
            blue: UInt16(v & 0xFF) * 257
        )
    }
}
