import AppKit
import Foundation

enum AppRelauncher {
    private static var didScheduleRelaunch = false

    static func relaunch() {
        scheduleRelaunch()
        NSApp.terminate(nil)
    }

    @discardableResult
    static func scheduleRelaunch() -> Bool {
        guard !didScheduleRelaunch else {
            return true
        }
        guard let appBundleURL else {
            return false
        }
        didScheduleRelaunch = true

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "sleep 0.8; exec /usr/bin/open \"$1\"",
            "relaunch",
            appBundleURL.path
        ]

        do {
            try process.run()
        } catch {
            NSWorkspace.shared.open(appBundleURL)
        }

        return true
    }

    private static var appBundleURL: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }
}
