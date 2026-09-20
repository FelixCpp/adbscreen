import Foundation

/// Big-endian read/write helpers matching scrcpy's wire protocol (util/binary.h).
enum BE {
    static func u16(_ b: [UInt8], _ o: Int) -> UInt16 {
        (UInt16(b[o]) << 8) | UInt16(b[o + 1])
    }

    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
    }

    static func u64(_ b: [UInt8], _ o: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 {
            v = (v << 8) | UInt64(b[o + i])
        }
        return v
    }

    static func writeU16(_ v: UInt16, into buf: inout [UInt8], at o: Int) {
        buf[o] = UInt8((v >> 8) & 0xFF)
        buf[o + 1] = UInt8(v & 0xFF)
    }

    static func writeU32(_ v: UInt32, into buf: inout [UInt8], at o: Int) {
        buf[o] = UInt8((v >> 24) & 0xFF)
        buf[o + 1] = UInt8((v >> 16) & 0xFF)
        buf[o + 2] = UInt8((v >> 8) & 0xFF)
        buf[o + 3] = UInt8(v & 0xFF)
    }

    static func writeU64(_ v: UInt64, into buf: inout [UInt8], at o: Int) {
        for i in 0..<8 {
            let shift = UInt64(56 - i * 8)
            buf[o + i] = UInt8((v >> shift) & 0xFF)
        }
    }

    /// float in [-1, 1] -> Q0.15 fixed point, as used by sc_float_to_i16fp
    static func floatToI16FP(_ f: Float) -> Int16 {
        let clamped = max(-1, min(1, f))
        let v = clamped * 32767.0
        return Int16(v.rounded())
    }

    /// float in [0, 1] -> Q0.16 fixed point, as used by sc_float_to_u16fp
    static func floatToU16FP(_ f: Float) -> UInt16 {
        let clamped = max(0, min(1, f))
        if clamped >= 1 {
            return 0xFFFF
        }
        let v = clamped * 65536.0
        return UInt16(v.rounded())
    }
}
