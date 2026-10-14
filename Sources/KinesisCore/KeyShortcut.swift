import Foundation

/// A key combination you record yourself, such as ⌃⌥K, or a modifier on its own,
/// such as right Option for a push-to-talk app.
public struct KeyShortcut: Codable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
        public static let function = Modifiers(rawValue: 1 << 4)

        /// In the order macOS draws them, with the key code of the left-hand key.
        public static let ordered: [(modifier: Modifiers, symbol: String, keyCode: UInt16)] = [
            (.control, "⌃", 59), (.option, "⌥", 58), (.shift, "⇧", 56), (.command, "⌘", 55), (.function, "fn", 63),
        ]
    }

    /// The macOS virtual key code. For a modifier on its own, this is that modifier's key.
    public let keyCode: UInt16
    /// The modifiers held with the key. A modifier on its own includes itself.
    public let modifiers: Modifiers
    /// The key's name as recorded, such as "K", "space" or "→".
    public let key: String

    public init(keyCode: UInt16, modifiers: Modifiers, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// Key codes of the modifier keys, left and right, and which modifier each one is.
    public static let modifierKeys: [UInt16: Modifiers] = [
        55: .command, 54: .command, 56: .shift, 60: .shift,
        58: .option, 61: .option, 59: .control, 62: .control, 63: .function,
    ]

    /// Keys that macOS always reports with the fn flag, such as arrows and F-keys. The flag
    /// is part of the key, so it is not recorded as a modifier the person held.
    public static let keysCarryingFunctionFlag: Set<UInt16> = [
        123, 124, 125, 126, // arrows
        114, 115, 116, 117, 119, 121, // help, home, page up, forward delete, end, page down
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90, // F1–F20
    ]

    /// True for a modifier pressed on its own, such as right Option.
    public var isModifierOnly: Bool { Self.modifierKeys[keyCode] != nil }

    /// The modifiers other than the key itself, which go down before it and up after it.
    public var heldModifiers: Modifiers {
        guard let own = Self.modifierKeys[keyCode] else { return modifiers }
        return modifiers.subtracting(own)
    }

    /// How the shortcut reads in a menu: ⌃⌥K, ⇧⌘space, right ⌥.
    public var display: String {
        let symbols = Modifiers.ordered.filter { heldModifiers.contains($0.modifier) }.map(\.symbol)
        let joined = symbols.joined()
        let separator = symbols.last == "fn" ? " " : ""
        return joined.isEmpty ? key : joined + separator + key
    }

    /// The name of a key, for keys whose character is not printable or not obvious.
    public static func name(forKeyCode keyCode: UInt16) -> String? {
        switch keyCode {
        case 36: "return"
        case 48: "tab"
        case 49: "space"
        case 51: "delete"
        case 53: "esc"
        case 76: "enter"
        case 117: "⌦"
        case 115: "home"
        case 119: "end"
        case 116: "page up"
        case 121: "page down"
        case 123: "←"
        case 124: "→"
        case 125: "↓"
        case 126: "↑"
        case 122: "F1"
        case 120: "F2"
        case 99: "F3"
        case 118: "F4"
        case 96: "F5"
        case 97: "F6"
        case 98: "F7"
        case 100: "F8"
        case 101: "F9"
        case 109: "F10"
        case 103: "F11"
        case 111: "F12"
        case 105: "F13"
        case 107: "F14"
        case 113: "F15"
        case 106: "F16"
        case 64: "F17"
        case 79: "F18"
        case 80: "F19"
        case 90: "F20"
        case 55: "⌘"
        case 54: "right ⌘"
        case 56: "⇧"
        case 60: "right ⇧"
        case 58: "⌥"
        case 61: "right ⌥"
        case 59: "⌃"
        case 62: "right ⌃"
        case 63: "fn"
        default: nil
        }
    }
}
