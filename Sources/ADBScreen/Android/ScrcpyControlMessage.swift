import Foundation

/// Wire-compatible encoders for scrcpy's control protocol
/// (app/src/control_msg.c, SC_CONTROL_MSG_TYPE_*). Byte layouts are
/// reproduced exactly from the scrcpy v4.1 source.
enum ScrcpyControlMessageType: UInt8 {
    case injectKeycode = 0
    case injectText = 1
    case injectTouchEvent = 2
    case injectScrollEvent = 3
    case backOrScreenOn = 4
    case expandNotificationPanel = 5
    case expandSettingsPanel = 6
    case collapsePanels = 7
    case getClipboard = 8
    case setClipboard = 9
    case setDisplayPower = 10
    case rotateDevice = 11
    // 12-16 (UHID_CREATE/INPUT/DESTROY, OPEN_HARD_KEYBOARD_SETTINGS,
    // START_APP) intentionally unused here.
    case resetVideo = 17
}

enum AndroidKeyEventAction: UInt8 {
    case down = 0
    case up = 1
}

enum AndroidMotionEventAction: UInt8 {
    case down = 0
    case up = 1
    case move = 2
    case cancel = 3
}

enum AndroidMotionEventButton: UInt32 {
    case primary = 1 // AMOTION_EVENT_BUTTON_PRIMARY (left mouse button)
}

struct ScrcpyPosition {
    let x: Int32
    let y: Int32
    let screenWidth: UInt16
    let screenHeight: UInt16
}

enum ScrcpyPointerID {
    static let mouse: UInt64 = UInt64.max // SC_POINTER_ID_MOUSE = -1
}

enum ScrcpyControlMessage {
    private static func writePosition(_ pos: ScrcpyPosition, into buf: inout [UInt8], at o: Int) {
        BE.writeU32(UInt32(bitPattern: pos.x), into: &buf, at: o)
        BE.writeU32(UInt32(bitPattern: pos.y), into: &buf, at: o + 4)
        BE.writeU16(pos.screenWidth, into: &buf, at: o + 8)
        BE.writeU16(pos.screenHeight, into: &buf, at: o + 10)
    }

    static func touch(action: AndroidMotionEventAction, pointerID: UInt64, position: ScrcpyPosition,
                       pressure: Float, actionButton: UInt32, buttons: UInt32) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: 32)
        buf[0] = ScrcpyControlMessageType.injectTouchEvent.rawValue
        buf[1] = action.rawValue
        BE.writeU64(pointerID, into: &buf, at: 2)
        writePosition(position, into: &buf, at: 10)
        BE.writeU16(BE.floatToU16FP(pressure), into: &buf, at: 22)
        BE.writeU32(actionButton, into: &buf, at: 24)
        BE.writeU32(buttons, into: &buf, at: 28)
        return buf
    }

    static func scroll(position: ScrcpyPosition, hscroll: Float, vscroll: Float, buttons: UInt32) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: 21)
        buf[0] = ScrcpyControlMessageType.injectScrollEvent.rawValue
        writePosition(position, into: &buf, at: 1)
        let h = UInt16(bitPattern: BE.floatToI16FP(hscroll / 16))
        let v = UInt16(bitPattern: BE.floatToI16FP(vscroll / 16))
        BE.writeU16(h, into: &buf, at: 13)
        BE.writeU16(v, into: &buf, at: 15)
        BE.writeU32(buttons, into: &buf, at: 17)
        return buf
    }

    static func keycode(action: AndroidKeyEventAction, keycode: Int32, repeatCount: UInt32 = 0, metastate: UInt32 = 0) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: 14)
        buf[0] = ScrcpyControlMessageType.injectKeycode.rawValue
        buf[1] = action.rawValue
        BE.writeU32(UInt32(bitPattern: keycode), into: &buf, at: 2)
        BE.writeU32(repeatCount, into: &buf, at: 6)
        BE.writeU32(metastate, into: &buf, at: 10)
        return buf
    }

    static func backOrScreenOn(action: AndroidKeyEventAction) -> [UInt8] {
        [ScrcpyControlMessageType.backOrScreenOn.rawValue, action.rawValue]
    }

    static func text(_ string: String) -> [UInt8] {
        var buf: [UInt8] = [ScrcpyControlMessageType.injectText.rawValue]
        let utf8 = Array(string.utf8.prefix(300))
        var lenBuf = [UInt8](repeating: 0, count: 4)
        BE.writeU32(UInt32(utf8.count), into: &lenBuf, at: 0)
        buf.append(contentsOf: lenBuf)
        buf.append(contentsOf: utf8)
        return buf
    }

    static func simple(_ type: ScrcpyControlMessageType) -> [UInt8] {
        [type.rawValue]
    }

    /// SC_CONTROL_MSG_TYPE_SET_DISPLAY_POWER: `on == false` mirrors
    /// scrcpy's own "power off on start" behavior — it blanks the device
    /// screen (without locking it) while mirroring keeps running.
    static func setDisplayPower(on: Bool) -> [UInt8] {
        [ScrcpyControlMessageType.setDisplayPower.rawValue, on ? 1 : 0]
    }

    static func setClipboard(text: String, sequence: UInt64 = 0, paste: Bool = false) -> [UInt8] {
        var buf: [UInt8] = [ScrcpyControlMessageType.setClipboard.rawValue]
        var seqBuf = [UInt8](repeating: 0, count: 8)
        BE.writeU64(sequence, into: &seqBuf, at: 0)
        buf.append(contentsOf: seqBuf)
        buf.append(paste ? 1 : 0)
        let utf8 = Array(text.utf8.prefix(0x3FFF6)) // SC_CONTROL_MSG_CLIPBOARD_TEXT_MAX_LENGTH
        var lenBuf = [UInt8](repeating: 0, count: 4)
        BE.writeU32(UInt32(utf8.count), into: &lenBuf, at: 0)
        buf.append(contentsOf: lenBuf)
        buf.append(contentsOf: utf8)
        return buf
    }
}
