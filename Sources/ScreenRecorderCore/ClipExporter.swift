@preconcurrency import AVFoundation
import Foundation

public enum ClipExporterError: LocalizedError {
    case emptySelection
    case missingVideoTrack(URL)
    case cannotCreateCompositionTrack
    case cannotCreateExportSession
    case exportFailed(String)
    case exportCancelled

    public var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "There are no recorded segments to export."
        case .missingVideoTrack(let url):
            return "Segment has no video track: \(url.lastPathComponent)"
        case .cannotCreateCompositionTrack:
            return "Could not create the output video track."
        case .cannotCreateExportSession:
            return "Could not create the export session."
        case .exportFailed(let message):
            return message
        case .exportCancelled:
            return "Export was cancelled."
        }
    }
}

public final class ClipExporter {
    public init() {}

    public func export(selection: SegmentSelection, to outputURL: URL) async throws -> URL {
        guard !selection.segments.isEmpty else {
            throw ClipExporterError.emptySelection
        }

        let composition = AVMutableComposition()
        guard let outputTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ClipExporterError.cannotCreateCompositionTrack
        }

        let requestedOutputDuration = CMTime(seconds: selection.requestedDuration, preferredTimescale: 600)
        var remainingOutputDuration = requestedOutputDuration
        var insertAt = CMTime.zero
        for (index, segment) in selection.segments.enumerated() {
            let asset = AVURLAsset(url: segment.url)
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .video).first else {
                throw ClipExporterError.missingVideoTrack(segment.url)
            }

            var sourceStart = CMTime.zero
            var sourceDuration = try await asset.load(.duration)
            if index == 0 {
                let trimSeconds = max(0, selection.requestedStartDate.timeIntervalSince(segment.startDate))
                sourceStart = CMTime(seconds: trimSeconds, preferredTimescale: 600)
                sourceDuration = max(.zero, sourceDuration - sourceStart)
            }

            let durationToInsert = min(sourceDuration, remainingOutputDuration)
            guard durationToInsert > .zero else {
                continue
            }

            try outputTrack.insertTimeRange(
                CMTimeRange(start: sourceStart, duration: durationToInsert),
                of: sourceTrack,
                at: insertAt
            )
            insertAt = insertAt + durationToInsert
            remainingOutputDuration = max(.zero, remainingOutputDuration - durationToInsert)

            if remainingOutputDuration <= .zero {
                break
            }
        }

        guard insertAt > .zero else {
            throw ClipExporterError.emptySelection
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ClipExporterError.cannotCreateExportSession
        }
        let exportSessionBox = ExportSessionBox(exportSession)

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov
        exportSession.shouldOptimizeForNetworkUse = true
        exportSession.timeRange = CMTimeRange(start: .zero, duration: insertAt)

        return try await withCheckedThrowingContinuation { continuation in
            exportSession.exportAsynchronously {
                switch exportSessionBox.session.status {
                case .completed:
                    continuation.resume(returning: outputURL)
                case .cancelled:
                    continuation.resume(throwing: ClipExporterError.exportCancelled)
                case .failed:
                    continuation.resume(throwing: exportSessionBox.session.error ?? ClipExporterError.exportFailed("Export failed."))
                default:
                    continuation.resume(throwing: ClipExporterError.exportFailed("Export ended with status \(exportSessionBox.session.status.rawValue)."))
                }
            }
        }
    }
}

private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}
