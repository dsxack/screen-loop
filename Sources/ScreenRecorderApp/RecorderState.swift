import Foundation

enum RecorderState: Equatable {
    case stopped
    case permissionRequired
    case starting
    case recording
    case paused
    case exporting
    case saved(URL, TimeInterval)
    case failed(String)

    var menuStatus: String {
        switch self {
        case .stopped:
            return "Stopped"
        case .permissionRequired:
            return "Screen Recording Permission Required"
        case .starting:
            return "Starting Recording..."
        case .recording:
            return "Recording Main Display"
        case .paused:
            return "Recording Paused"
        case .exporting:
            return "Saving Clip..."
        case .saved(let url, let duration):
            return "Saved \(Self.formatDuration(duration)): \(url.lastPathComponent)"
        case .failed(let message):
            return "Error: \(message)"
        }
    }

    var statusItemTitle: String {
        switch self {
        case .recording:
            return "REC"
        case .exporting:
            return "SAVE"
        case .paused:
            return "PAUSE"
        case .saved:
            return "SAVED"
        case .failed:
            return "ERR"
        case .permissionRequired:
            return "PERM"
        case .starting:
            return "START"
        case .stopped:
            return "REC"
        }
    }

    var canSave: Bool {
        switch self {
        case .recording, .paused, .saved:
            return true
        default:
            return false
        }
    }

    var canToggleRecording: Bool {
        switch self {
        case .recording, .paused, .saved, .failed:
            return true
        default:
            return false
        }
    }

    var isRecordingActive: Bool {
        switch self {
        case .recording, .saved:
            return true
        default:
            return false
        }
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(1, Int(duration.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
