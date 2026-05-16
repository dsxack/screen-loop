@preconcurrency import AVFoundation
import CoreMedia
import Foundation

public enum SegmentFileWriterError: LocalizedError {
    case cannotCreateWriter(URL)
    case cannotAddInput
    case cannotAddAudioInput
    case cannotStartWriting(String)
    case appendFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cannotCreateWriter(let url):
            return "Could not create a writer for \(url.lastPathComponent)."
        case .cannotAddInput:
            return "Could not add the video input to the writer."
        case .cannotAddAudioInput:
            return "Could not add the audio input to the writer."
        case .cannotStartWriting(let message):
            return message
        case .appendFailed(let message):
            return message
        }
    }
}

public final class SegmentFileWriter {
    public let url: URL

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let fallbackVideoFrameDuration: CMTime
    private var firstPresentationTime: CMTime?
    private var lastVideoEndTime: CMTime?
    private var lastMediaEndTime: CMTime?
    private var firstSampleDate: Date?
    private var isFinishing = false

    public init(
        url: URL,
        geometry: VideoGeometry,
        frameRate: Int = 30,
        bitRate: Int? = nil,
        capturesAudio: Bool = false
    ) throws {
        self.url = url
        fallbackVideoFrameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, frameRate)))

        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw SegmentFileWriterError.cannotCreateWriter(url)
        }

        let bitRate = bitRate ?? Self.bitRate(width: geometry.width, height: geometry.height, frameRate: frameRate)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: geometry.width,
            AVVideoHeightKey: geometry.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw SegmentFileWriterError.cannotAddInput
        }
        writer.add(input)

        if capturesAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ]
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = true

            guard writer.canAdd(audioInput) else {
                throw SegmentFileWriterError.cannotAddAudioInput
            }
            writer.add(audioInput)
            self.audioInput = audioInput
        } else {
            audioInput = nil
        }
    }

    public var elapsedAtLastFrame: TimeInterval {
        guard let firstPresentationTime, let lastVideoEndTime else {
            return 0
        }
        return max(0, CMTimeGetSeconds(lastVideoEndTime - firstPresentationTime))
    }

    public func append(_ sampleBuffer: CMSampleBuffer, receivedAt date: Date) throws {
        guard CMSampleBufferDataIsReady(sampleBuffer), !isFinishing else {
            return
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid else {
            return
        }
        let sampleEndTime = Self.sampleEndTime(
            for: sampleBuffer,
            presentationTime: presentationTime,
            fallbackDuration: fallbackVideoFrameDuration
        )

        if firstPresentationTime == nil {
            guard writer.startWriting() else {
                throw SegmentFileWriterError.cannotStartWriting(
                    writer.error?.localizedDescription ?? "Could not start writing."
                )
            }
            writer.startSession(atSourceTime: presentationTime)
            firstPresentationTime = presentationTime
            firstSampleDate = date
        }

        guard writer.status == .writing else {
            throw SegmentFileWriterError.appendFailed(
                writer.error?.localizedDescription ?? "Writer is not accepting frames."
            )
        }

        guard input.isReadyForMoreMediaData else {
            return
        }

        guard input.append(sampleBuffer) else {
            throw SegmentFileWriterError.appendFailed(
                writer.error?.localizedDescription ?? "Could not append a frame."
            )
        }

        updateLastVideoEndTime(sampleEndTime)
        updateLastMediaEndTime(sampleEndTime)
    }

    public func appendAudio(_ sampleBuffer: CMSampleBuffer) throws {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              !isFinishing,
              let audioInput,
              let firstPresentationTime else {
            return
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid,
              presentationTime >= firstPresentationTime else {
            return
        }
        let sampleEndTime = Self.sampleEndTime(
            for: sampleBuffer,
            presentationTime: presentationTime,
            fallbackDuration: Self.audioFallbackDuration(for: sampleBuffer)
        )

        guard writer.status == .writing else {
            throw SegmentFileWriterError.appendFailed(
                writer.error?.localizedDescription ?? "Writer is not accepting audio."
            )
        }

        guard audioInput.isReadyForMoreMediaData else {
            return
        }

        guard audioInput.append(sampleBuffer) else {
            throw SegmentFileWriterError.appendFailed(
                writer.error?.localizedDescription ?? "Could not append audio."
            )
        }

        updateLastMediaEndTime(sampleEndTime)
    }

    public func finish(completion: @escaping (Result<RecordedSegment?, Error>) -> Void) {
        guard !isFinishing else {
            completion(.success(nil))
            return
        }

        isFinishing = true

        guard let firstPresentationTime, let lastMediaEndTime, let firstSampleDate else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            completion(.success(nil))
            return
        }

        let duration = max(0, CMTimeGetSeconds(lastMediaEndTime - firstPresentationTime))
        guard duration > 0 else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            completion(.success(nil))
            return
        }

        writer.endSession(atSourceTime: lastMediaEndTime)
        input.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting { [url] in
            if let error = self.writer.error {
                completion(.failure(error))
                return
            }

            let segment = RecordedSegment(
                url: url,
                startDate: firstSampleDate,
                endDate: firstSampleDate.addingTimeInterval(duration)
            )
            completion(.success(segment))
        }
    }

    private static func bitRate(width: Int, height: Int, frameRate: Int) -> Int {
        let pixels = max(1, width * height)
        let referencePixels = 1920 * 1080
        let referenceBitRate = 8_000_000
        let scaled = Double(referenceBitRate) * (Double(pixels) / Double(referencePixels)) * (Double(frameRate) / 30.0)
        return max(2_500_000, Int(scaled))
    }

    private func updateLastMediaEndTime(_ time: CMTime) {
        guard time.isValid else {
            return
        }

        guard let lastMediaEndTime else {
            self.lastMediaEndTime = time
            return
        }

        if time > lastMediaEndTime {
            self.lastMediaEndTime = time
        }
    }

    private func updateLastVideoEndTime(_ time: CMTime) {
        guard time.isValid else {
            return
        }

        guard let lastVideoEndTime else {
            self.lastVideoEndTime = time
            return
        }

        if time > lastVideoEndTime {
            self.lastVideoEndTime = time
        }
    }

    private static func sampleEndTime(
        for sampleBuffer: CMSampleBuffer,
        presentationTime: CMTime,
        fallbackDuration: CMTime?
    ) -> CMTime {
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        if duration.isValid, duration > .zero {
            return presentationTime + duration
        }

        if let fallbackDuration, fallbackDuration.isValid, fallbackDuration > .zero {
            return presentationTime + fallbackDuration
        }

        return presentationTime
    }

    private static func audioFallbackDuration(for sampleBuffer: CMSampleBuffer) -> CMTime? {
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        let sampleRate = streamDescription.pointee.mSampleRate
        guard sampleRate > 0 else {
            return nil
        }

        return CMTime(seconds: Double(sampleCount) / sampleRate, preferredTimescale: 600_000)
    }
}
