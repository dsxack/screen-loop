import Foundation

enum RecordingMode: String, CaseIterable, Sendable {
    case mainDisplay
    case allDisplays
    case off

    private static let defaultsKey = "RecordingMode"

    var title: String {
        switch self {
        case .mainDisplay:
            return "Main Display"
        case .allDisplays:
            return "All Displays"
        case .off:
            return "Off"
        }
    }

    var menuTitle: String {
        switch self {
        case .mainDisplay:
            return "Record Main Display"
        case .allDisplays:
            return "Record All Displays"
        case .off:
            return "Recording Off"
        }
    }

    var isCaptureEnabled: Bool {
        self != .off
    }

    static func load(from defaults: UserDefaults = .standard) -> RecordingMode {
        guard let rawValue = defaults.string(forKey: defaultsKey),
              let mode = RecordingMode(rawValue: rawValue) else {
            return .mainDisplay
        }
        return mode
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}
