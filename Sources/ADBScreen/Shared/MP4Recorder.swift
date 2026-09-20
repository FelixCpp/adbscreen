import AVFoundation
import CoreMedia

/// Remuxes the already-compressed H.264 sample buffers we build for display
/// straight into an MP4 file via AVAssetWriter passthrough (outputSettings:
/// nil) — no re-encoding, since the bytes are identical to what's already
/// being decoded and shown live. Video-only, no audio track.
final class MP4Recorder {
    enum RecorderError: LocalizedError {
        case cannotAddInput
        case writerFailed(Error?)

        var errorDescription: String? {
            switch self {
            case .cannotAddInput:
                return "Aufnahme-Eingang konnte nicht erstellt werden."
            case .writerFailed(let error):
                return error?.localizedDescription ?? "Aufnahme fehlgeschlagen."
            }
        }
    }

    let outputURL: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var sessionStarted = false

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func start(formatDescription: CMFormatDescription) throws {
        try? FileManager.default.removeItem(at: outputURL)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formatDescription)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else { throw RecorderError.cannotAddInput }
        writer.add(input)
        guard writer.startWriting() else { throw RecorderError.writerFailed(writer.error) }

        self.writer = writer
        self.input = input
        self.sessionStarted = false
    }

    /// Call from the session's own frame-processing thread, one at a time,
    /// in presentation order — matches how the display path already drives
    /// this (see ScrcpySession/AirPlayReceiverSession).
    func append(_ sampleBuffer: CMSampleBuffer) {
        guard let writer, let input, writer.status == .writing else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            sessionStarted = true
        }
        guard input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    func stop(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let writer, let input else {
            DispatchQueue.main.async { completion(.success(())) }
            return
        }
        input.markAsFinished()
        writer.finishWriting {
            DispatchQueue.main.async {
                if writer.status == .completed {
                    completion(.success(()))
                } else {
                    completion(.failure(RecorderError.writerFailed(writer.error)))
                }
            }
        }
    }
}
