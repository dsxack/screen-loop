import AppKit
@preconcurrency import AVFoundation
import AVKit
import ScreenRecorderCore

@MainActor
final class TrimWindowController: NSWindowController, NSWindowDelegate {
    private let sourceURL: URL
    private let trimmer = VideoTrimmer()
    private let minimumRange: TimeInterval = 0.5
    private let playbackBoundaryTolerance: TimeInterval = 0.05
    private let player = AVPlayer()
    private let playerView = AVPlayerView()
    private let rangeSlider = RangeSliderControl()
    private let startField = NSTextField(string: "0:00")
    private let endField = NSTextField(string: "0:00")
    private let statusLabel = NSTextField(labelWithString: "Loading clip...")
    private let replaceButton = NSButton(title: "Replace Original", target: nil, action: nil)
    private let createNewButton = NSButton(title: "Create New", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    private var duration: TimeInterval = 0
    private var startTime: TimeInterval = 0
    private var endTime: TimeInterval = 0
    private var isUpdatingControls = false
    private var isExporting = false
    private var isSeekingPlayer = false
    private var playerRateObservation: NSKeyValueObservation?
    private var playerTimeObserver: Any?

    var onClose: (() -> Void)?

    init(sourceURL: URL) {
        self.sourceURL = sourceURL

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Trim Clip"
        window.minSize = NSSize(width: 680, height: 500)

        super.init(window: window)
        window.delegate = self
        setupUI()
        installPlayerObservers()
        loadClip()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func showWindowAndActivate() {
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        player.pause()
        removePlayerObservers()
        onClose?()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else {
            return
        }

        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.translatesAutoresizingMaskIntoConstraints = false

        rangeSlider.target = self
        rangeSlider.action = #selector(rangeSliderChanged(_:))
        rangeSlider.minimumRange = minimumRange
        rangeSlider.translatesAutoresizingMaskIntoConstraints = false

        [startField, endField].forEach { field in
            field.alignment = .right
            field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            field.target = self
            field.action = #selector(timeFieldChanged(_:))
            field.widthAnchor.constraint(equalToConstant: 76).isActive = true
        }

        replaceButton.target = self
        replaceButton.action = #selector(replaceOriginalClicked)
        replaceButton.bezelStyle = .rounded
        createNewButton.target = self
        createNewButton.action = #selector(createNewClicked)
        createNewButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.bezelStyle = .rounded

        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.textColor = .secondaryLabelColor

        let startLabel = NSTextField(labelWithString: "Start")
        let endLabel = NSTextField(labelWithString: "End")
        let spacer = NSView()
        let grid = NSGridView(views: [
            [startLabel, rangeSlider, startField],
            [endLabel, spacer, endField]
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 1).xPlacement = .fill
        rangeSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let buttonStack = NSStackView(views: [cancelButton, replaceButton, createNewButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 10
        buttonStack.distribution = .gravityAreas
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        let controlsStack = NSStackView(views: [grid, statusLabel, buttonStack])
        controlsStack.orientation = .vertical
        controlsStack.alignment = .leading
        controlsStack.spacing = 14
        controlsStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(playerView)
        contentView.addSubview(controlsStack)

        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            playerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            playerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            playerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),

            controlsStack.topAnchor.constraint(equalTo: playerView.bottomAnchor, constant: 16),
            controlsStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            controlsStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            controlsStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),

            grid.widthAnchor.constraint(equalTo: controlsStack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: controlsStack.widthAnchor),
            buttonStack.widthAnchor.constraint(equalTo: controlsStack.widthAnchor)
        ])

        setControlsEnabled(false)
    }

    private func loadClip() {
        player.replaceCurrentItem(with: AVPlayerItem(url: sourceURL))

        Task {
            do {
                let asset = AVURLAsset(url: sourceURL)
                let loadedDuration = try await asset.load(.duration).seconds
                guard loadedDuration.isFinite, loadedDuration >= minimumRange else {
                    statusLabel.stringValue = "Clip is too short to trim."
                    return
                }

                duration = loadedDuration
                startTime = 0
                endTime = loadedDuration
                rangeSlider.minimumValue = 0
                rangeSlider.maximumValue = loadedDuration
                setControlsEnabled(true)
                updateControls(seekTo: .zero)
                statusLabel.stringValue = "Choose start and end, then save the trimmed clip."
            } catch {
                statusLabel.stringValue = "Could not load clip: \(error.localizedDescription)"
            }
        }
    }

    private func setControlsEnabled(_ enabled: Bool) {
        let enabled = enabled && !isExporting
        rangeSlider.isEnabled = enabled
        startField.isEnabled = enabled
        endField.isEnabled = enabled
        replaceButton.isEnabled = enabled
        createNewButton.isEnabled = enabled
    }

    @objc private func rangeSliderChanged(_ sender: RangeSliderControl) {
        guard !isUpdatingControls else {
            return
        }

        let previousStart = startTime
        let previousEnd = endTime
        startTime = sender.lowerValue
        endTime = sender.upperValue

        switch sender.activeHandle {
        case .lower:
            updateControls(seekTo: startTime)
        case .upper:
            updateControls(seekTo: endTime)
        case nil:
            let startDelta = abs(startTime - previousStart)
            let endDelta = abs(endTime - previousEnd)
            updateControls(seekTo: startDelta >= endDelta ? startTime : endTime)
        }
    }

    @objc private func timeFieldChanged(_ sender: NSTextField) {
        guard let parsedTime = Self.parseTime(sender.stringValue) else {
            updateControls()
            return
        }

        if sender === startField {
            startTime = min(max(0, parsedTime), max(0, endTime - minimumRange))
            updateControls(seekTo: startTime)
        } else {
            endTime = max(min(duration, parsedTime), min(duration, startTime + minimumRange))
            updateControls(seekTo: endTime)
        }
    }

    @objc private func createNewClicked() {
        performTrim(mode: .createNew)
    }

    @objc private func replaceOriginalClicked() {
        performTrim(mode: .replaceOriginal)
    }

    @objc private func cancelClicked() {
        close()
    }

    private func updateControls(seekTo time: TimeInterval? = nil) {
        isUpdatingControls = true
        rangeSlider.setRange(lower: startTime, upper: endTime)
        startField.stringValue = Self.formatTime(startTime)
        endField.stringValue = Self.formatTime(endTime)
        isUpdatingControls = false

        if let time {
            seekPlayer(to: time)
        } else {
            clampCurrentPreviewToSelectedRange()
        }
    }

    private func installPlayerObservers() {
        playerRateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.playerRateDidChange()
            }
        }

        playerTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.playerTimeDidChange(time.seconds)
            }
        }
    }

    private func removePlayerObservers() {
        playerRateObservation?.invalidate()
        playerRateObservation = nil

        if let playerTimeObserver {
            player.removeTimeObserver(playerTimeObserver)
            self.playerTimeObserver = nil
        }
    }

    private func playerRateDidChange() {
        guard player.rate > 0, !isSeekingPlayer else {
            return
        }

        let currentTime = player.currentTime().seconds
        guard currentTime.isFinite else {
            return
        }

        if currentTime < startTime - playbackBoundaryTolerance || currentTime >= endTime - playbackBoundaryTolerance {
            seekPlayer(to: startTime, resumePlayback: true)
        }
    }

    private func playerTimeDidChange(_ currentTime: TimeInterval) {
        guard player.rate > 0, !isSeekingPlayer, currentTime.isFinite else {
            return
        }

        if currentTime >= endTime - playbackBoundaryTolerance {
            player.pause()
            seekPlayer(to: endTime)
        } else if currentTime < startTime - playbackBoundaryTolerance {
            seekPlayer(to: startTime, resumePlayback: true)
        }
    }

    private func clampCurrentPreviewToSelectedRange() {
        let currentTime = player.currentTime().seconds
        guard currentTime.isFinite else {
            return
        }

        if currentTime < startTime - playbackBoundaryTolerance {
            seekPlayer(to: startTime, resumePlayback: player.rate > 0)
        } else if currentTime > endTime + playbackBoundaryTolerance {
            player.pause()
            seekPlayer(to: endTime)
        }
    }

    private func seekPlayer(to time: TimeInterval, resumePlayback: Bool = false) {
        let clampedTime = min(max(0, time), max(0, duration))
        isSeekingPlayer = true
        player.seek(
            to: CMTime(seconds: clampedTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isSeekingPlayer = false
                if resumePlayback {
                    self?.player.play()
                }
            }
        }
    }

    private func performTrim(mode: TrimOutputMode) {
        guard endTime - startTime >= minimumRange else {
            statusLabel.stringValue = "Choose at least 0.5 seconds."
            return
        }

        isExporting = true
        setControlsEnabled(false)
        statusLabel.stringValue = "Trimming..."

        Task {
            do {
                let result = try await trimmer.trim(
                    sourceURL: sourceURL,
                    startTime: startTime,
                    endTime: endTime,
                    mode: mode
                )

                if result.replacedOriginal {
                    player.replaceCurrentItem(with: AVPlayerItem(url: result.url))
                    duration = result.duration
                    startTime = 0
                    endTime = result.duration
                    rangeSlider.maximumValue = result.duration
                    updateControls(seekTo: .zero)
                    statusLabel.stringValue = "Replaced original: \(result.url.lastPathComponent)"
                } else {
                    statusLabel.stringValue = "Created: \(result.url.lastPathComponent)"
                }
            } catch {
                statusLabel.stringValue = "Trim failed: \(error.localizedDescription)"
            }

            isExporting = false
            setControlsEnabled(true)
        }
    }

    private static func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds = max(0, Int(time.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private static func parseTime(_ value: String) -> TimeInterval? {
        let parts = value.split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else {
            return nil
        }

        let numbers = parts.compactMap(Double.init)
        guard numbers.count == parts.count else {
            return nil
        }

        switch numbers.count {
        case 1:
            return numbers[0]
        case 2:
            return numbers[0] * 60 + numbers[1]
        case 3:
            return numbers[0] * 3600 + numbers[1] * 60 + numbers[2]
        default:
            return nil
        }
    }
}
