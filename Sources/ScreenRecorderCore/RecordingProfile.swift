import Foundation

public enum RecordingProfile: String, CaseIterable, Sendable {
    case readableText
    case highQuality
    case lowPower

    public static let defaultProfile: RecordingProfile = .readableText

    public var title: String {
        switch self {
        case .readableText:
            return "Readable Text"
        case .highQuality:
            return "High Quality"
        case .lowPower:
            return "Low Power"
        }
    }

    public var maxLongEdge: Int {
        switch self {
        case .readableText, .highQuality:
            return 1920
        case .lowPower:
            return 1280
        }
    }

    public var maxHeight: Int {
        maxLongEdge
    }

    public var frameRate: Int {
        switch self {
        case .readableText:
            return 15
        case .highQuality:
            return 30
        case .lowPower:
            return 15
        }
    }

    public func bitRate(for geometry: VideoGeometry) -> Int {
        let pixels = max(1, geometry.width * geometry.height)
        let referencePixels = 1920 * 1080

        switch self {
        case .readableText:
            let scaled = Double(5_000_000) * (Double(pixels) / Double(referencePixels)) * (Double(frameRate) / 15.0)
            return max(2_500_000, Int(scaled))
        case .highQuality:
            let scaled = Double(8_000_000) * (Double(pixels) / Double(referencePixels)) * (Double(frameRate) / 30.0)
            return max(2_500_000, Int(scaled))
        case .lowPower:
            let scaled = Double(2_000_000) * (Double(pixels) / Double(1280 * 720)) * (Double(frameRate) / 15.0)
            return max(1_200_000, Int(scaled))
        }
    }
}
