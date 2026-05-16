import Foundation

public struct RecordedSegment: Equatable, Sendable {
    public let url: URL
    public let startDate: Date
    public let endDate: Date

    public init(url: URL, startDate: Date, endDate: Date) {
        self.url = url
        self.startDate = startDate
        self.endDate = endDate
    }

    public var duration: TimeInterval {
        max(0, endDate.timeIntervalSince(startDate))
    }
}

public struct SegmentSelection: Equatable, Sendable {
    public let segments: [RecordedSegment]
    public let requestedStartDate: Date
    public let endDate: Date

    public init(segments: [RecordedSegment], requestedStartDate: Date, endDate: Date) {
        self.segments = segments
        self.requestedStartDate = requestedStartDate
        self.endDate = endDate
    }

    public var requestedDuration: TimeInterval {
        let clippedSegments = segments.compactMap { segment -> RecordedSegment? in
            let startDate = max(segment.startDate, requestedStartDate)
            let endDate = min(segment.endDate, self.endDate)
            guard endDate > startDate else {
                return nil
            }
            return RecordedSegment(url: segment.url, startDate: startDate, endDate: endDate)
        }
        return SegmentRingBuffer.unionDuration(of: clippedSegments)
    }
}
