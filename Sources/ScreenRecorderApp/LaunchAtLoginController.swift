import Foundation
import ServiceManagement

enum LaunchAtLoginController {
    private static let preferenceInitializedKey = "LaunchAtLoginPreferenceInitialized"
    private static let preferenceEnabledKey = "LaunchAtLoginPreferenceEnabled"

    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static var isEnabled: Bool {
        status == .enabled
    }

    static var requiresApproval: Bool {
        status == .requiresApproval
    }

    static var statusTitle: String {
        switch status {
        case .enabled:
            return "Launch at Login: On"
        case .notRegistered:
            return "Launch at Login: Off"
        case .requiresApproval:
            return "Launch at Login: Needs Approval"
        case .notFound:
            return "Launch at Login: App Not Found"
        @unknown default:
            return "Launch at Login: Unknown"
        }
    }

    static func applyInitialDefaultIfNeeded() throws {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: preferenceInitializedKey) else {
            if defaults.bool(forKey: preferenceEnabledKey), status == .notRegistered {
                try setEnabled(true)
            }
            return
        }

        defaults.set(true, forKey: preferenceInitializedKey)
        try setEnabled(true)
    }

    static func setEnabled(_ enabled: Bool) throws {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: preferenceInitializedKey)
        defaults.set(enabled, forKey: preferenceEnabledKey)

        if enabled {
            switch status {
            case .enabled:
                return
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
                return
            case .notRegistered, .notFound:
                try SMAppService.mainApp.register()
            @unknown default:
                try SMAppService.mainApp.register()
            }
        } else {
            switch status {
            case .notRegistered:
                return
            case .enabled, .requiresApproval, .notFound:
                try SMAppService.mainApp.unregister()
            @unknown default:
                try SMAppService.mainApp.unregister()
            }
        }
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
