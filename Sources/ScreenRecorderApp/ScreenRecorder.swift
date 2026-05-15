import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import ScreenRecorderCore

struct SavedClip {
    let url: URL
    let duration: TimeInterval
}

final class ScreenRecorder: NSObject, @unchecked Sendable {
    private let paths: RecordingPaths
    private let ringBuffer: SegmentRingBuffer
    private let exporter: ClipExporter
    private let captureQueue = DispatchQueue(label: "screen-recorder.capture", qos: .userInitiated)
    private let segmentDuration: TimeInterval = 60
    private let retentionDuration: TimeInterval = 60 * 60
    private let onStateChange: (RecorderState) -> Void

    private var stream: SCStream?
    private var activeWriter: SegmentFileWriter?
    private var geometry: VideoGeometry?
    private var profile: RecordingProfile = .lowPower
    private var recordingEnabled = true
    private var wakeRestartTask: Task<Void, Never>?
    private var pendingSegmentFinishes = 0
    private var pendingFinishError: Error?
    private var pendingFinishWaiters: [CheckedContinuation<Void, Error>] = []

    var currentProfile: RecordingProfile {
        profile
    }

    var isCaptureActive: Bool {
        stream != nil
    }

    init(
        paths: RecordingPaths = RecordingPaths(),
        exporter: ClipExporter = ClipExporter(),
        onStateChange: @escaping (RecorderState) -> Void
    ) {
        self.paths = paths
        self.ringBuffer = SegmentRingBuffer(retention: retentionDuration)
        self.exporter = exporter
        self.onStateChange = onStateChange
    }

    func start() {
        recordingEnabled = true
        Task {
            do {
                try paths.prepareForLaunch()
                let recoveredSegments = try await BufferedSegmentRecovery.recover(
                    in: paths.bufferDirectory,
                    retention: retentionDuration
                )
                await restoreRecoveredSegments(recoveredSegments)
                try await startCapture()
            } catch {
                publish(.failed(error.localizedDescription))
            }
        }
    }

    func setRecordingEnabled(_ enabled: Bool) {
        recordingEnabled = enabled
        Task {
            do {
                if enabled {
                    try await startCapture()
                } else {
                    await stopCapture(publishStoppedState: false)
                    publish(.paused)
                }
            } catch {
                publish(.failed(error.localizedDescription))
            }
        }
    }

    func availableMediaDuration() async -> TimeInterval {
        await withCheckedContinuation { continuation in
            captureQueue.async {
                continuation.resume(returning: self.availableMediaDurationLocked())
            }
        }
    }

    func availableMediaDurationSnapshot() -> TimeInterval {
        captureQueue.sync {
            availableMediaDurationLocked()
        }
    }

    func setProfile(_ newProfile: RecordingProfile) {
        guard newProfile != profile else {
            return
        }

        let wasRecording = stream != nil
        profile = newProfile

        guard wasRecording else {
            publish(.paused)
            return
        }

        Task {
            do {
                publish(.starting)
                await stopCapture(publishStoppedState: false)
                try await startCapture()
            } catch {
                publish(.failed(error.localizedDescription))
            }
        }
    }

    func handleSystemWillSleep() {
        Task {
            wakeRestartTask?.cancel()
            guard stream != nil else {
                return
            }

            await stopCapture(publishStoppedState: false)
            if recordingEnabled {
                publish(.paused)
            }
        }
    }

    func handleSystemDidWake() {
        scheduleRestartAfterWake()
    }

    private func startCapture() async throws {
        publish(.starting)

        guard ScreenCapturePermission.isGranted else {
            publish(.permissionRequired)
            return
        }

        guard stream == nil else {
            publish(.recording)
            return
        }

        let activeProfile = profile
        let content = try await SCShareableContent.current
        let mainDisplayID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainDisplayID }) ?? content.displays.first else {
            throw RecorderRuntimeError("No display is available for capture.")
        }

        let geometry = VideoGeometry.fitWithin(
            sourceWidth: display.width,
            sourceHeight: display.height,
            maxHeight: activeProfile.maxHeight
        )
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = makeStreamConfiguration(geometry: geometry, profile: activeProfile)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            captureQueue.async {
                do {
                    self.geometry = geometry
                    self.activeWriter = try self.makeWriterLocked()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        try await stream.startCapture()
        self.stream = stream
        publish(.recording)
    }

    private func availableMediaDurationLocked() -> TimeInterval {
        let activeDuration = activeWriter?.elapsedAtLastFrame ?? 0
        return min(retentionDuration, ringBuffer.mediaDuration + activeDuration)
    }

    private func restoreRecoveredSegments(_ segments: [RecordedSegment]) async {
        await withCheckedContinuation { continuation in
            captureQueue.async {
                self.ringBuffer.restore(segments)
                continuation.resume()
            }
        }
    }

    func stop() {
        recordingEnabled = false
        wakeRestartTask?.cancel()
        Task {
            await stopCapture(publishStoppedState: true)
        }
    }

    private func stopCapture(publishStoppedState: Bool) async {
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }

        await finalizeActiveSegment(createReplacement: false)
        if publishStoppedState {
            publish(.stopped)
        }
    }

    private func scheduleRestartAfterWake(delayNanoseconds: UInt64 = 2_000_000_000) {
        guard recordingEnabled else {
            return
        }

        wakeRestartTask?.cancel()
        wakeRestartTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
                try Task.checkCancellation()
                try await self?.startCapture()
            } catch is CancellationError {
                return
            } catch {
                self?.publish(.failed(error.localizedDescription))
            }
        }
    }

    private func handleStreamStoppedUnexpectedly(_ error: Error) async {
        await stopCapture(publishStoppedState: false)

        guard recordingEnabled else {
            publish(.paused)
            return
        }

        publish(.starting)
        scheduleRestartAfterWake(delayNanoseconds: 1_000_000_000)
    }

    func saveLast(minutes: Int) async throws -> SavedClip {
        let duration = TimeInterval(minutes * 60)
        let wasRecording = stream != nil
        publish(.exporting)

        await finalizeActiveSegment(createReplacement: wasRecording)
        try await waitForPendingFinishes()

        let selection = await withCheckedContinuation { continuation in
            captureQueue.async {
                continuation.resume(returning: self.ringBuffer.selection(forLast: duration))
            }
        }

        guard let selection else {
            throw RecorderRuntimeError("No video has been recorded yet.")
        }

        let actualDuration = selection.requestedDuration
        let outputURL = paths.makeRecordingURL(duration: actualDuration)
        let exportedURL = try await exporter.export(selection: selection, to: outputURL)
        publish(wasRecording ? .recording : .paused)
        return SavedClip(url: exportedURL, duration: actualDuration)
    }

    private func makeStreamConfiguration(geometry: VideoGeometry, profile: RecordingProfile) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = geometry.width
        configuration.height = geometry.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(profile.frameRate))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = false
        configuration.preservesAspectRatio = true
        configuration.showsCursor = true
        configuration.queueDepth = 5
        configuration.capturesAudio = false
        return configuration
    }

    private func makeWriterLocked() throws -> SegmentFileWriter {
        guard let geometry else {
            throw RecorderRuntimeError("Recording geometry is not configured.")
        }
        return try SegmentFileWriter(
            url: paths.makeSegmentURL(),
            geometry: geometry,
            frameRate: profile.frameRate,
            bitRate: profile.bitRate(for: geometry)
        )
    }

    private func handle(sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, isCompleteFrame(sampleBuffer) else {
            return
        }

        do {
            if activeWriter == nil {
                activeWriter = try makeWriterLocked()
            }

            guard let writer = activeWriter else {
                return
            }

            try writer.append(sampleBuffer, receivedAt: Date())

            if writer.elapsedAtLastFrame >= segmentDuration {
                activeWriter = try makeWriterLocked()
                finishWriterLocked(writer)
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

    private func finalizeActiveSegment(createReplacement: Bool) async {
        await withCheckedContinuation { continuation in
            captureQueue.async {
                guard let writer = self.activeWriter else {
                    continuation.resume()
                    return
                }

                do {
                    self.activeWriter = createReplacement ? try self.makeWriterLocked() : nil
                    self.finishWriterLocked(writer) {
                        continuation.resume()
                    }
                } catch {
                    self.activeWriter = nil
                    self.pendingFinishError = error
                    self.publish(.failed(error.localizedDescription))
                    continuation.resume()
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

    private func finishWriterLocked(_ writer: SegmentFileWriter, completion: (() -> Void)? = nil) {
        pendingSegmentFinishes += 1

        writer.finish { result in
            self.captureQueue.async {
                switch result {
                case .success(let segment):
                    if let segment {
                        self.ringBuffer.add(segment)
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

    private func publish(_ state: RecorderState) {
        DispatchQueue.main.async {
            self.onStateChange(state)
        }
    }
}

extension ScreenRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        handle(sampleBuffer: sampleBuffer, of: type)
    }
}

extension ScreenRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task {
            await handleStreamStoppedUnexpectedly(error)
        }
    }
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
