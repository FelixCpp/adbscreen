import CoreMedia

/// Low-level CoreMedia/VideoToolbox plumbing shared by every H.264 mirror
/// source (scrcpy's Android stream, the AirPlay/UxPlay receiver's iOS
/// stream): building a format description from SPS/PPS, and wrapping an
/// AVCC-framed access unit into a CMSampleBuffer ready for
/// AVSampleBufferDisplayLayer.
///
/// Samples carry a real (host-time-derived) presentationTimeStamp rather
/// than `.zero` — the `kCMSampleAttachmentKey_DisplayImmediately` flag set
/// below already makes AVSampleBufferDisplayLayer ignore PTS-based
/// scheduling for live low-latency display, so this doesn't affect
/// mirroring, but a real, monotonically increasing PTS is required for the
/// same sample buffers to double as input to AVAssetWriter when recording.
enum H264CoreMedia {
    static func makeFormatDescription(sps: [UInt8], pps: [UInt8]) -> CMVideoFormatDescription? {
        var result: CMVideoFormatDescription?
        sps.withUnsafeBufferPointer { spsPtr in
            pps.withUnsafeBufferPointer { ppsPtr in
                guard let spsBase = spsPtr.baseAddress, let ppsBase = ppsPtr.baseAddress else { return }
                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes: [Int] = [spsPtr.count, ppsPtr.count]
                _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &result
                )
            }
        }
        return result
    }

    static func makeSampleBuffer(avccData: [UInt8], formatDescription: CMVideoFormatDescription, isKeyFrame: Bool, presentationTimeStamp: CMTime) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let size = avccData.count
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: size,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: size,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard createStatus == kCMBlockBufferNoErr, let bb = blockBuffer else { return nil }

        let copyStatus = avccData.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: bb, offsetIntoDestination: 0, dataLength: size)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: presentationTimeStamp, decodeTimeStamp: .invalid)
        var sampleSize = size
        let sbStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sb = sampleBuffer else { return nil }

        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
           CFArrayGetCount(attachmentsArray) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachmentsArray, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                  Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                  Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !isKeyFrame {
                CFDictionarySetValue(dict,
                                      Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                      Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sb
    }
}
