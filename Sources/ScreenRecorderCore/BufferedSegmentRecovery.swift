@preconcurrency import AVFoundation
import Foundation

public enum BufferedSegmentRecovery {
    public static func recover(
        in directory: URL,
        retention: TimeInterval,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) async throws -> [RecordedSegment] {
        _ = now
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var recovered: [RecordedSegment] = []

        for url in urls where url.pathExtension.lowercased() == "mov" {
            guard let segment = await recoverSegment(from: url) else {
                removeFileIfPresent(at: url, fileManager: fileManager)
                continue
            }

            recovered.append(segment)
        }

        let ringBuffer = SegmentRingBuffer(retention: retention, fileManager: fileManager)
        recovered.sorted { lhs, rhs in
            if lhs.startDate == rhs.startDate {
                return lhs.url.path < rhs.url.path
            }
            return lhs.startDate < rhs.startDate
        }.forEach { ringBuffer.add($0) }

        return ringBuffer.allSegments
    }

    private static func recoverSegment(from url: URL) async -> RecordedSegment? {
        guard let startDate = RecordingPaths.segmentStartDate(from: url) else {
            return nil
        }

        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else {
            return nil
        }

        let durationSeconds = duration.seconds
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            return nil
        }

        return RecordedSegment(
            url: url,
            startDate: startDate,
            endDate: startDate.addingTimeInterval(durationSeconds)
        )
    }

    private static func removeFileIfPresent(at url: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try? fileManager.removeItem(at: url)
    }
}
