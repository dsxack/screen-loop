import Foundation

public enum AudioRecordingMode: String, CaseIterable, Sendable {
    case off
    case systemAudio

    private static let defaultsKey = "AudioRecordingMode"

    public var title: String {
        switch self {
        case .off:
            return "Off"
        case .systemAudio:
            return "System Audio"
        }
    }

    public var capturesSystemAudio: Bool {
        self == .systemAudio
    }

    public static func load(from defaults: UserDefaults = .standard) -> AudioRecordingMode {
        guard let rawValue = defaults.string(forKey: defaultsKey),
              let mode = AudioRecordingMode(rawValue: rawValue) else {
            return .off
        }
        return mode
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}
