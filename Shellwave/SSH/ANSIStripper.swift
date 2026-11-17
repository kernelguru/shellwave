import Foundation

/// Entfernt ANSI-Escape-Sequenzen und Steuerzeichen aus Terminal-Ausgabe.
enum ANSIStripper {
    static func strip(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var it = text.unicodeScalars.makeIterator()
        while let c = it.next() {
            switch c {
            case "\u{1B}":
                guard let next = it.next() else { break }
                if next == "[" {
                    // CSI: bis zum Endbyte 0x40–0x7E
                    while let p = it.next(), !(0x40...0x7E).contains(p.value) {}
                } else if next == "]" {
                    // OSC: bis BEL oder ESC \
                    while let p = it.next() {
                        if p == "\u{07}" { break }
                        if p == "\u{1B}" { _ = it.next(); break }
                    }
                }
            case "\r":
                continue
            case "\n", "\t":
                out.append(c)
            default:
                if c.value >= 0x20 && c.value != 0x7F { out.append(c) }
            }
        }
        return String(out)
    }
}
