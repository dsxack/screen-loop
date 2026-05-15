import AppKit
@preconcurrency import AVFoundation
import AVKit
import ScreenRecorderCore

struct TrimWindowSource: Equatable {
    let title: String
    let url: URL
}

@MainActor
final class TrimWindowController: NSWindowController, NSWindowDelegate {
    private let sources: [TrimWindowSource]
    private var selectedSourceIndex: Int
    private var sourceURL: URL {
        sources[selectedSourceIndex].url
    }
    private var sourceTitle: String {
        sources[selectedSourceIndex].title
    }
    private let trimmer = VideoTrimmer()
    private let minimumRange: TimeInterval = 0.5
    private let playbackBoundaryTolerance: TimeInterval = 0.05
    private var sourceAsset: AVURLAsset
    private let player = AVPlayer()
    private let playerView = AVPlayerView()
    private let previewContainer = NSView()
    private let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
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
    private var loadGeneration = 0
    private var previewGeneration = 0
    private var previewRefreshTask: Task<Void, Never>?
    private var playerRateObservation: NSKeyValueObservation?
    private var playerTimeObserver: Any?
    private var playerViewWidthConstraint: NSLayoutConstraint?
    private var playerViewHeightConstraint: NSLayoutConstraint?
    private var previewContainerHeightConstraint: NSLayoutConstraint?
    private weak var controlsStack: NSStackView?
    private weak var sourceStack: NSStackView?

    var onClose: (() -> Void)?

    convenience init(sourceURL: URL) {
        self.init(sources: [TrimWindowSource(title: sourceURL.lastPathComponent, url: sourceURL)])
    }

    init(sources: [TrimWindowSource], selectedIndex: Int = 0) {
        precondition(!sources.isEmpty, "TrimWindowController requires at least one source.")
        self.sources = sources
        self.selectedSourceIndex = min(max(0, selectedIndex), sources.count - 1)
        self.sourceAsset = AVURLAsset(url: sources[self.selectedSourceIndex].url)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Trim Clip"
        window.minSize = NSSize(width: 560, height: 500)

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
        previewRefreshTask?.cancel()
        removePlayerObservers()
        onClose?()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else {
            return
        }

        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.videoGravity = .resizeAspect
        playerView.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.translatesAutoresizingMaskIntoConstraints = false

        sourcePopup.target = self
        sourcePopup.action = #selector(sourcePopupChanged(_:))
        sourcePopup.translatesAutoresizingMaskIntoConstraints = false
        for (index, source) in sources.enumerated() {
            sourcePopup.addItem(withTitle: source.title)
            sourcePopup.item(at: index)?.representedObject = index
        }
        sourcePopup.selectItem(at: selectedSourceIndex)

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

        let sourceLabel = NSTextField(labelWithString: "Display")
        let sourceSpacer = NSView()
        let sourceStack = NSStackView(views: [sourceLabel, sourcePopup, sourceSpacer])
        self.sourceStack = sourceStack
        sourceStack.orientation = .horizontal
        sourceStack.alignment = .centerY
        sourceStack.spacing = 8
        sourceStack.translatesAutoresizingMaskIntoConstraints = false
        sourceSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sourcePopup.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let startLabel = NSTextField(labelWithString: "Start")
        let endLabel = NSTextField(labelWithString: "End")

        let startGroup = NSStackView(views: [startLabel, startField])
        startGroup.orientation = .horizontal
        startGroup.alignment = .centerY
        startGroup.spacing = 8

        let endGroup = NSStackView(views: [endLabel, endField])
        endGroup.orientation = .horizontal
        endGroup.alignment = .centerY
        endGroup.spacing = 8

        let headerSpacer = NSView()
        let rangeHeader = NSStackView(views: [startGroup, headerSpacer, endGroup])
        rangeHeader.orientation = .horizontal
        rangeHeader.alignment = .centerY
        rangeHeader.spacing = 12
        rangeHeader.translatesAutoresizingMaskIntoConstraints = false

        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        startGroup.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        endGroup.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        rangeSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let rangeStack = NSStackView(views: [rangeHeader, rangeSlider])
        rangeStack.orientation = .vertical
        rangeStack.alignment = .leading
        rangeStack.spacing = 8
        rangeStack.translatesAutoresizingMaskIntoConstraints = false

        let buttonStack = NSStackView(views: [cancelButton, replaceButton, createNewButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 10
        buttonStack.distribution = .gravityAreas
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        let controlsStack = NSStackView(views: [rangeStack, statusLabel, buttonStack])
        self.controlsStack = controlsStack
        controlsStack.orientation = .vertical
        controlsStack.alignment = .leading
        controlsStack.spacing = 14
        controlsStack.translatesAutoresizingMaskIntoConstraints = false

        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 16
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        if sources.count > 1 {
            contentStack.addArrangedSubview(sourceStack)
        }
        previewContainer.addSubview(playerView)
        contentStack.addArrangedSubview(previewContainer)
        contentStack.addArrangedSubview(controlsStack)

        contentView.addSubview(contentStack)

        let playerViewWidthConstraint = playerView.widthAnchor.constraint(equalToConstant: 788)
        let playerViewHeightConstraint = playerView.heightAnchor.constraint(equalToConstant: 320)
        let previewContainerHeightConstraint = previewContainer.heightAnchor.constraint(equalToConstant: 320)
        self.playerViewWidthConstraint = playerViewWidthConstraint
        self.playerViewHeightConstraint = playerViewHeightConstraint
        self.previewContainerHeightConstraint = previewContainerHeightConstraint

        var constraints = [
            contentStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            contentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            contentStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),

            previewContainer.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            previewContainerHeightConstraint,
            playerView.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            playerView.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
            playerViewWidthConstraint,
            playerViewHeightConstraint,

            controlsStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            rangeStack.widthAnchor.constraint(equalTo: controlsStack.widthAnchor),
            rangeHeader.widthAnchor.constraint(equalTo: rangeStack.widthAnchor),
            rangeSlider.widthAnchor.constraint(equalTo: rangeStack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: controlsStack.widthAnchor),
            buttonStack.widthAnchor.constraint(equalTo: controlsStack.widthAnchor)
        ]
        if sources.count > 1 {
            constraints.append(sourceStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor))
            constraints.append(sourcePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 220))
        }
        NSLayoutConstraint.activate(constraints)

        setControlsEnabled(false)
    }

    private func loadClip() {
        loadGeneration += 1
        let generation = loadGeneration
        let asset = sourceAsset
        player.pause()
        player.replaceCurrentItem(with: nil)
        previewRefreshTask?.cancel()
        duration = 0
        startTime = 0
        endTime = 0
        rangeSlider.minimumValue = 0
        rangeSlider.maximumValue = 0
        startField.stringValue = "0:00"
        endField.stringValue = "0:00"
        setControlsEnabled(false)
        statusLabel.stringValue = "Loading \(sourceTitle)..."

        Task {
            do {
                let loadedDuration = try await asset.load(.duration).seconds
                let presentationSize = try await Self.presentationSize(for: asset)
                guard generation == loadGeneration else {
                    return
                }
                guard loadedDuration.isFinite, loadedDuration >= minimumRange else {
                    statusLabel.stringValue = "Clip is too short to trim."
                    return
                }

                applyWindowLayout(for: presentationSize)
                duration = loadedDuration
                startTime = 0
                endTime = loadedDuration
                rangeSlider.minimumValue = 0
                rangeSlider.maximumValue = loadedDuration
                setControlsEnabled(true)
                updateControls(seekToSourceTime: .zero)
                statusLabel.stringValue = "Choose start and end, then save the trimmed clip."
            } catch {
                guard generation == loadGeneration else {
                    return
                }
                statusLabel.stringValue = "Could not load clip: \(error.localizedDescription)"
            }
        }
    }

    private func applyWindowLayout(for presentationSize: CGSize) {
        guard presentationSize.width > 0, presentationSize.height > 0,
              let window else {
            return
        }

        let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let aspectRatio = max(0.1, min(10, presentationSize.width / presentationSize.height))
        let controlsHeight = max(112, controlsStack?.fittingSize.height ?? 112)
        let sourceHeight = sources.count > 1 ? max(26, sourceStack?.fittingSize.height ?? 26) : 0
        let outerMargin: CGFloat = 32
        let stackSpacing: CGFloat = 16
        let sourceBlockHeight = sources.count > 1 ? sourceHeight + stackSpacing : 0
        let controlsBlockHeight = stackSpacing + controlsHeight
        let minStackWidth: CGFloat = sources.count > 1 ? 520 : 500
        let maxStackWidth = max(minStackWidth, min(1050, visibleFrame.width - 112))
        let maxContentHeight = max(500, visibleFrame.height - 120)
        let maxPreviewHeight = max(260, maxContentHeight - outerMargin - sourceBlockHeight - controlsBlockHeight)

        let previewSize: CGSize
        let stackWidth: CGFloat
        if aspectRatio < 1 {
            var previewHeight = min(maxPreviewHeight, max(560, maxPreviewHeight))
            var previewWidth = previewHeight * aspectRatio
            stackWidth = min(maxStackWidth, max(minStackWidth, previewWidth))
            if previewWidth > stackWidth {
                previewWidth = stackWidth
                previewHeight = previewWidth / aspectRatio
            }
            previewSize = CGSize(width: previewWidth, height: previewHeight)
        } else {
            var previewWidth = min(maxStackWidth, max(788, minStackWidth))
            var previewHeight = previewWidth / aspectRatio
            if previewHeight > maxPreviewHeight {
                previewHeight = maxPreviewHeight
                previewWidth = previewHeight * aspectRatio
            }
            stackWidth = min(maxStackWidth, max(minStackWidth, previewWidth))
            previewSize = CGSize(width: previewWidth, height: previewHeight)
        }

        playerViewWidthConstraint?.constant = previewSize.width
        playerViewHeightConstraint?.constant = previewSize.height
        previewContainerHeightConstraint?.constant = previewSize.height

        let contentSize = NSSize(
            width: stackWidth + outerMargin,
            height: outerMargin + sourceBlockHeight + previewSize.height + controlsBlockHeight
        )
        resizeWindow(window, toContentSize: contentSize, within: visibleFrame)
    }

    private func resizeWindow(_ window: NSWindow, toContentSize contentSize: NSSize, within visibleFrame: NSRect) {
        let oldFrame = window.frame
        let center = NSPoint(x: oldFrame.midX, y: oldFrame.midY)
        window.setContentSize(contentSize)

        var frame = window.frame
        frame.origin.x = center.x - frame.width / 2
        frame.origin.y = center.y - frame.height / 2

        if frame.minX < visibleFrame.minX {
            frame.origin.x = visibleFrame.minX
        }
        if frame.maxX > visibleFrame.maxX {
            frame.origin.x = visibleFrame.maxX - frame.width
        }
        if frame.minY < visibleFrame.minY {
            frame.origin.y = visibleFrame.minY
        }
        if frame.maxY > visibleFrame.maxY {
            frame.origin.y = visibleFrame.maxY - frame.height
        }

        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    private func setControlsEnabled(_ enabled: Bool) {
        let enabled = enabled && !isExporting
        rangeSlider.isEnabled = enabled
        startField.isEnabled = enabled
        endField.isEnabled = enabled
        replaceButton.isEnabled = enabled
        createNewButton.isEnabled = enabled
        sourcePopup.isEnabled = sources.count > 1 && enabled
    }

    @objc private func sourcePopupChanged(_ sender: NSPopUpButton) {
        guard !isExporting else {
            sender.selectItem(at: selectedSourceIndex)
            return
        }

        let selectedIndex = sender.selectedItem?.representedObject as? Int ?? sender.indexOfSelectedItem
        guard sources.indices.contains(selectedIndex), selectedIndex != selectedSourceIndex else {
            return
        }

        selectedSourceIndex = selectedIndex
        sourceAsset = AVURLAsset(url: sourceURL)
        loadClip()
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
            updateControls(seekToSourceTime: startTime)
        case .upper:
            updateControls(seekToSourceTime: endTime)
        case nil:
            let startDelta = abs(startTime - previousStart)
            let endDelta = abs(endTime - previousEnd)
            updateControls(seekToSourceTime: startDelta >= endDelta ? startTime : endTime)
        }
    }

    @objc private func timeFieldChanged(_ sender: NSTextField) {
        guard let parsedTime = Self.parseTime(sender.stringValue) else {
            updateControls()
            return
        }

        if sender === startField {
            startTime = min(max(0, parsedTime), max(0, endTime - minimumRange))
            updateControls(seekToSourceTime: startTime)
        } else {
            endTime = max(min(duration, parsedTime), min(duration, startTime + minimumRange))
            updateControls(seekToSourceTime: endTime)
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

    private func updateControls(seekToSourceTime time: TimeInterval? = nil) {
        isUpdatingControls = true
        rangeSlider.setRange(lower: startTime, upper: endTime)
        startField.stringValue = Self.formatTime(startTime)
        endField.stringValue = Self.formatTime(endTime)
        isUpdatingControls = false

        schedulePreviewRefresh(seekToSourceTime: time)
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

        if currentTime >= previewDuration - playbackBoundaryTolerance {
            seekPlayer(toPreviewTime: .zero, resumePlayback: true)
        }
    }

    private func playerTimeDidChange(_ currentTime: TimeInterval) {
        guard player.rate > 0, !isSeekingPlayer, currentTime.isFinite else {
            return
        }

        if currentTime >= previewDuration - playbackBoundaryTolerance {
            player.pause()
            seekPlayer(toPreviewTime: previewDuration)
        } else if currentTime < 0 {
            seekPlayer(toPreviewTime: .zero, resumePlayback: true)
        }
    }

    private var previewDuration: TimeInterval {
        max(0, endTime - startTime)
    }

    private func schedulePreviewRefresh(seekToSourceTime sourceTime: TimeInterval?) {
        let sourceStart = startTime
        let rangeDuration = previewDuration
        let asset = sourceAsset
        let currentPreviewTime = player.currentTime().seconds
        let previewSeekTime = if let sourceTime {
            min(max(0, sourceTime - sourceStart), rangeDuration)
        } else if currentPreviewTime.isFinite {
            min(max(0, currentPreviewTime), rangeDuration)
        } else {
            TimeInterval.zero
        }
        let shouldResume = player.rate > 0

        previewGeneration += 1
        let generation = previewGeneration
        previewRefreshTask?.cancel()
        previewRefreshTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 60_000_000)
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            await refreshPreviewItem(
                asset: asset,
                sourceStart: sourceStart,
                duration: rangeDuration,
                seekToPreviewTime: previewSeekTime,
                resumePlayback: shouldResume,
                generation: generation
            )
        }
    }

    private func refreshPreviewItem(
        asset: AVURLAsset,
        sourceStart: TimeInterval,
        duration: TimeInterval,
        seekToPreviewTime: TimeInterval,
        resumePlayback: Bool,
        generation: Int
    ) async {
        guard duration >= minimumRange else {
            return
        }

        do {
            let composition = AVMutableComposition()
            try await composition.insertTimeRange(
                CMTimeRange(
                    start: CMTime(seconds: sourceStart, preferredTimescale: 600),
                    duration: CMTime(seconds: duration, preferredTimescale: 600)
                ),
                of: asset,
                at: .zero
            )

            guard generation == previewGeneration, !Task.isCancelled else {
                return
            }

            player.replaceCurrentItem(with: AVPlayerItem(asset: composition))
            seekPlayer(toPreviewTime: seekToPreviewTime, resumePlayback: resumePlayback)
        } catch {
            statusLabel.stringValue = "Could not update preview: \(error.localizedDescription)"
        }
    }

    private func seekPlayer(toPreviewTime time: TimeInterval, resumePlayback: Bool = false) {
        let clampedTime = min(max(0, time), max(0, previewDuration))
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
        let trimSourceURL = sourceURL

        Task {
            do {
                let result = try await trimmer.trim(
                    sourceURL: trimSourceURL,
                    startTime: startTime,
                    endTime: endTime,
                    mode: mode
                )

                if result.replacedOriginal {
                    sourceAsset = AVURLAsset(url: result.url)
                    duration = result.duration
                    startTime = 0
                    endTime = result.duration
                    rangeSlider.maximumValue = result.duration
                    updateControls(seekToSourceTime: .zero)
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

    private static func presentationSize(for asset: AVURLAsset) async throws -> CGSize {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return CGSize(width: 16, height: 9)
        }

        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        return presentationSize(naturalSize: naturalSize, preferredTransform: preferredTransform)
    }

    private static func presentationSize(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform
    ) -> CGSize {
        let transformed = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let transformedSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        if transformedSize.width > 0, transformedSize.height > 0 {
            return transformedSize
        }

        return CGSize(width: abs(naturalSize.width), height: abs(naturalSize.height))
    }
}
