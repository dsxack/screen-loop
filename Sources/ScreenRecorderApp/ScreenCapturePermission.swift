import AppKit
import CoreGraphics
import Foundation

enum ScreenCapturePermission {
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        ]

        for value in urls {
            guard let url = URL(string: value) else {
                continue
            }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
