@preconcurrency import AVFoundation
import CoreMedia
import Foundation

public enum SegmentFileWriterError: LocalizedError {
    case cannotCreateWriter(URL)
    case cannotAddInput
    case cannotStartWriting(String)
    case appendFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cannotCreateWriter(let url):
            return "Could not create a writer for \(url.lastPathComponent)."
        case .cannotAddInput:
            return "Could not add the video input to the writer."
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
    private var firstPresentationTime: CMTime?
    private var lastPresentationTime: CMTime?
    private var firstSampleDate: Date?
    private var isFinishing = false

    public init(url: URL, geometry: VideoGeometry, frameRate: Int = 30, bitRate: Int? = nil) throws {
        self.url = url

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
    }

    public var elapsedAtLastFrame: TimeInterval {
        guard let firstPresentationTime, let lastPresentationTime else {
            return 0
        }
        return max(0, CMTimeGetSeconds(lastPresentationTime - firstPresentationTime))
    }

    public func append(_ sampleBuffer: CMSampleBuffer, receivedAt date: Date) throws {
        guard CMSampleBufferDataIsReady(sampleBuffer), !isFinishing else {
            return
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid else {
            return
        }

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

        lastPresentationTime = presentationTime
    }

    public func finish(completion: @escaping (Result<RecordedSegment?, Error>) -> Void) {
        guard !isFinishing else {
            completion(.success(nil))
            return
        }

        isFinishing = true

        guard let firstPresentationTime, let lastPresentationTime, let firstSampleDate else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            completion(.success(nil))
            return
        }

        let duration = max(0, CMTimeGetSeconds(lastPresentationTime - firstPresentationTime))
        guard duration > 0 else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            completion(.success(nil))
            return
        }

        input.markAsFinished()
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
}
