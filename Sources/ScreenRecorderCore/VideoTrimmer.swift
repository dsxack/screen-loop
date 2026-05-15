@preconcurrency import AVFoundation
import Foundation

public enum TrimOutputMode: Equatable, Sendable {
    case createNew
    case replaceOriginal
}

public struct TrimResult: Equatable, Sendable {
    public let url: URL
    public let duration: TimeInterval
    public let replacedOriginal: Bool

    public init(url: URL, duration: TimeInterval, replacedOriginal: Bool) {
        self.url = url
        self.duration = duration
        self.replacedOriginal = replacedOriginal
    }
}

public enum VideoTrimmerError: LocalizedError {
    case invalidRange
    case missingVideoTrack(URL)
    case cannotCreateExportSession
    case exportFailed(String)
    case exportCancelled
    case cannotReplaceOriginal(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRange:
            return "Choose a valid start and end time."
        case .missingVideoTrack(let url):
            return "Clip has no video track: \(url.lastPathComponent)"
        case .cannotCreateExportSession:
            return "Could not create the trim export session."
        case .exportFailed(let message):
            return message
        case .exportCancelled:
            return "Trim export was cancelled."
        case .cannotReplaceOriginal(let message):
            return message
        }
    }
}

public final class VideoTrimmer {
    private let fileManager: FileManager
    private let minimumDuration: TimeInterval

    public init(fileManager: FileManager = .default, minimumDuration: TimeInterval = 0.5) {
        self.fileManager = fileManager
        self.minimumDuration = minimumDuration
    }

    public func trim(
        sourceURL: URL,
        startTime: TimeInterval,
        endTime: TimeInterval,
        mode: TrimOutputMode,
        date: Date = Date()
    ) async throws -> TrimResult {
        let asset = AVURLAsset(url: sourceURL)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
            throw VideoTrimmerError.missingVideoTrack(sourceURL)
        }

        let assetDuration = try await asset.load(.duration).seconds
        guard assetDuration.isFinite, assetDuration > 0 else {
            throw VideoTrimmerError.invalidRange
        }

        let clampedStart = max(0, startTime)
        let clampedEnd = min(endTime, assetDuration)
        let outputDuration = clampedEnd - clampedStart
        guard clampedStart < clampedEnd, outputDuration >= minimumDuration else {
            throw VideoTrimmerError.invalidRange
        }

        let outputURL = try outputURL(for: sourceURL, mode: mode, date: date)
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw VideoTrimmerError.cannotCreateExportSession
        }
        let exportSessionBox = TrimExportSessionBox(exportSession)
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov
        exportSession.shouldOptimizeForNetworkUse = true
        exportSession.timeRange = CMTimeRange(
            start: CMTime(seconds: clampedStart, preferredTimescale: 600),
            duration: CMTime(seconds: outputDuration, preferredTimescale: 600)
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportSession.exportAsynchronously {
                switch exportSessionBox.session.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: VideoTrimmerError.exportCancelled)
                case .failed:
                    continuation.resume(throwing: exportSessionBox.session.error ?? VideoTrimmerError.exportFailed("Trim export failed."))
                default:
                    continuation.resume(throwing: VideoTrimmerError.exportFailed("Trim export ended with status \(exportSessionBox.session.status.rawValue)."))
                }
            }
        }

        switch mode {
        case .createNew:
            return TrimResult(url: outputURL, duration: outputDuration, replacedOriginal: false)
        case .replaceOriginal:
            do {
                _ = try fileManager.replaceItemAt(sourceURL, withItemAt: outputURL)
            } catch {
                try? fileManager.removeItem(at: outputURL)
                throw VideoTrimmerError.cannotReplaceOriginal(error.localizedDescription)
            }
            return TrimResult(url: sourceURL, duration: outputDuration, replacedOriginal: true)
        }
    }

    private func outputURL(for sourceURL: URL, mode: TrimOutputMode, date: Date) throws -> URL {
        let directory = sourceURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        switch mode {
        case .createNew:
            let baseName = sourceURL.deletingPathExtension().lastPathComponent
            let stem = "\(baseName) - Trimmed \(Self.fileStamp(from: date))"
            var candidate = directory.appendingPathComponent("\(stem).mov")
            var counter = 2
            while fileManager.fileExists(atPath: candidate.path) {
                candidate = directory.appendingPathComponent("\(stem) \(counter).mov")
                counter += 1
            }
            return candidate
        case .replaceOriginal:
            return directory.appendingPathComponent(".trim-\(UUID().uuidString).mov")
        }
    }

    private static func fileStamp(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter.string(from: date)
    }
}

private final class TrimExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}
