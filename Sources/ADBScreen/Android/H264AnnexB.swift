import Foundation

/// Splits an Annex-B byte stream (NAL units prefixed by 00 00 01 or
/// 00 00 00 01 start codes) into individual NAL unit byte ranges, and
/// converts to length-prefixed AVCC form for VideoToolbox / CMSampleBuffer.
///
/// MediaCodec's H.264 output on Android (what the scrcpy server forwards
/// verbatim) is Annex-B formatted.
enum H264AnnexB {
    /// Returns the byte ranges of each NAL unit (start code excluded).
    static func splitNALUnits(_ data: [UInt8]) -> [Range<Int>] {
        var starts: [(start: Int, codeLen: Int)] = []
        var i = 0
        let n = data.count
        while i + 2 < n {
            if data[i] == 0, data[i + 1] == 0 {
                if data[i + 2] == 1 {
                    starts.append((i + 3, 3))
                    i += 3
                    continue
                } else if i + 3 < n, data[i + 2] == 0, data[i + 3] == 1 {
                    starts.append((i + 4, 4))
                    i += 4
                    continue
                }
            }
            i += 1
        }
        guard !starts.isEmpty else { return [] }
        var ranges: [Range<Int>] = []
        for (idx, entry) in starts.enumerated() {
            let nalStart = entry.start
            let nextStart: Int
            if idx + 1 < starts.count {
                nextStart = starts[idx + 1].start - starts[idx + 1].codeLen
            } else {
                nextStart = n
            }
            if nalStart < nextStart {
                ranges.append(nalStart..<nextStart)
            }
        }
        return ranges
    }

    static func nalType(_ data: [UInt8], _ range: Range<Int>) -> UInt8 {
        data[range.lowerBound] & 0x1F
    }

    /// Rewrites an Annex-B buffer as AVCC (4-byte big-endian length prefixes),
    /// dropping any start codes. Ready to hand to CMBlockBuffer with a format
    /// description created with nalUnitHeaderLength = 4.
    static func annexBToAVCC(_ data: [UInt8], nalRanges: [Range<Int>]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(data.count + nalRanges.count * 4)
        for range in nalRanges {
            var lenBuf = [UInt8](repeating: 0, count: 4)
            BE.writeU32(UInt32(range.count), into: &lenBuf, at: 0)
            out.append(contentsOf: lenBuf)
            out.append(contentsOf: data[range])
        }
        return out
    }
}
