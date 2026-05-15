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
        segments.reduce(0) { partialResult, segment in
            partialResult + segment.duration
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

        var selected: [RecordedSegment] = []
        var remainingDuration = duration

        for segment in segments.reversed() {
            selected.append(segment)

            if remainingDuration <= segment.duration {
                let trimFromSegmentStart = max(0, segment.duration - remainingDuration)
                let startDate = segment.startDate.addingTimeInterval(trimFromSegmentStart)
                let orderedSelection = Array(selected.reversed())

                return SegmentSelection(
                    segments: orderedSelection,
                    requestedStartDate: startDate,
                    endDate: orderedSelection.last?.endDate ?? segment.endDate
                )
            }

            remainingDuration -= segment.duration
        }

        let orderedSelection = Array(selected.reversed())
        guard let first = orderedSelection.first, let last = orderedSelection.last else {
            return nil
        }
        return SegmentSelection(
            segments: orderedSelection,
            requestedStartDate: first.startDate,
            endDate: last.endDate
        )
    }

    private func trimExpiredSegments() {
        var currentMediaDuration = mediaDuration
        var expired: [RecordedSegment] = []

        while let first = segments.first, currentMediaDuration - first.duration >= retention {
            currentMediaDuration -= first.duration
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

}
