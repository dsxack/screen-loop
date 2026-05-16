import Foundation

public final class SegmentRingBuffer {
    private let retention: TimeInterval
    private let fileManager: FileManager
    private var segments: [RecordedSegment] = []

    public init(retention: TimeInterval, fileManager: FileManager = .default) {
        self.retention = retention
        self.fileManager = fileManager
    }

    public var allSegments: [RecordedSegment] {
        segments
    }

    public var mediaDuration: TimeInterval {
        Self.unionDuration(of: segments)
    }

    public static func unionDuration(of segments: [RecordedSegment]) -> TimeInterval {
        mergedIntervals(for: segments).reduce(0) { partialResult, interval in
            partialResult + interval.end.timeIntervalSince(interval.start)
        }
    }

    public func add(_ segment: RecordedSegment) {
        guard segment.duration > 0 else {
            removeFileIfPresent(at: segment.url)
            return
        }

        segments.append(segment)
        segments.sort { lhs, rhs in
            if lhs.startDate == rhs.startDate {
                return lhs.url.path < rhs.url.path
            }
            return lhs.startDate < rhs.startDate
        }
        trimExpiredSegments()
    }

    public func restore(_ recoveredSegments: [RecordedSegment]) {
        removeAll(deleteFiles: false)
        recoveredSegments.forEach(add)
    }

    public func removeAll(deleteFiles: Bool) {
        if deleteFiles {
            segments.forEach { removeFileIfPresent(at: $0.url) }
        }
        segments.removeAll()
    }

    public func selection(forLast duration: TimeInterval) -> SegmentSelection? {
        guard duration > 0, !segments.isEmpty else {
            return nil
        }

        let intervals = Self.mergedIntervals(for: segments)
        guard let lastInterval = intervals.last else {
            return nil
        }

        var remainingDuration = duration
        var requestedStartDate = intervals.first?.start ?? lastInterval.start

        for interval in intervals.reversed() {
            let intervalDuration = interval.end.timeIntervalSince(interval.start)
            if remainingDuration <= intervalDuration {
                requestedStartDate = interval.end.addingTimeInterval(-remainingDuration)
                break
            }

            remainingDuration -= intervalDuration
            requestedStartDate = interval.start
        }

        let selectedSegments = segments.filter { segment in
            segment.endDate > requestedStartDate && segment.startDate < lastInterval.end
        }
        guard !selectedSegments.isEmpty else {
            return nil
        }

        return SegmentSelection(
            segments: selectedSegments,
            requestedStartDate: requestedStartDate,
            endDate: lastInterval.end
        )
    }

    private func trimExpiredSegments() {
        var expired: [RecordedSegment] = []

        while let first = segments.first,
              Self.unionDuration(of: Array(segments.dropFirst())) >= retention {
            expired.append(first)
            segments.removeFirst()
        }

        expired.forEach { removeFileIfPresent(at: $0.url) }
    }

    private func removeFileIfPresent(at url: URL) {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try? fileManager.removeItem(at: url)
    }

    private static func mergedIntervals(for segments: [RecordedSegment]) -> [SegmentInterval] {
        let sortedSegments = segments
            .filter { $0.duration > 0 }
            .sorted { lhs, rhs in
                if lhs.startDate == rhs.startDate {
                    return lhs.url.path < rhs.url.path
                }
                return lhs.startDate < rhs.startDate
            }

        var intervals: [SegmentInterval] = []
        for segment in sortedSegments {
            guard let last = intervals.last else {
                intervals.append(SegmentInterval(start: segment.startDate, end: segment.endDate))
                continue
            }

            if segment.startDate <= last.end {
                intervals[intervals.count - 1] = SegmentInterval(
                    start: last.start,
                    end: max(last.end, segment.endDate)
                )
            } else {
                intervals.append(SegmentInterval(start: segment.startDate, end: segment.endDate))
            }
        }

        return intervals
    }

}

private struct SegmentInterval {
    let start: Date
    let end: Date
}
