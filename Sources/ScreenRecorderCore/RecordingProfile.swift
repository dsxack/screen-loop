import Foundation

public enum RecordingProfile: String, CaseIterable, Sendable {
    case highQuality
    case lowPower

    public var title: String {
        switch self {
        case .highQuality:
            return "High Quality"
        case .lowPower:
            return "Low Power"
        }
    }

    public var maxHeight: Int {
        switch self {
        case .highQuality:
            return 1080
        case .lowPower:
            return 720
        }
    }

    public var frameRate: Int {
        switch self {
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
        case .highQuality:
            let scaled = Double(8_000_000) * (Double(pixels) / Double(referencePixels)) * (Double(frameRate) / 30.0)
            return max(2_500_000, Int(scaled))
        case .lowPower:
            let scaled = Double(2_000_000) * (Double(pixels) / Double(1280 * 720)) * (Double(frameRate) / 15.0)
            return max(1_200_000, Int(scaled))
        }
    }
}
