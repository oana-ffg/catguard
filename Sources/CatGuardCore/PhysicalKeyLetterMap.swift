enum PhysicalKeyLetterMap {
    /// Maps macOS virtual key codes for the ANSI letter positions to their
    /// physical QWERTY letters. This deliberately ignores the active keyboard
    /// layout so the rescue phrase remains available while ordinary key events
    /// are being suppressed.
    static func letter(forMacVirtualKeyCode keyCode: Int64) -> Character? {
        switch keyCode {
        case 0: "a"
        case 1: "s"
        case 2: "d"
        case 3: "f"
        case 4: "h"
        case 5: "g"
        case 6: "z"
        case 7: "x"
        case 8: "c"
        case 9: "v"
        case 11: "b"
        case 12: "q"
        case 13: "w"
        case 14: "e"
        case 15: "r"
        case 16: "y"
        case 17: "t"
        case 31: "o"
        case 32: "u"
        case 34: "i"
        case 35: "p"
        case 37: "l"
        case 38: "j"
        case 40: "k"
        case 45: "n"
        case 46: "m"
        default: nil
        }
    }
}
