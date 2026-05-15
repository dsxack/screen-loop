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
        guard let first = segments.first else {
            return 0
        }

        let firstSegmentTrim = max(0, requestedStartDate.timeIntervalSince(first.startDate))
        return segments.enumerated().reduce(0) { partialResult, item in
            let (index, segment) = item
            if index == 0 {
                return partialResult + max(0, segment.duration - firstSegmentTrim)
            }
            return partialResult + segment.duration
        }
    }
}
