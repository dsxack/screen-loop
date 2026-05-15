import Foundation

public struct VideoGeometry: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public static func fitWithin1080p(sourceWidth: Int, sourceHeight: Int) -> VideoGeometry {
        fitWithin(sourceWidth: sourceWidth, sourceHeight: sourceHeight, maxLongEdge: 1920)
    }

    public static func fitWithin(sourceWidth: Int, sourceHeight: Int, maxLongEdge: Int) -> VideoGeometry {
        guard sourceWidth > 0, sourceHeight > 0 else {
            return VideoGeometry(width: max(2, maxLongEdge), height: max(2, maxLongEdge * 9 / 16))
        }

        let sourceLongEdge = max(sourceWidth, sourceHeight)
        let scale = min(1.0, Double(maxLongEdge) / Double(sourceLongEdge))
        return VideoGeometry(
            width: evenDimension(Int((Double(sourceWidth) * scale).rounded())),
            height: evenDimension(Int((Double(sourceHeight) * scale).rounded()))
        )
    }

    public static func fitWithin(sourceWidth: Int, sourceHeight: Int, maxHeight: Int) -> VideoGeometry {
        guard sourceWidth > 0, sourceHeight > 0 else {
            return VideoGeometry(width: max(2, maxHeight * 16 / 9), height: max(2, maxHeight))
        }

        let scale = min(1.0, Double(maxHeight) / Double(sourceHeight))
        return VideoGeometry(
            width: evenDimension(Int((Double(sourceWidth) * scale).rounded())),
            height: evenDimension(Int((Double(sourceHeight) * scale).rounded()))
        )
    }

    private static func evenDimension(_ value: Int) -> Int {
        max(2, value - (value % 2))
    }
}
