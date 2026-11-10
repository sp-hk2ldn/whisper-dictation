import Carbon

/// A configurable registered-hotkey chord. Registration is deliberately left
/// to a live macOS adapter; this value has no keyboard-monitoring behavior.
public struct HotkeyChord: Sendable, Equatable, Hashable {
    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// An explicit chord that avoids normal terminal text entry.
    public static let pushToTalkDefault = HotkeyChord(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(controlKey | optionKey | cmdKey)
    )

    public var title: String {
        let symbols = [
            (UInt32(controlKey), "⌃"),
            (UInt32(optionKey), "⌥"),
            (UInt32(shiftKey), "⇧"),
            (UInt32(cmdKey), "⌘"),
        ]
        .filter { modifiers & $0.0 != 0 }
        .map(\.1)
        .joined()

        return symbols + Self.keyName(for: keyCode)
    }

    public var validationMessage: String? {
        if Self.extendedFunctionKeyCodes.contains(keyCode) {
            return nil
        }

        let modifierCount = [
            UInt32(controlKey),
            UInt32(optionKey),
            UInt32(shiftKey),
            UInt32(cmdKey),
        ]
        .count { modifiers & $0 != 0 }

        guard modifierCount >= 2 else {
            return "Use at least two modifier keys, or choose F13–F20."
        }
        return nil
    }

    private static let extendedFunctionKeyCodes: Set<UInt32> = [
        UInt32(kVK_F13),
        UInt32(kVK_F14),
        UInt32(kVK_F15),
        UInt32(kVK_F16),
        UInt32(kVK_F17),
        UInt32(kVK_F18),
        UInt32(kVK_F19),
        UInt32(kVK_F20),
    ]

    private static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: "A"
        case kVK_ANSI_B: "B"
        case kVK_ANSI_C: "C"
        case kVK_ANSI_D: "D"
        case kVK_ANSI_E: "E"
        case kVK_ANSI_F: "F"
        case kVK_ANSI_G: "G"
        case kVK_ANSI_H: "H"
        case kVK_ANSI_I: "I"
        case kVK_ANSI_J: "J"
        case kVK_ANSI_K: "K"
        case kVK_ANSI_L: "L"
        case kVK_ANSI_M: "M"
        case kVK_ANSI_N: "N"
        case kVK_ANSI_O: "O"
        case kVK_ANSI_P: "P"
        case kVK_ANSI_Q: "Q"
        case kVK_ANSI_R: "R"
        case kVK_ANSI_S: "S"
        case kVK_ANSI_T: "T"
        case kVK_ANSI_U: "U"
        case kVK_ANSI_V: "V"
        case kVK_ANSI_W: "W"
        case kVK_ANSI_X: "X"
        case kVK_ANSI_Y: "Y"
        case kVK_ANSI_Z: "Z"
        case kVK_ANSI_0: "0"
        case kVK_ANSI_1: "1"
        case kVK_ANSI_2: "2"
        case kVK_ANSI_3: "3"
        case kVK_ANSI_4: "4"
        case kVK_ANSI_5: "5"
        case kVK_ANSI_6: "6"
        case kVK_ANSI_7: "7"
        case kVK_ANSI_8: "8"
        case kVK_ANSI_9: "9"
        case kVK_Space: "Space"
        case kVK_Tab: "Tab"
        case kVK_Return: "Return"
        case kVK_Delete: "Delete"
        case kVK_ForwardDelete: "Forward Delete"
        case kVK_Home: "Home"
        case kVK_End: "End"
        case kVK_PageUp: "Page Up"
        case kVK_PageDown: "Page Down"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        case kVK_F1: "F1"
        case kVK_F2: "F2"
        case kVK_F3: "F3"
        case kVK_F4: "F4"
        case kVK_F5: "F5"
        case kVK_F6: "F6"
        case kVK_F7: "F7"
        case kVK_F8: "F8"
        case kVK_F9: "F9"
        case kVK_F10: "F10"
        case kVK_F11: "F11"
        case kVK_F12: "F12"
        case kVK_F13: "F13"
        case kVK_F14: "F14"
        case kVK_F15: "F15"
        case kVK_F16: "F16"
        case kVK_F17: "F17"
        case kVK_F18: "F18"
        case kVK_F19: "F19"
        case kVK_F20: "F20"
        case kVK_ANSI_Equal: "="
        case kVK_ANSI_Minus: "−"
        case kVK_ANSI_LeftBracket: "["
        case kVK_ANSI_RightBracket: "]"
        case kVK_ANSI_Semicolon: ";"
        case kVK_ANSI_Quote: "'"
        case kVK_ANSI_Comma: ","
        case kVK_ANSI_Period: "."
        case kVK_ANSI_Slash: "/"
        case kVK_ANSI_Backslash: "\\"
        case kVK_ANSI_Grave: "`"
        default: "Key \(keyCode)"
        }
    }
}

public enum PushToTalkEvent: Sendable, Equatable {
    case pressed
    case released
}

/// Converts raw down/up edges into one push-to-talk transition each.
///
/// The filter is intentionally independent of Carbon so repeated key-down
/// events can be handled deterministically before a live registration adapter
/// is introduced.
public struct PushToTalkEdgeFilter: Sendable {
    private var isPressed = false

    public init() {}

    public mutating func receiveKeyDown() -> PushToTalkEvent? {
        guard !isPressed else { return nil }
        isPressed = true
        return .pressed
    }

    public mutating func receiveKeyUp() -> PushToTalkEvent? {
        guard isPressed else { return nil }
        isPressed = false
        return .released
    }
}
