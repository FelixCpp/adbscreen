import AppKit

/// Maps a handful of non-printable macOS virtual key codes to Android
/// KeyEvent keycodes. Printable characters are sent via INJECT_TEXT instead
/// (see MirrorNSView.keyDown), so this only needs to cover control keys.
enum AndroidKeycodeMap {
    private static let map: [UInt16: Int32] = [
        36: 66,  // Return -> KEYCODE_ENTER
        76: 66,  // Keypad Enter -> KEYCODE_ENTER
        48: 61,  // Tab -> KEYCODE_TAB
        51: 67,  // Delete (backspace) -> KEYCODE_DEL
        117: 112, // Forward Delete -> KEYCODE_FORWARD_DEL
        53: 111, // Escape -> KEYCODE_ESCAPE
        123: 21, // Left -> KEYCODE_DPAD_LEFT
        124: 22, // Right -> KEYCODE_DPAD_RIGHT
        125: 20, // Down -> KEYCODE_DPAD_DOWN
        126: 19, // Up -> KEYCODE_DPAD_UP
        115: 122, // Home -> KEYCODE_MOVE_HOME
        119: 123, // End -> KEYCODE_MOVE_END
    ]

    static func keycode(for event: NSEvent) -> Int32? {
        map[event.keyCode]
    }
}
