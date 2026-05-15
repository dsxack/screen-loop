import AppKit
import Foundation
import ScreenRecorderCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, @unchecked Sendable {
    private static let maxHistoryDisplay = "60:00"
    private static let informationalMenuItemHeight: CGFloat = 28
    private static let informationalMenuItemLeftInset: CGFloat = 22
    private static let informationalMenuItemRightInset: CGFloat = 16
    private static let informationalMenuItemMinimumWidth: CGFloat = 280

    private static var isOptionPressed: Bool {
        NSEvent.modifierFlags.contains(.option)
    }

    private let paths = RecordingPaths()
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var availableHistoryMenuItem: NSMenuItem!
    private var bufferSizeMenuItem: NSMenuItem!
    private var permissionMenuItem: NSMenuItem!
    private var relaunchMenuItem: NSMenuItem!
    private var recordingMenuItem: NSMenuItem!
    private var profileRootMenuItem: NSMenuItem!
    private var launchAtLoginMenuItem: NSMenuItem!
    private var openLoginItemsSettingsMenuItem: NSMenuItem!
    private var profileMenuItems: [NSMenuItem] = []
    private var saveMenuItems: [NSMenuItem] = []
    private var saveAndTrimMenuItems: [NSMenuItem] = []
    private var trimWindows: [TrimWindowController] = []
    private var recorder: ScreenRecorder!
    private var currentState: RecorderState = .stopped
    private var workspaceObservers: [NSObjectProtocol] = []
    private var availableHistoryTimer: Timer?
    private var savedStatusResetTask: Task<Void, Never>?
    private var savedStatusGeneration = 0
    private var permissionRelaunchPending = false
    private var isStatusMenuOpen = false
    private var menuModifierMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMenu()

        recorder = ScreenRecorder(paths: paths) { [weak self] state in
            self?.setState(state)
        }

        configureLaunchAtLoginDefault()
        installWorkspaceObservers()
        recorder.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if permissionRelaunchPending || (currentState == .permissionRequired && ScreenCapturePermission.isGranted) {
            AppRelauncher.scheduleRelaunch()
        }
        stopAvailableHistoryTimer()
        cancelSavedStatusReset()
        removeWorkspaceObservers()
        recorder.stop()
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = currentState.statusItemTitle
        statusItem.button?.toolTip = "Screen Recorder"

        let menu = NSMenu()

        statusMenuItem = Self.makeInformationalMenuItem(title: currentState.menuStatus)
        menu.addItem(statusMenuItem)

        availableHistoryMenuItem = Self.makeInformationalMenuItem(
            title: "Available History: 0:00 / \(Self.maxHistoryDisplay)"
        )
        menu.addItem(availableHistoryMenuItem)

        bufferSizeMenuItem = Self.makeInformationalMenuItem(title: "Buffer Size: 0 KB")
        menu.addItem(bufferSizeMenuItem)

        permissionMenuItem = NSMenuItem(
            title: "Grant Screen Recording Permission",
            action: #selector(requestPermission),
            keyEquivalent: ""
        )
        permissionMenuItem.target = self
        menu.addItem(permissionMenuItem)

        relaunchMenuItem = NSMenuItem(
            title: "Relaunch Screen Recorder",
            action: #selector(relaunchApp),
            keyEquivalent: ""
        )
        relaunchMenuItem.target = self
        menu.addItem(relaunchMenuItem)

        menu.addItem(.separator())

        recordingMenuItem = NSMenuItem(
            title: "Recording",
            action: #selector(toggleRecording),
            keyEquivalent: ""
        )
        recordingMenuItem.target = self
        menu.addItem(recordingMenuItem)

        let profileMenu = NSMenu()
        for profile in RecordingProfile.allCases {
            let item = NSMenuItem(
                title: profile.title,
                action: #selector(profileMenuItemClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = profile.rawValue
            profileMenuItems.append(item)
            profileMenu.addItem(item)
        }

        profileRootMenuItem = NSMenuItem(title: "Profile", action: nil, keyEquivalent: "")
        profileRootMenuItem.submenu = profileMenu
        menu.addItem(profileRootMenuItem)

        launchAtLoginMenuItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLoginMenuItem.target = self
        menu.addItem(launchAtLoginMenuItem)

        openLoginItemsSettingsMenuItem = NSMenuItem(
            title: "Open Login Items Settings",
            action: #selector(openLoginItemsSettings),
            keyEquivalent: ""
        )
        openLoginItemsSettingsMenuItem.target = self
        menu.addItem(openLoginItemsSettingsMenuItem)

        menu.addItem(.separator())

        let saveHeaderItem = NSMenuItem(title: "Save Last", action: nil, keyEquivalent: "")
        saveHeaderItem.isEnabled = false
        menu.addItem(saveHeaderItem)

        let saveAndTrimHeaderItem = NSMenuItem(title: "Save and Trim Last", action: nil, keyEquivalent: "")
        saveAndTrimHeaderItem.isEnabled = false
        saveAndTrimHeaderItem.isAlternate = true
        saveAndTrimHeaderItem.keyEquivalentModifierMask = [.option]
        menu.addItem(saveAndTrimHeaderItem)

        for minutes in [1, 3, 5, 15, 30, 45, 60] {
            let item = NSMenuItem(
                title: Self.durationMenuTitle(minutes: minutes),
                action: #selector(saveMenuItemClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = minutes
            item.isEnabled = false
            saveMenuItems.append(item)
            menu.addItem(item)

            let trimItem = NSMenuItem(
                title: Self.durationMenuTitle(minutes: minutes),
                action: #selector(saveMenuItemClicked(_:)),
                keyEquivalent: ""
            )
            trimItem.target = self
            trimItem.representedObject = minutes
            trimItem.tag = 1
            trimItem.isEnabled = false
            trimItem.isAlternate = true
            trimItem.keyEquivalentModifierMask = [.option]
            saveAndTrimMenuItems.append(trimItem)
            menu.addItem(trimItem)
        }

        menu.addItem(.separator())

        let openFolderItem = NSMenuItem(
            title: "Open Recordings Folder",
            action: #selector(openRecordingsFolder),
            keyEquivalent: ""
        )
        openFolderItem.target = self
        menu.addItem(openFolderItem)

        let openBufferFolderItem = NSMenuItem(
            title: "Open Buffer Folder",
            action: #selector(openBufferFolder),
            keyEquivalent: ""
        )
        openBufferFolderItem.target = self
        openBufferFolderItem.isAlternate = true
        openBufferFolderItem.keyEquivalentModifierMask = [.option]
        menu.addItem(openBufferFolderItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
        updateMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isStatusMenuOpen = true
        installMenuModifierMonitor()
        updateAdvancedMenuItems(optionPressed: Self.isOptionPressed)
        startAvailableHistoryTimer()
    }

    func menuDidClose(_ menu: NSMenu) {
        isStatusMenuOpen = false
        removeMenuModifierMonitor()
        updateAdvancedMenuItems(optionPressed: false)
        stopAvailableHistoryTimer()
    }

    private func setState(_ state: RecorderState) {
        currentState = state
        updateMenu()

        if case .saved = state {
            scheduleSavedStatusReset()
        } else {
            cancelSavedStatusReset()
        }
    }

    private func updateMenu() {
        statusItem?.button?.title = currentState.statusItemTitle
        Self.setInformationalTitle(currentState.menuStatus, for: statusMenuItem)
        permissionMenuItem?.isHidden = currentState != .permissionRequired
        relaunchMenuItem?.isHidden = currentState != .permissionRequired
        recordingMenuItem?.isEnabled = currentState.canToggleRecording
        recordingMenuItem?.state = recorder?.isCaptureActive == true ? .on : .off
        launchAtLoginMenuItem?.title = LaunchAtLoginController.statusTitle
        launchAtLoginMenuItem?.state = LaunchAtLoginController.isEnabled ? .on : .off
        updateAdvancedMenuItems(optionPressed: isStatusMenuOpen && Self.isOptionPressed)
        profileMenuItems.forEach { item in
            let rawValue = item.representedObject as? String
            item.state = rawValue == recorder?.currentProfile.rawValue ? .on : .off
            item.isEnabled = currentState != .starting && currentState != .exporting
        }
        saveMenuItems.forEach { $0.isEnabled = currentState.canSave }
        saveAndTrimMenuItems.forEach { $0.isEnabled = currentState.canSave }
    }

    private func updateAdvancedMenuItems(optionPressed: Bool) {
        availableHistoryMenuItem?.isHidden = !optionPressed
        bufferSizeMenuItem?.isHidden = !optionPressed
        profileRootMenuItem?.isHidden = !optionPressed
        launchAtLoginMenuItem?.isHidden = !optionPressed
        openLoginItemsSettingsMenuItem?.isHidden = !(optionPressed && LaunchAtLoginController.requiresApproval)

        if isStatusMenuOpen {
            statusItem?.menu?.update()
        }
    }

    private static func durationMenuTitle(minutes: Int) -> String {
        minutes == 1 ? "1 Minute" : "\(minutes) Minutes"
    }

    private static func makeInformationalMenuItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.view = makeInformationalMenuItemView(title: title)
        return item
    }

    private static func setInformationalTitle(_ title: String, for item: NSMenuItem?) {
        item?.title = title
        guard let view = item?.view,
              let label = view.subviews.first as? NSTextField else {
            return
        }

        label.stringValue = title
        resizeInformationalMenuItemView(view, title: title)
    }

    private static func makeInformationalMenuItemView(title: String) -> NSView {
        let view = NSView(frame: .zero)
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.menuFont(ofSize: 0)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        view.addSubview(label)
        resizeInformationalMenuItemView(view, title: title)
        return view
    }

    private static func resizeInformationalMenuItemView(_ view: NSView, title: String) {
        let font = NSFont.menuFont(ofSize: 0)
        let textWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        let width = max(
            informationalMenuItemMinimumWidth,
            textWidth + informationalMenuItemLeftInset + informationalMenuItemRightInset
        )

        view.frame = CGRect(x: 0, y: 0, width: width, height: informationalMenuItemHeight)
        guard let label = view.subviews.first as? NSTextField else {
            return
        }

        label.frame = CGRect(
            x: informationalMenuItemLeftInset,
            y: 4,
            width: width - informationalMenuItemLeftInset - informationalMenuItemRightInset,
            height: informationalMenuItemHeight - 8
        )
    }

    private func installMenuModifierMonitor() {
        removeMenuModifierMonitor()
        menuModifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.updateAdvancedMenuItems(optionPressed: event.modifierFlags.contains(.option))
            return event
        }
    }

    private func removeMenuModifierMonitor() {
        guard let menuModifierMonitor else {
            return
        }

        NSEvent.removeMonitor(menuModifierMonitor)
        self.menuModifierMonitor = nil
    }

    private func startAvailableHistoryTimer() {
        stopAvailableHistoryTimer()
        refreshAvailableHistory()

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshAvailableHistory()
        }
        timer.tolerance = 0.1
        availableHistoryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    private func stopAvailableHistoryTimer() {
        availableHistoryTimer?.invalidate()
        availableHistoryTimer = nil
    }

    private func refreshAvailableHistory() {
        guard let recorder else {
            Self.setInformationalTitle(
                "Available History: 0:00 / \(Self.maxHistoryDisplay)",
                for: availableHistoryMenuItem
            )
            Self.setInformationalTitle(
                "Buffer Size: \(Self.formatByteCount(bufferDirectorySize()))",
                for: bufferSizeMenuItem
            )
            return
        }

        let duration = recorder.availableMediaDurationSnapshot()
        Self.setInformationalTitle(
            "Available History: \(Self.formatDuration(duration)) / \(Self.maxHistoryDisplay)",
            for: availableHistoryMenuItem
        )
        Self.setInformationalTitle(
            "Buffer Size: \(Self.formatByteCount(bufferDirectorySize()))",
            for: bufferSizeMenuItem
        )
        statusItem.menu?.update()
    }

    private func scheduleSavedStatusReset() {
        savedStatusResetTask?.cancel()
        savedStatusGeneration += 1
        let generation = savedStatusGeneration

        savedStatusResetTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 2_500_000_000)
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.savedStatusGeneration == generation else {
                    return
                }
                guard case .saved = self.currentState else {
                    return
                }

                self.setState(self.recorder?.isCaptureActive == true ? .recording : .paused)
            }
        }
    }

    private func cancelSavedStatusReset() {
        savedStatusResetTask?.cancel()
        savedStatusResetTask = nil
        savedStatusGeneration += 1
    }

    @objc private func requestPermission() {
        permissionRelaunchPending = true
        if ScreenCapturePermission.request() {
            AppRelauncher.relaunch()
        } else {
            ScreenCapturePermission.openSettings()
            setState(.permissionRequired)
        }
    }

    @objc private func relaunchApp() {
        AppRelauncher.relaunch()
    }

    @objc private func saveMenuItemClicked(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int, currentState.canSave else {
            return
        }

        let shouldOpenTrimWindow = sender.tag == 1
        setState(.exporting)
        Task {
            do {
                let clip = try await recorder.saveLast(minutes: minutes)
                await MainActor.run {
                    setState(.saved(clip.url, clip.duration))
                    if shouldOpenTrimWindow {
                        openTrimWindow(for: clip.url)
                    }
                }
            } catch {
                await MainActor.run {
                    setState(.failed(error.localizedDescription))
                }
            }
        }
    }

    @MainActor
    private func openTrimWindow(for url: URL) {
        let controller = TrimWindowController(sourceURL: url)
        controller.onClose = { [weak self, weak controller] in
            guard let controller else {
                return
            }
            self?.trimWindows.removeAll { $0 === controller }
        }
        trimWindows.append(controller)
        controller.showWindowAndActivate()
    }

    @objc private func toggleRecording() {
        recorder.setRecordingEnabled(!recorder.isCaptureActive)
    }

    @objc private func profileMenuItemClicked(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let profile = RecordingProfile(rawValue: rawValue) else {
            return
        }

        recorder.setProfile(profile)
        updateMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LaunchAtLoginController.setEnabled(!LaunchAtLoginController.isEnabled)
            updateMenu()
        } catch {
            setState(.failed(error.localizedDescription))
        }
    }

    @objc private func openLoginItemsSettings() {
        LaunchAtLoginController.openSettings()
    }

    @objc private func openRecordingsFolder() {
        try? FileManager.default.createDirectory(at: paths.recordingsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(paths.recordingsDirectory)
    }

    @objc private func openBufferFolder() {
        try? FileManager.default.createDirectory(at: paths.bufferDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(paths.bufferDirectory)
    }

    private func bufferDirectorySize() -> Int64 {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: paths.bufferDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var totalSize: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize else {
                continue
            }

            totalSize += Int64(fileSize)
        }

        return totalSize
    }

    @objc private func quit() {
        permissionRelaunchPending = false
        stopAvailableHistoryTimer()
        cancelSavedStatusReset()
        recorder.stop()
        NSApp.terminate(nil)
    }

    private func configureLaunchAtLoginDefault() {
        do {
            try LaunchAtLoginController.applyInitialDefaultIfNeeded()
            updateMenu()
        } catch {
            setState(.failed(error.localizedDescription))
        }
    }

    private func installWorkspaceObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter

        workspaceObservers.append(notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recorder.handleSystemWillSleep()
        })

        workspaceObservers.append(notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recorder.handleSystemDidWake()
        })

        workspaceObservers.append(notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recorder.handleSystemDidWake()
        })

        workspaceObservers.append(notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recorder.handleSystemDidWake()
        })
    }

    private func removeWorkspaceObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private static func formatByteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
