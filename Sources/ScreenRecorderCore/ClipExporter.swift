@preconcurrency import AVFoundation
import Foundation

public enum ClipExporterError: LocalizedError {
    case emptySelection
    case missingVideoTrack(URL)
    case cannotCreateCompositionTrack
    case cannotCreateAudioCompositionTrack
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
        case .cannotCreateAudioCompositionTrack:
            return "Could not create the output audio track."
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
    private static let outputTimescale: CMTimeScale = 600
    private static let audioCrossfadeHalfDuration: TimeInterval = 0.04

    public init() {}

    public func export(selection: SegmentSelection, to outputURL: URL) async throws -> URL {
        let plannedRanges = Self.plannedRanges(for: selection)
        guard !plannedRanges.isEmpty else {
            throw ClipExporterError.emptySelection
        }

        let composition = AVMutableComposition()
        guard let outputTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ClipExporterError.cannotCreateCompositionTrack
        }

        var audioOutputTracks: [AVMutableCompositionTrack] = []
        var audioMixParameters: [AVMutableAudioMixInputParameters] = []
        var insertAt = CMTime.zero
        var hasVideoTransform = false

        for (rangeIndex, plannedRange) in plannedRanges.enumerated() {
            let segment = plannedRange.segment
            let asset = AVURLAsset(url: segment.url)
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .video).first else {
                throw ClipExporterError.missingVideoTrack(segment.url)
            }

            if !hasVideoTransform {
                outputTrack.preferredTransform = try await sourceTrack.load(.preferredTransform)
                hasVideoTransform = true
            }

            let sourceStart = CMTime(
                seconds: plannedRange.startDate.timeIntervalSince(segment.startDate),
                preferredTimescale: Self.outputTimescale
            )
            let requestedDuration = CMTime(
                seconds: plannedRange.endDate.timeIntervalSince(plannedRange.startDate),
                preferredTimescale: Self.outputTimescale
            )
            let assetDuration = try await asset.load(.duration)
            let sourceDuration = min(requestedDuration, max(.zero, assetDuration - sourceStart))
            guard sourceDuration > .zero else {
                continue
            }

            let sourceRange = CMTimeRange(start: sourceStart, duration: sourceDuration)
            try outputTrack.insertTimeRange(sourceRange, of: sourceTrack, at: insertAt)

            if let sourceAudioTrack = try await asset.loadTracks(withMediaType: .audio).first,
               let audioInsertion = try await Self.audioInsertion(
                   sourceRange: sourceRange,
                   outputStart: insertAt,
                   sourceAudioTrack: sourceAudioTrack,
                   headExtension: plannedRange.audioHeadExtension,
                   tailExtension: plannedRange.audioTailExtension
               ) {
                let trackIndex = rangeIndex % 2
                try Self.prepareAudioTracks(
                    audioOutputTracks: &audioOutputTracks,
                    audioMixParameters: &audioMixParameters,
                    upTo: trackIndex,
                    in: composition
                )
                let track = audioOutputTracks[trackIndex]

                try track.insertTimeRange(
                    audioInsertion.range,
                    of: sourceAudioTrack,
                    at: audioInsertion.outputStart
                )

                Self.applyAudioMix(
                    parameters: audioMixParameters[trackIndex],
                    insertion: audioInsertion,
                    videoOutputStart: insertAt,
                    videoOutputEnd: insertAt + sourceDuration,
                    headExtension: plannedRange.audioHeadExtension,
                    tailExtension: plannedRange.audioTailExtension
                )
            }

            insertAt = insertAt + sourceDuration
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
        if !audioMixParameters.isEmpty {
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = audioMixParameters
            exportSession.audioMix = audioMix
        }

        do {
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
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private static func plannedRanges(for selection: SegmentSelection) -> [PlannedSegmentRange] {
        let segments = selection.segments.sorted { lhs, rhs in
            if lhs.startDate == rhs.startDate {
                return lhs.url.path < rhs.url.path
            }
            return lhs.startDate < rhs.startDate
        }

        return segments.indices.compactMap { index in
            let segment = segments[index]
            var startDate = later(segment.startDate, selection.requestedStartDate)
            var endDate = earlier(segment.endDate, selection.endDate)
            var audioHeadExtension: TimeInterval = 0
            var audioTailExtension: TimeInterval = 0

            if index > segments.startIndex,
               let overlap = overlapInfo(between: segments[index - 1], and: segment) {
                startDate = later(startDate, overlap.cutDate)
                if startDate == overlap.cutDate {
                    audioHeadExtension = min(Self.audioCrossfadeHalfDuration, overlap.duration / 2.0)
                }
            }

            let nextIndex = segments.index(after: index)
            if nextIndex < segments.endIndex,
               let overlap = overlapInfo(between: segment, and: segments[nextIndex]) {
                endDate = earlier(endDate, overlap.cutDate)
                if endDate == overlap.cutDate {
                    audioTailExtension = min(Self.audioCrossfadeHalfDuration, overlap.duration / 2.0)
                }
            }

            guard endDate > startDate else {
                return nil
            }

            return PlannedSegmentRange(
                segment: segment,
                startDate: startDate,
                endDate: endDate,
                audioHeadExtension: audioHeadExtension,
                audioTailExtension: audioTailExtension
            )
        }
    }

    private static func overlapInfo(between lhs: RecordedSegment, and rhs: RecordedSegment) -> (cutDate: Date, duration: TimeInterval)? {
        let overlapStart = later(lhs.startDate, rhs.startDate)
        let overlapEnd = earlier(lhs.endDate, rhs.endDate)
        guard overlapEnd > overlapStart else {
            return nil
        }

        let duration = overlapEnd.timeIntervalSince(overlapStart)
        return (
            cutDate: overlapStart.addingTimeInterval(duration / 2.0),
            duration: duration
        )
    }

    private static func audioInsertion(
        sourceRange: CMTimeRange,
        outputStart: CMTime,
        sourceAudioTrack: AVAssetTrack,
        headExtension: TimeInterval,
        tailExtension: TimeInterval
    ) async throws -> AudioInsertion? {
        let audioRange = try await sourceAudioTrack.load(.timeRange)
        let head = CMTime(seconds: headExtension, preferredTimescale: Self.outputTimescale)
        let tail = CMTime(seconds: tailExtension, preferredTimescale: Self.outputTimescale)
        let desiredSourceStart = sourceRange.start - head
        let desiredSourceEnd = sourceRange.start + sourceRange.duration + tail
        let desiredOutputStart = outputStart - head
        let audioEnd = audioRange.start + audioRange.duration
        var start = max(desiredSourceStart, audioRange.start)
        let end = min(desiredSourceEnd, audioEnd)
        var actualOutputStart = desiredOutputStart + (start - desiredSourceStart)

        if actualOutputStart < .zero {
            let trim = .zero - actualOutputStart
            start = start + trim
            actualOutputStart = .zero
        }

        guard end > start else {
            return nil
        }

        return AudioInsertion(
            range: CMTimeRange(start: start, duration: end - start),
            outputStart: actualOutputStart
        )
    }

    private static func prepareAudioTracks(
        audioOutputTracks: inout [AVMutableCompositionTrack],
        audioMixParameters: inout [AVMutableAudioMixInputParameters],
        upTo trackIndex: Int,
        in composition: AVMutableComposition
    ) throws {
        while audioOutputTracks.count <= trackIndex {
            guard let track = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw ClipExporterError.cannotCreateAudioCompositionTrack
            }

            audioOutputTracks.append(track)
            audioMixParameters.append(AVMutableAudioMixInputParameters(track: track))
        }
    }

    private static func applyAudioMix(
        parameters: AVMutableAudioMixInputParameters,
        insertion: AudioInsertion,
        videoOutputStart: CMTime,
        videoOutputEnd: CMTime,
        headExtension: TimeInterval,
        tailExtension: TimeInterval
    ) {
        let insertionRange = CMTimeRange(start: insertion.outputStart, duration: insertion.range.duration)
        let head = CMTime(seconds: headExtension, preferredTimescale: Self.outputTimescale)
        let tail = CMTime(seconds: tailExtension, preferredTimescale: Self.outputTimescale)

        if head > .zero {
            let fadeRange = CMTimeRange(start: videoOutputStart - head, duration: head + head)
            applyVolumeRamp(
                parameters: parameters,
                fadeRange: fadeRange,
                insertionRange: insertionRange,
                startVolume: 0,
                endVolume: 1
            )
        } else {
            parameters.setVolume(1, at: insertion.outputStart)
        }

        if tail > .zero {
            let fadeRange = CMTimeRange(start: videoOutputEnd - tail, duration: tail + tail)
            applyVolumeRamp(
                parameters: parameters,
                fadeRange: fadeRange,
                insertionRange: insertionRange,
                startVolume: 1,
                endVolume: 0
            )
        }
    }

    private static func applyVolumeRamp(
        parameters: AVMutableAudioMixInputParameters,
        fadeRange: CMTimeRange,
        insertionRange: CMTimeRange,
        startVolume: Float,
        endVolume: Float
    ) {
        guard let clippedRange = intersection(fadeRange, insertionRange) else {
            return
        }

        let clippedEnd = clippedRange.start + clippedRange.duration
        let startProgress = progress(at: clippedRange.start, in: fadeRange)
        let endProgress = progress(at: clippedEnd, in: fadeRange)
        let clippedStartVolume = startVolume + ((endVolume - startVolume) * startProgress)
        let clippedEndVolume = startVolume + ((endVolume - startVolume) * endProgress)

        parameters.setVolume(clippedStartVolume, at: clippedRange.start)
        parameters.setVolumeRamp(
            fromStartVolume: clippedStartVolume,
            toEndVolume: clippedEndVolume,
            timeRange: clippedRange
        )
        parameters.setVolume(clippedEndVolume, at: clippedEnd)
    }

    private static func intersection(_ lhs: CMTimeRange, _ rhs: CMTimeRange) -> CMTimeRange? {
        let start = max(lhs.start, rhs.start)
        let end = min(lhs.start + lhs.duration, rhs.start + rhs.duration)
        guard end > start else {
            return nil
        }
        return CMTimeRange(start: start, duration: end - start)
    }

    private static func progress(at time: CMTime, in range: CMTimeRange) -> Float {
        guard range.duration > .zero else {
            return 1
        }

        let progress = CMTimeGetSeconds(time - range.start) / CMTimeGetSeconds(range.duration)
        return Float(min(1, max(0, progress)))
    }

    private static func later(_ lhs: Date, _ rhs: Date) -> Date {
        lhs >= rhs ? lhs : rhs
    }

    private static func earlier(_ lhs: Date, _ rhs: Date) -> Date {
        lhs <= rhs ? lhs : rhs
    }
}

private struct PlannedSegmentRange {
    let segment: RecordedSegment
    let startDate: Date
    let endDate: Date
    let audioHeadExtension: TimeInterval
    let audioTailExtension: TimeInterval
}

private struct AudioInsertion {
    let range: CMTimeRange
    let outputStart: CMTime
}

private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}
