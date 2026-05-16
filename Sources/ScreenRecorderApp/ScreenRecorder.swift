import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit
import ScreenRecorderCore

struct SavedDisplayRecording: Equatable, Sendable {
    let displayID: UInt32
    let displayName: String
    let url: URL
    let isMain: Bool
}

enum SavedRecording: Equatable, Sendable {
    case single(url: URL, duration: TimeInterval)
    case displaySet(folderURL: URL, duration: TimeInterval, entries: [SavedDisplayRecording])

    var duration: TimeInterval {
        switch self {
        case .single(_, let duration), .displaySet(_, let duration, _):
            return duration
        }
    }

    var statusURL: URL {
        switch self {
        case .single(let url, _):
            return url
        case .displaySet(let folderURL, _, _):
            return folderURL
        }
    }
}

struct AvailableHistoryEntry: Equatable, Sendable {
    let displayName: String
    let duration: TimeInterval
    let isMain: Bool
}

struct AvailableHistorySnapshot: Equatable, Sendable {
    let recordingScope: RecordingMode
    let entries: [AvailableHistoryEntry]
}

final class ScreenRecorder: NSObject, @unchecked Sendable {
    private let paths: RecordingPaths
    private let exporter: ClipExporter
    private let captureQueue = DispatchQueue(label: "screen-recorder.capture", qos: .userInitiated)
    private let segmentDuration: TimeInterval = 60
    private let segmentOverlapDuration: TimeInterval = 1
    private let retentionDuration: TimeInterval = 60 * 60
    private let onStateChange: (RecorderState) -> Void

    private var sessions: [CGDirectDisplayID: DisplayCaptureSession] = [:]
    private var selectedMode: RecordingMode
    private var bufferMode: RecordingMode
    private var allDisplayScopeIDs: Set<CGDirectDisplayID> = []
    private var profile: RecordingProfile = .defaultProfile
    private var audioMode: AudioRecordingMode
    private var wakeRestartTask: Task<Void, Never>?
    private var pendingSegmentFinishes = 0
    private var pendingFinishError: Error?
    private var pendingFinishWaiters: [CheckedContinuation<Void, Error>] = []

    var currentMode: RecordingMode {
        selectedMode
    }

    var currentProfile: RecordingProfile {
        profile
    }

    var currentAudioMode: AudioRecordingMode {
        audioMode
    }

    var isCaptureActive: Bool {
        captureQueue.sync {
            sessions.values.contains { $0.isCaptureActive }
        }
    }

    var steadyState: RecorderState {
        if selectedMode == .off {
            return .paused(.off)
        }
        return isCaptureActive ? .recording(selectedMode) : .paused(selectedMode)
    }

    init(
        paths: RecordingPaths = RecordingPaths(),
        mode: RecordingMode = .mainDisplay,
        audioMode: AudioRecordingMode = .off,
        exporter: ClipExporter = ClipExporter(),
        onStateChange: @escaping (RecorderState) -> Void
    ) {
        self.paths = paths
        self.selectedMode = mode
        self.bufferMode = mode == .off ? .mainDisplay : mode
        self.audioMode = audioMode
        self.exporter = exporter
        self.onStateChange = onStateChange
    }

    func start() {
        Task {
            do {
                try paths.prepareForLaunch()
                if selectedMode == .off {
                    try await recoverStoredBufferSessions()
                    publish(.paused(.off))
                } else {
                    try await startCapture(for: selectedMode)
                }
            } catch {
                publish(.failed(error.localizedDescription))
            }
        }
    }

    func setRecordingMode(_ mode: RecordingMode) {
        selectedMode = mode
        if mode != .off {
            bufferMode = mode
        }

        Task {
            do {
                if mode == .off {
                    wakeRestartTask?.cancel()
                    await stopCapture(publishStoppedState: false)
                    publish(.paused(.off))
                } else {
                    try await startCapture(for: mode)
                }
            } catch {
                publish(.failed(error.localizedDescription))
            }
        }
    }

    func availableHistorySnapshot() -> AvailableHistorySnapshot {
        captureQueue.sync {
            availableHistorySnapshotLocked()
        }
    }

    func setProfile(_ newProfile: RecordingProfile) {
        guard newProfile != profile else {
            return
        }

        let wasRecording = isCaptureActive
        profile = newProfile

        guard wasRecording, selectedMode != .off else {
            publish(steadyState)
            return
        }

        Task {
            do {
                publish(.starting)
                try await startCapture(for: selectedMode)
            } catch {
                publish(.failed(error.localizedDescription))
            }
        }
    }

    func setAudioRecordingMode(_ newMode: AudioRecordingMode) {
        guard newMode != audioMode else {
            return
        }

        let wasRecording = isCaptureActive
        audioMode = newMode

        guard wasRecording, selectedMode != .off else {
            publish(steadyState)
            return
        }

        Task {
            do {
                publish(.starting)
                try await startCapture(for: selectedMode)
            } catch {
                publish(.failed(error.localizedDescription))
            }
        }
    }

    func handleSystemWillSleep() {
        Task {
            wakeRestartTask?.cancel()
            guard isCaptureActive else {
                return
            }

            await stopCapture(publishStoppedState: false)
            if selectedMode != .off {
                publish(.paused(selectedMode))
            }
        }
    }

    func handleSystemDidWake() {
        scheduleRestartAfterWake()
    }

    func handleDisplayConfigurationChanged() {
        scheduleRestartAfterWake(delayNanoseconds: 1_000_000_000)
    }

    func stop() {
        wakeRestartTask?.cancel()
        Task {
            await stopCapture(publishStoppedState: true)
        }
    }

    func saveLast(minutes: Int) async throws -> SavedRecording {
        let duration = TimeInterval(minutes * 60)
        let wasRecording = isCaptureActive
        publish(.exporting)
        defer {
            publish(steadyState)
        }

        await finalizeActiveSegments(createReplacement: wasRecording)
        try await waitForPendingFinishes()

        let plan = try await makeExportPlan(forLast: duration)
        let savedRecording: SavedRecording

        switch plan {
        case .single(let selection):
            let actualDuration = selection.requestedDuration
            let outputURL = paths.makeRecordingURL(duration: actualDuration)
            let exportedURL = try await exporter.export(selection: selection, to: outputURL)
            savedRecording = .single(url: exportedURL, duration: actualDuration)

        case .displaySet(let duration, let selections):
            let outputDirectory = paths.makeAllDisplaysRecordingDirectory(duration: duration)
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

            var entries: [SavedDisplayRecording] = []
            for selection in selections {
                let outputURL = paths.makeDisplayRecordingURL(
                    in: outputDirectory,
                    displayName: selection.displayName,
                    displayIndex: selection.displayIndex,
                    displayID: selection.displayID
                )
                let exportedURL = try await exporter.export(selection: selection.selection, to: outputURL)
                entries.append(SavedDisplayRecording(
                    displayID: selection.displayID,
                    displayName: selection.displayName,
                    url: exportedURL,
                    isMain: selection.isMain
                ))
            }

            savedRecording = .displaySet(folderURL: outputDirectory, duration: duration, entries: entries)
        }

        return savedRecording
    }

    private func startCapture(for mode: RecordingMode) async throws {
        publish(.starting)

        guard mode != .off else {
            await stopCapture(publishStoppedState: false)
            publish(.paused(.off))
            return
        }

        guard ScreenCapturePermission.isGranted else {
            publish(.permissionRequired)
            return
        }

        let activeProfile = profile
        let activeAudioMode = audioMode
        let content = try await SCShareableContent.current
        let displays = selectedDisplays(for: mode, from: content.displays)
        guard !displays.isEmpty else {
            throw RecorderRuntimeError("No display is available for capture.")
        }

        await stopCapture(publishStoppedState: false)
        bufferMode = mode
        allDisplayScopeIDs = mode == .allDisplays ? Set(displays.map(\.displayID)) : []

        do {
            for (offset, display) in displays.enumerated() {
                let displayIndex = offset + 1
                let isMain = display.displayID == CGMainDisplayID()
                let session = session(for: display, displayIndex: displayIndex, isMain: isMain)
                let geometry = VideoGeometry.fitWithin(
                    sourceWidth: display.width,
                    sourceHeight: display.height,
                    maxLongEdge: activeProfile.maxLongEdge
                )
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let capturesAudio = activeAudioMode.capturesSystemAudio && offset == 0
                let configuration = makeStreamConfiguration(
                    geometry: geometry,
                    profile: activeProfile,
                    capturesAudio: capturesAudio
                )
                let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
                if capturesAudio {
                    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
                }

                try await recoverSessionIfNeeded(session, includeLegacyRoot: isMain)
                try await configureSessionForCapture(session, stream: stream, geometry: geometry)
                try await stream.startCapture()
            }
        } catch {
            await stopCapture(publishStoppedState: false)
            throw error
        }

        publish(.recording(mode))
    }

    private func selectedDisplays(for mode: RecordingMode, from displays: [SCDisplay]) -> [SCDisplay] {
        let sortedDisplays = displays.sorted(by: displaySort)
        switch mode {
        case .mainDisplay:
            let mainDisplayID = CGMainDisplayID()
            if let mainDisplay = sortedDisplays.first(where: { $0.displayID == mainDisplayID }) {
                return [mainDisplay]
            }
            if let firstDisplay = sortedDisplays.first {
                return [firstDisplay]
            }
            return []
        case .allDisplays:
            return sortedDisplays
        case .off:
            return []
        }
    }

    private func displaySort(_ lhs: SCDisplay, _ rhs: SCDisplay) -> Bool {
        let mainDisplayID = CGMainDisplayID()
        if lhs.displayID == mainDisplayID, rhs.displayID != mainDisplayID {
            return true
        }
        if rhs.displayID == mainDisplayID, lhs.displayID != mainDisplayID {
            return false
        }
        if lhs.frame.minX != rhs.frame.minX {
            return lhs.frame.minX < rhs.frame.minX
        }
        if lhs.frame.minY != rhs.frame.minY {
            return lhs.frame.minY < rhs.frame.minY
        }
        return lhs.displayID < rhs.displayID
    }

    private func session(for display: SCDisplay, displayIndex: Int, isMain: Bool) -> DisplayCaptureSession {
        if let session = sessions[display.displayID] {
            session.displayName = Self.displayName(displayIndex: displayIndex, isMain: isMain)
            session.displayIndex = displayIndex
            session.isMain = isMain
            return session
        }

        let session = DisplayCaptureSession(
            displayID: display.displayID,
            displayName: Self.displayName(displayIndex: displayIndex, isMain: isMain),
            displayIndex: displayIndex,
            isMain: isMain,
            retention: retentionDuration
        )
        sessions[display.displayID] = session
        return session
    }

    private func recoverStoredBufferSessions() async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.bufferDirectory, withIntermediateDirectories: true)

        let urls = try fileManager.contentsOfDirectory(
            at: paths.bufferDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let mainDisplayID = CGMainDisplayID()
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true,
                  let displayID = Self.displayID(fromBufferDirectoryName: url.lastPathComponent) else {
                continue
            }

            let isMain = displayID == mainDisplayID
            let session = storedSession(displayID: displayID, isMain: isMain)
            let recoveredSegments = try await BufferedSegmentRecovery.recover(
                in: url,
                retention: retentionDuration
            )
            await restoreRecoveredSegments(recoveredSegments, into: session, markRecovered: true)
        }

        let legacySegments = try await BufferedSegmentRecovery.recover(
            in: paths.bufferDirectory,
            retention: retentionDuration
        )
        if !legacySegments.isEmpty {
            let session = storedSession(displayID: mainDisplayID, isMain: true)
            await restoreRecoveredSegments(
                session.ringBuffer.allSegments + legacySegments,
                into: session,
                markRecovered: true
            )
        }

        updateRecoveredBufferScope()
    }

    private func storedSession(displayID: CGDirectDisplayID, isMain: Bool) -> DisplayCaptureSession {
        if let session = sessions[displayID] {
            return session
        }

        let displayIndex = isMain ? 1 : sessions.count + 1
        let session = DisplayCaptureSession(
            displayID: displayID,
            displayName: Self.displayName(displayIndex: displayIndex, isMain: isMain),
            displayIndex: displayIndex,
            isMain: isMain,
            retention: retentionDuration
        )
        sessions[displayID] = session
        return session
    }

    private func recoverSessionIfNeeded(_ session: DisplayCaptureSession, includeLegacyRoot: Bool) async throws {
        guard !session.hasRecoveredSegments else {
            return
        }

        var recoveredSegments = try await BufferedSegmentRecovery.recover(
            in: paths.bufferDirectory(forDisplayID: session.displayID),
            retention: retentionDuration
        )

        if includeLegacyRoot {
            recoveredSegments += try await BufferedSegmentRecovery.recover(
                in: paths.bufferDirectory,
                retention: retentionDuration
            )
        }

        await restoreRecoveredSegments(recoveredSegments, into: session, markRecovered: true)
    }

    private func restoreRecoveredSegments(
        _ segments: [RecordedSegment],
        into session: DisplayCaptureSession,
        markRecovered: Bool
    ) async {
        await withCheckedContinuation { continuation in
            captureQueue.async {
                session.ringBuffer.restore(segments)
                session.hasRecoveredSegments = markRecovered
                continuation.resume()
            }
        }
    }

    private func updateRecoveredBufferScope() {
        guard selectedMode == .off else {
            return
        }

        captureQueue.sync {
            let recoveredDisplayIDs = self.sessions.values
                .filter { $0.ringBuffer.mediaDuration > 0 }
                .map(\.displayID)
            if recoveredDisplayIDs.count > 1 {
                self.bufferMode = .allDisplays
                self.allDisplayScopeIDs = Set(recoveredDisplayIDs)
            } else {
                self.bufferMode = .mainDisplay
                self.allDisplayScopeIDs = []
            }
        }
    }

    private func configureSessionForCapture(
        _ session: DisplayCaptureSession,
        stream: SCStream,
        geometry: VideoGeometry
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            captureQueue.async {
                do {
                    session.geometry = geometry
                    session.stream = stream
                    session.activeWriters = [try self.makeActiveWriterLocked(for: session)]
                    continuation.resume()
                } catch {
                    session.stream = nil
                    session.activeWriters.removeAll()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func availableHistorySnapshotLocked() -> AvailableHistorySnapshot {
        switch bufferMode {
        case .mainDisplay, .off:
            let entries = primarySessionLocked().map { [historyEntry(for: $0)] } ?? [
                AvailableHistoryEntry(displayName: Self.displayName(displayIndex: 1, isMain: true), duration: 0, isMain: true)
            ]
            return AvailableHistorySnapshot(recordingScope: .mainDisplay, entries: entries)
        case .allDisplays:
            let displaySessions = allDisplaySessionsLocked()
            guard !displaySessions.isEmpty else {
                return AvailableHistorySnapshot(recordingScope: .allDisplays, entries: [])
            }
            return AvailableHistorySnapshot(
                recordingScope: .allDisplays,
                entries: displaySessions.map(historyEntry)
            )
        }
    }

    private func stopCapture(publishStoppedState: Bool) async {
        let streams = captureQueue.sync {
            sessions.values.compactMap(\.stream)
        }

        for stream in streams {
            try? await stream.stopCapture()
        }

        await withCheckedContinuation { continuation in
            captureQueue.async {
                for session in self.sessions.values where session.stream != nil {
                    session.stream = nil
                }
                continuation.resume()
            }
        }

        await finalizeActiveSegments(createReplacement: false)
        if publishStoppedState {
            publish(.stopped)
        }
    }

    private func scheduleRestartAfterWake(delayNanoseconds: UInt64 = 2_000_000_000) {
        guard selectedMode != .off else {
            return
        }

        wakeRestartTask?.cancel()
        wakeRestartTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
                try Task.checkCancellation()
                guard let self else {
                    return
                }
                try await self.startCapture(for: self.selectedMode)
            } catch is CancellationError {
                return
            } catch {
                self?.publish(.failed(error.localizedDescription))
            }
        }
    }

    private func handleStreamStoppedUnexpectedly(_ error: Error) async {
        await stopCapture(publishStoppedState: false)

        guard selectedMode != .off else {
            publish(.paused(.off))
            return
        }

        publish(.starting)
        scheduleRestartAfterWake(delayNanoseconds: 1_000_000_000)
    }

    private func makeStreamConfiguration(
        geometry: VideoGeometry,
        profile: RecordingProfile,
        capturesAudio: Bool
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = geometry.width
        configuration.height = geometry.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(profile.frameRate))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = false
        configuration.preservesAspectRatio = true
        configuration.showsCursor = true
        configuration.queueDepth = 5
        configuration.capturesAudio = capturesAudio
        if capturesAudio {
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            configuration.excludesCurrentProcessAudio = true
        }
        return configuration
    }

    private func makeWriterLocked(for session: DisplayCaptureSession) throws -> SegmentFileWriter {
        guard let geometry = session.geometry else {
            throw RecorderRuntimeError("Recording geometry is not configured.")
        }

        try FileManager.default.createDirectory(
            at: paths.bufferDirectory(forDisplayID: session.displayID),
            withIntermediateDirectories: true
        )

        return try SegmentFileWriter(
            url: paths.makeSegmentURL(displayID: session.displayID),
            geometry: geometry,
            frameRate: profile.frameRate,
            bitRate: profile.bitRate(for: geometry),
            capturesAudio: audioMode.capturesSystemAudio
        )
    }

    private func makeActiveWriterLocked(for session: DisplayCaptureSession) throws -> ActiveSegmentWriter {
        ActiveSegmentWriter(writer: try makeWriterLocked(for: session))
    }

    private func handle(sampleBuffer: CMSampleBuffer, from stream: SCStream, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            handleScreenSampleBuffer(sampleBuffer, from: stream)
        case .audio:
            handleAudioSampleBuffer(sampleBuffer)
        case .microphone:
            return
        @unknown default:
            return
        }
    }

    private func handleScreenSampleBuffer(_ sampleBuffer: CMSampleBuffer, from stream: SCStream) {
        guard isCompleteFrame(sampleBuffer),
              let session = sessions.values.first(where: { $0.stream === stream }) else {
            return
        }

        do {
            if session.activeWriters.isEmpty {
                session.activeWriters = [try makeActiveWriterLocked(for: session)]
            }

            let receivedAt = Date()
            for activeWriter in session.activeWriters {
                try activeWriter.appendVideo(sampleBuffer, receivedAt: receivedAt)
            }

            if session.activeWriters.count == 1,
               let activeWriter = session.activeWriters.first,
               activeWriter.writer.elapsedAtLastFrame >= segmentDuration {
                let nextWriter = try makeActiveWriterLocked(for: session)
                let alignedReceivedAt = activeWriter.mediaDate(for: sampleBuffer) ?? receivedAt
                try nextWriter.appendVideo(sampleBuffer, receivedAt: alignedReceivedAt)
                session.activeWriters.append(nextWriter)
            }

            let finishedWriters = session.activeWriters.dropLast().filter {
                $0.writer.elapsedAtLastFrame >= segmentDuration + segmentOverlapDuration
            }
            if !finishedWriters.isEmpty {
                let finishedURLs = Set(finishedWriters.map(\.writer.url))
                session.activeWriters.removeAll { finishedURLs.contains($0.writer.url) }
                for activeWriter in finishedWriters {
                    finishWriterLocked(activeWriter.writer, displayID: session.displayID)
                }
            }
        } catch {
            publish(.failed(error.localizedDescription))
        }
    }

    private func handleAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard audioMode.capturesSystemAudio else {
            return
        }

        do {
            for session in sessions.values {
                for activeWriter in session.activeWriters {
                    try activeWriter.writer.appendAudio(sampleBuffer)
                }
            }
        } catch {
            publish(.failed(error.localizedDescription))
        }
    }

    private func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let first = attachments.first,
              let rawStatus = first[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else {
            return true
        }

        return status == .complete || status == .started
    }

    private func finalizeActiveSegments(createReplacement: Bool) async {
        await withCheckedContinuation { continuation in
            captureQueue.async {
                var targets: [(CGDirectDisplayID, SegmentFileWriter)] = []
                for session in self.sessions.values where !session.activeWriters.isEmpty {
                    targets += session.activeWriters.map { (session.displayID, $0.writer) }

                    do {
                        session.activeWriters = createReplacement && session.stream != nil
                            ? [try self.makeActiveWriterLocked(for: session)]
                            : []
                    } catch {
                        session.activeWriters.removeAll()
                        self.pendingFinishError = error
                        self.publish(.failed(error.localizedDescription))
                    }
                }

                guard !targets.isEmpty else {
                    continuation.resume()
                    return
                }

                var remaining = targets.count
                for (displayID, writer) in targets {
                    self.finishWriterLocked(writer, displayID: displayID) {
                        remaining -= 1
                        if remaining == 0 {
                            continuation.resume()
                        }
                    }
                }
            }
        }
    }

    private func waitForPendingFinishes() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            captureQueue.async {
                if self.pendingSegmentFinishes == 0 {
                    if let error = self.pendingFinishError {
                        self.pendingFinishError = nil
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                    return
                }

                self.pendingFinishWaiters.append(continuation)
            }
        }
    }

    private func finishWriterLocked(
        _ writer: SegmentFileWriter,
        displayID: CGDirectDisplayID,
        completion: (() -> Void)? = nil
    ) {
        pendingSegmentFinishes += 1

        writer.finish { result in
            self.captureQueue.async {
                switch result {
                case .success(let segment):
                    if let segment {
                        self.sessions[displayID]?.ringBuffer.add(segment)
                    }
                case .failure(let error):
                    self.pendingFinishError = error
                    self.publish(.failed(error.localizedDescription))
                }

                self.pendingSegmentFinishes -= 1
                completion?()
                self.resumeFinishWaitersIfReadyLocked()
            }
        }
    }

    private func resumeFinishWaitersIfReadyLocked() {
        guard pendingSegmentFinishes == 0, !pendingFinishWaiters.isEmpty else {
            return
        }

        let waiters = pendingFinishWaiters
        pendingFinishWaiters.removeAll()

        if let error = pendingFinishError {
            pendingFinishError = nil
            waiters.forEach { $0.resume(throwing: error) }
        } else {
            waiters.forEach { $0.resume() }
        }
    }

    private func makeExportPlan(forLast duration: TimeInterval) async throws -> ExportPlan {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ExportPlan, Error>) in
            captureQueue.async {
                do {
                    continuation.resume(returning: try self.makeExportPlanLocked(forLast: duration))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func makeExportPlanLocked(forLast duration: TimeInterval) throws -> ExportPlan {
        switch bufferMode {
        case .mainDisplay, .off:
            guard let session = primarySessionLocked(),
                  let selection = session.ringBuffer.selection(forLast: duration) else {
                throw RecorderRuntimeError("No video has been recorded yet.")
            }
            return .single(selection: selection)

        case .allDisplays:
            let displaySessions = allDisplaySessionsLocked()
            guard !displaySessions.isEmpty else {
                throw RecorderRuntimeError("No video has been recorded yet.")
            }

            let exportDurations = RecordingDurationPlan.perDisplayExportDurations(
                requestedDuration: duration,
                availableDurations: RecordingDurationPlan.perDisplayAvailableHistoryDurations(
                    rawDurations: displaySessions.map(\.ringBuffer.mediaDuration),
                    retentionDuration: retentionDuration
                )
            )
            var selections: [DisplaySelection] = []
            for (session, exportDuration) in zip(displaySessions, exportDurations) {
                guard exportDuration > 0 else {
                    continue
                }
                guard let selection = session.ringBuffer.selection(forLast: exportDuration) else {
                    throw RecorderRuntimeError("No video has been recorded for \(session.displayName).")
                }
                selections.append(DisplaySelection(
                    displayID: session.displayID,
                    displayName: session.displayName,
                    displayIndex: session.displayIndex,
                    isMain: session.isMain,
                    selection: selection
                ))
            }

            guard !selections.isEmpty else {
                throw RecorderRuntimeError("No video has been recorded yet.")
            }

            let actualDuration = selections.map(\.selection.requestedDuration).max() ?? 0
            return .displaySet(duration: actualDuration, selections: selections)
        }
    }

    private func primarySessionLocked() -> DisplayCaptureSession? {
        sessions.values.first(where: \.isMain) ?? sessions.values.sorted(by: sessionSort).first
    }

    private func allDisplaySessionsLocked() -> [DisplayCaptureSession] {
        let displaySessions = allDisplayScopeIDs.isEmpty
            ? Array(sessions.values)
            : sessions.values.filter { allDisplayScopeIDs.contains($0.displayID) }
        return displaySessions.sorted(by: sessionSort)
    }

    private func sessionSort(_ lhs: DisplayCaptureSession, _ rhs: DisplayCaptureSession) -> Bool {
        if lhs.isMain, !rhs.isMain {
            return true
        }
        if rhs.isMain, !lhs.isMain {
            return false
        }
        if lhs.displayIndex != rhs.displayIndex {
            return lhs.displayIndex < rhs.displayIndex
        }
        return lhs.displayID < rhs.displayID
    }

    private func publish(_ state: RecorderState) {
        DispatchQueue.main.async {
            self.onStateChange(state)
        }
    }

    private static func displayName(displayIndex: Int, isMain: Bool) -> String {
        isMain ? "Main Display" : "Display \(displayIndex)"
    }

    private func historyEntry(for session: DisplayCaptureSession) -> AvailableHistoryEntry {
        AvailableHistoryEntry(
            displayName: session.displayName,
            duration: RecordingDurationPlan.availableHistoryDuration(
                rawDuration: session.mediaDuration,
                retentionDuration: retentionDuration
            ),
            isMain: session.isMain
        )
    }

    private static func displayID(fromBufferDirectoryName name: String) -> CGDirectDisplayID? {
        let prefix = "display-"
        guard name.hasPrefix(prefix),
              let id = CGDirectDisplayID(name.dropFirst(prefix.count)) else {
            return nil
        }
        return id
    }
}

extension ScreenRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        handle(sampleBuffer: sampleBuffer, from: stream, of: type)
    }
}

extension ScreenRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task {
            await handleStreamStoppedUnexpectedly(error)
        }
    }
}

private final class DisplayCaptureSession: @unchecked Sendable {
    let displayID: CGDirectDisplayID
    let ringBuffer: SegmentRingBuffer
    var displayName: String
    var displayIndex: Int
    var isMain: Bool
    var geometry: VideoGeometry?
    var stream: SCStream?
    var activeWriters: [ActiveSegmentWriter] = []
    var hasRecoveredSegments = false

    init(
        displayID: CGDirectDisplayID,
        displayName: String,
        displayIndex: Int,
        isMain: Bool,
        retention: TimeInterval
    ) {
        self.displayID = displayID
        self.displayName = displayName
        self.displayIndex = displayIndex
        self.isMain = isMain
        self.ringBuffer = SegmentRingBuffer(retention: retention)
    }

    var isCaptureActive: Bool {
        stream != nil
    }

    var mediaDuration: TimeInterval {
        let activeSegments = activeWriters.compactMap(\.estimatedSegment)
        return SegmentRingBuffer.unionDuration(of: ringBuffer.allSegments + activeSegments)
    }
}

private final class ActiveSegmentWriter {
    let writer: SegmentFileWriter
    private var firstSampleDate: Date?
    private var firstPresentationTime: CMTime?

    init(writer: SegmentFileWriter) {
        self.writer = writer
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer, receivedAt date: Date) throws {
        if firstSampleDate == nil {
            firstSampleDate = date
        }
        if firstPresentationTime == nil {
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if presentationTime.isValid {
                firstPresentationTime = presentationTime
            }
        }
        try writer.append(sampleBuffer, receivedAt: date)
    }

    func mediaDate(for sampleBuffer: CMSampleBuffer) -> Date? {
        guard let firstSampleDate, let firstPresentationTime else {
            return nil
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid else {
            return nil
        }

        return firstSampleDate.addingTimeInterval(CMTimeGetSeconds(presentationTime - firstPresentationTime))
    }

    var estimatedSegment: RecordedSegment? {
        guard let firstSampleDate else {
            return nil
        }

        let duration = writer.elapsedAtLastFrame
        guard duration > 0 else {
            return nil
        }

        return RecordedSegment(
            url: writer.url,
            startDate: firstSampleDate,
            endDate: firstSampleDate.addingTimeInterval(duration)
        )
    }
}

private enum ExportPlan {
    case single(selection: SegmentSelection)
    case displaySet(duration: TimeInterval, selections: [DisplaySelection])
}

private struct DisplaySelection {
    let displayID: CGDirectDisplayID
    let displayName: String
    let displayIndex: Int
    let isMain: Bool
    let selection: SegmentSelection
}

private struct RecorderRuntimeError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
