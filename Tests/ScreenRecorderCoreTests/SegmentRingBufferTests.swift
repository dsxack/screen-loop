@preconcurrency import AVFoundation
import CoreVideo
import ScreenRecorderCore
import Testing

@Suite
struct SegmentRingBufferTests {
    @Test
    func testRetentionKeepsSegmentsByRecordedMediaDuration() throws {
        let directory = try makeTemporaryDirectory()
        let buffer = SegmentRingBuffer(retention: 60)
        let base = Date(timeIntervalSince1970: 100)

        let segments = [
            makeSegment(in: directory, name: "0.mov", start: base, end: base.addingTimeInterval(30)),
            makeSegment(in: directory, name: "1.mov", start: base.addingTimeInterval(30), end: base.addingTimeInterval(60)),
            makeSegment(in: directory, name: "2.mov", start: base.addingTimeInterval(60), end: base.addingTimeInterval(90)),
            makeSegment(in: directory, name: "3.mov", start: base.addingTimeInterval(90), end: base.addingTimeInterval(120))
        ]

        try segments.forEach { try Data().write(to: $0.url) }
        segments.forEach(buffer.add)

        #expect(buffer.allSegments.map(\.url.lastPathComponent) == ["2.mov", "3.mov"])
        #expect(!FileManager.default.fileExists(atPath: segments[0].url.path))
        #expect(!FileManager.default.fileExists(atPath: segments[1].url.path))
    }

    @Test
    func testSelectionForLastDurationTrimsStartAndReturnsOverlappingSegments() throws {
        let directory = try makeTemporaryDirectory()
        let buffer = SegmentRingBuffer(retention: 1800)
        let base = Date(timeIntervalSince1970: 200)

        let segments = [
            makeSegment(in: directory, name: "0.mov", start: base, end: base.addingTimeInterval(30)),
            makeSegment(in: directory, name: "1.mov", start: base.addingTimeInterval(30), end: base.addingTimeInterval(60)),
            makeSegment(in: directory, name: "2.mov", start: base.addingTimeInterval(60), end: base.addingTimeInterval(90))
        ]
        segments.forEach(buffer.add)

        let selection = try #require(buffer.selection(forLast: 45))
        #expect(selection.segments.map(\.url.lastPathComponent) == ["1.mov", "2.mov"])
        #expect(selection.requestedStartDate == base.addingTimeInterval(45))
        #expect(selection.endDate == base.addingTimeInterval(90))
    }

    @Test
    func testSelectionClampsToAvailableHistory() throws {
        let directory = try makeTemporaryDirectory()
        let buffer = SegmentRingBuffer(retention: 1800)
        let base = Date(timeIntervalSince1970: 300)

        let segments = [
            makeSegment(in: directory, name: "0.mov", start: base, end: base.addingTimeInterval(30)),
            makeSegment(in: directory, name: "1.mov", start: base.addingTimeInterval(30), end: base.addingTimeInterval(60))
        ]
        segments.forEach(buffer.add)

        let selection = try #require(buffer.selection(forLast: 180))
        #expect(selection.segments == segments)
        #expect(selection.requestedStartDate == base)
        #expect(selection.requestedDuration == 60)
    }

    @Test
    func testSelectionUsesRecordedMediaDurationAcrossGaps() throws {
        let directory = try makeTemporaryDirectory()
        let buffer = SegmentRingBuffer(retention: 1800)
        let base = Date(timeIntervalSince1970: 325)

        let segments = [
            makeSegment(in: directory, name: "0.mov", start: base, end: base.addingTimeInterval(60)),
            makeSegment(in: directory, name: "1.mov", start: base.addingTimeInterval(180), end: base.addingTimeInterval(240))
        ]
        segments.forEach(buffer.add)

        let selection = try #require(buffer.selection(forLast: 120))
        #expect(selection.segments == segments)
        #expect(selection.requestedDuration == 120)
    }

    @Test
    func testMediaDurationSumsRetainedSegments() throws {
        let directory = try makeTemporaryDirectory()
        let buffer = SegmentRingBuffer(retention: 60)
        let base = Date(timeIntervalSince1970: 350)

        buffer.add(makeSegment(in: directory, name: "0.mov", start: base, end: base.addingTimeInterval(10)))
        buffer.add(makeSegment(in: directory, name: "1.mov", start: base.addingTimeInterval(10), end: base.addingTimeInterval(25)))

        #expect(buffer.mediaDuration == 25)
    }

    @Test
    func testVideoGeometryFitsWithin1080p() {
        #expect(VideoGeometry.fitWithin1080p(sourceWidth: 5120, sourceHeight: 2880) == VideoGeometry(width: 1920, height: 1080))
        #expect(VideoGeometry.fitWithin1080p(sourceWidth: 1512, sourceHeight: 982) == VideoGeometry(width: 1512, height: 982))
        #expect(VideoGeometry.fitWithin(sourceWidth: 1920, sourceHeight: 1080, maxLongEdge: 1920) == VideoGeometry(width: 1920, height: 1080))
        #expect(VideoGeometry.fitWithin(sourceWidth: 1080, sourceHeight: 1920, maxLongEdge: 1920) == VideoGeometry(width: 1080, height: 1920))
        #expect(VideoGeometry.fitWithin(sourceWidth: 3840, sourceHeight: 2160, maxLongEdge: 1920) == VideoGeometry(width: 1920, height: 1080))
        #expect(VideoGeometry.fitWithin(sourceWidth: 1080, sourceHeight: 1920, maxLongEdge: 1280) == VideoGeometry(width: 720, height: 1280))
    }

    @Test
    func testRecordingProfilesSetExpectedLoadLevels() {
        let highGeometry = VideoGeometry(width: 1920, height: 1080)
        let readableGeometry = VideoGeometry(width: 1920, height: 1080)
        let lowGeometry = VideoGeometry(width: 1280, height: 720)

        #expect(RecordingProfile.defaultProfile == .readableText)
        #expect(RecordingProfile.readableText.frameRate == 15)
        #expect(RecordingProfile.readableText.maxLongEdge == 1920)
        #expect(RecordingProfile.highQuality.frameRate == 30)
        #expect(RecordingProfile.highQuality.maxLongEdge == 1920)
        #expect(RecordingProfile.lowPower.frameRate == 15)
        #expect(RecordingProfile.lowPower.maxLongEdge == 1280)
        #expect(RecordingProfile.readableText.bitRate(for: readableGeometry) == 5_000_000)
        #expect(RecordingProfile.highQuality.bitRate(for: highGeometry) == 8_000_000)
        #expect(RecordingProfile.lowPower.bitRate(for: lowGeometry) == 2_000_000)
    }

    @Test
    func testBufferedSegmentRecoveryTrimsToMediaRetention() async throws {
        let directory = try makeTemporaryDirectory()
        let paths = RecordingPaths(
            bufferDirectory: directory,
            recordingsDirectory: directory.appendingPathComponent("Recordings", isDirectory: true)
        )
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        let oldURL = paths.makeSegmentURL(startDate: base.addingTimeInterval(10))
        let recentURL = paths.makeSegmentURL(startDate: base.addingTimeInterval(100))
        let newerURL = paths.makeSegmentURL(startDate: base.addingTimeInterval(110))
        let invalidURL = paths.makeSegmentURL(startDate: base.addingTimeInterval(115))

        try await makeTestVideo(url: oldURL, duration: 1)
        try await makeTestVideo(url: recentURL, duration: 1)
        try await makeTestVideo(url: newerURL, duration: 1)
        try Data("not a movie".utf8).write(to: invalidURL)

        let recovered = try await BufferedSegmentRecovery.recover(
            in: directory,
            retention: 2,
            now: base.addingTimeInterval(120)
        )

        #expect(recovered.map(\.url.lastPathComponent) == [
            recentURL.lastPathComponent,
            newerURL.lastPathComponent
        ])
        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
        #expect(FileManager.default.fileExists(atPath: recentURL.path))
        #expect(FileManager.default.fileExists(atPath: newerURL.path))
        #expect(!FileManager.default.fileExists(atPath: invalidURL.path))
    }

    @Test
    func testSegmentFilenameDateRoundTrips() throws {
        let directory = try makeTemporaryDirectory()
        let paths = RecordingPaths(bufferDirectory: directory, recordingsDirectory: directory)
        let date = Date(timeIntervalSince1970: 1_700_000_123)
        let url = paths.makeSegmentURL(startDate: date)

        #expect(RecordingPaths.segmentStartDate(from: url) == date)
        #expect(RecordingPaths.segmentStartDate(from: directory.appendingPathComponent("other.mov")) == nil)
    }

    @Test
    func testRecordingDurationStampUsesActualDuration() {
        #expect(RecordingPaths.durationStamp(1) == "1s")
        #expect(RecordingPaths.durationStamp(180) == "3m")
        #expect(RecordingPaths.durationStamp(948) == "15m48s")
        #expect(RecordingPaths.durationStamp(1800) == "30m")
        #expect(RecordingPaths.durationStamp(3600) == "60m")
    }

    @Test
    func testPerDisplayExportDurationsUseEachDisplayHistory() {
        let availableDurations = RecordingDurationPlan.perDisplayAvailableHistoryDurations(
            rawDurations: [3660, 300],
            retentionDuration: 3600
        )
        let exportDurations = RecordingDurationPlan.perDisplayExportDurations(
            requestedDuration: 3600,
            availableDurations: availableDurations
        )

        #expect(RecordingDurationPlan.availableHistoryDuration(rawDuration: 3660, retentionDuration: 3600) == 3600)
        #expect(availableDurations == [3600, 300])
        #expect(exportDurations == [3600, 300])
    }

    @Test
    func testDisplayScopedRecordingPaths() throws {
        let directory = try makeTemporaryDirectory()
        let paths = RecordingPaths(
            bufferDirectory: directory.appendingPathComponent("Buffer", isDirectory: true),
            recordingsDirectory: directory.appendingPathComponent("Recordings", isDirectory: true)
        )
        let date = Date(timeIntervalSince1970: 1_700_000_123)

        let displayBufferDirectory = paths.bufferDirectory(forDisplayID: 123)
        #expect(displayBufferDirectory.lastPathComponent == "display-123")

        let segmentURL = paths.makeSegmentURL(displayID: 123, startDate: date)
        #expect(segmentURL.deletingLastPathComponent() == displayBufferDirectory)
        #expect(RecordingPaths.segmentStartDate(from: segmentURL) == date)

        let outputDirectory = paths.makeAllDisplaysRecordingDirectory(duration: 65, date: date)
        #expect(outputDirectory.lastPathComponent.contains("Last 1m05s - All Displays"))

        let displayURL = paths.makeDisplayRecordingURL(
            in: outputDirectory,
            displayName: "Main/Display: One\n",
            displayIndex: 1,
            displayID: 123
        )
        #expect(displayURL.lastPathComponent == "01 - Main-Display-One - Display 123.mov")
    }

    @Test
    func testDefaultRecordingPathsUsePublicProductName() {
        let paths = RecordingPaths()

        #expect(paths.bufferDirectory.path.hasSuffix("Application Support/Screen Loop/Buffer"))
        #expect(paths.recordingsDirectory.path.hasSuffix("Movies/Screen Loop"))
    }

    @Test
    func testExporterTrimsAndConcatenatesSegments() async throws {
        let directory = try makeTemporaryDirectory()
        let firstURL = directory.appendingPathComponent("first.mov")
        let secondURL = directory.appendingPathComponent("second.mov")
        let outputURL = directory.appendingPathComponent("output.mov")

        try await makeTestVideo(url: firstURL, duration: 1.0)
        try await makeTestVideo(url: secondURL, duration: 1.0)

        let base = Date(timeIntervalSince1970: 400)
        let selection = SegmentSelection(
            segments: [
                RecordedSegment(url: firstURL, startDate: base, endDate: base.addingTimeInterval(1)),
                RecordedSegment(url: secondURL, startDate: base.addingTimeInterval(1), endDate: base.addingTimeInterval(2))
            ],
            requestedStartDate: base.addingTimeInterval(0.5),
            endDate: base.addingTimeInterval(2)
        )

        let exportedURL = try await ClipExporter().export(selection: selection, to: outputURL)
        let asset = AVURLAsset(url: exportedURL)
        let exportedDuration = try await asset.load(.duration)

        #expect(abs(exportedDuration.seconds - 1.5) < 0.35)
    }

    @Test
    func testExporterCapsOutputToSelectionRequestedDuration() async throws {
        let directory = try makeTemporaryDirectory()
        let firstURL = directory.appendingPathComponent("first.mov")
        let secondURL = directory.appendingPathComponent("second.mov")
        let outputURL = directory.appendingPathComponent("output.mov")

        try await makeTestVideo(url: firstURL, duration: 2.0)
        try await makeTestVideo(url: secondURL, duration: 2.0)

        let base = Date(timeIntervalSince1970: 500)
        let selection = SegmentSelection(
            segments: [
                RecordedSegment(url: firstURL, startDate: base, endDate: base.addingTimeInterval(1)),
                RecordedSegment(url: secondURL, startDate: base.addingTimeInterval(1), endDate: base.addingTimeInterval(3))
            ],
            requestedStartDate: base,
            endDate: base.addingTimeInterval(3)
        )

        let exportedURL = try await ClipExporter().export(selection: selection, to: outputURL)
        let asset = AVURLAsset(url: exportedURL)
        let exportedDuration = try await asset.load(.duration)

        #expect(abs(exportedDuration.seconds - 3.0) < 0.35)
    }

    @Test
    func testVideoTrimmerCreateNewPreservesOriginal() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("source.mov")
        try await makeTestVideo(url: sourceURL, duration: 4.0)

        let originalDuration = try await AVURLAsset(url: sourceURL).load(.duration).seconds
        let result = try await VideoTrimmer().trim(
            sourceURL: sourceURL,
            startTime: 0.5,
            endTime: 2.0,
            mode: .createNew,
            date: Date(timeIntervalSince1970: 600)
        )

        let trimmedDuration = try await AVURLAsset(url: result.url).load(.duration).seconds
        let sourceDuration = try await AVURLAsset(url: sourceURL).load(.duration).seconds

        #expect(result.url != sourceURL)
        #expect(result.url.lastPathComponent.contains("Trimmed"))
        #expect(result.replacedOriginal == false)
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(FileManager.default.fileExists(atPath: result.url.path))
        #expect(abs(result.duration - 1.5) < 0.01)
        #expect(abs(trimmedDuration - 1.5) < 0.35)
        #expect(abs(sourceDuration - originalDuration) < 0.35)
    }

    @Test
    func testVideoTrimmerReplaceOriginal() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("source.mov")
        try await makeTestVideo(url: sourceURL, duration: 4.0)

        let result = try await VideoTrimmer().trim(
            sourceURL: sourceURL,
            startTime: 1.0,
            endTime: 2.5,
            mode: .replaceOriginal
        )

        let replacedDuration = try await AVURLAsset(url: sourceURL).load(.duration).seconds

        #expect(result.url == sourceURL)
        #expect(result.replacedOriginal == true)
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(abs(result.duration - 1.5) < 0.01)
        #expect(abs(replacedDuration - 1.5) < 0.35)
    }

    @Test
    func testVideoTrimmerRejectsInvalidRange() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("source.mov")
        try await makeTestVideo(url: sourceURL, duration: 2.0)

        var didThrow = false
        do {
            _ = try await VideoTrimmer().trim(
                sourceURL: sourceURL,
                startTime: 1.0,
                endTime: 1.2,
                mode: .createNew
            )
        } catch {
            didThrow = true
        }

        #expect(didThrow)
    }

    private func makeSegment(in directory: URL, name: String, start: Date, end: Date) -> RecordedSegment {
        RecordedSegment(url: directory.appendingPathComponent(name), startDate: start, endDate: end)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenRecorderTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeTestVideo(url: URL, duration: Double, frameRate: Int = 10) async throws {
        let width = 160
        let height = 90
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
        )

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )

        guard writer.canAdd(input) else {
            throw TestVideoError("Writer cannot add video input.")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? TestVideoError("Writer could not start.")
        }
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int(duration * Double(frameRate))
        for frame in 0..<frameCount {
            guard input.isReadyForMoreMediaData else {
                try await Task.sleep(nanoseconds: 10_000_000)
                continue
            }

            var pixelBuffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool else {
                throw TestVideoError("Missing pixel buffer pool.")
            }

            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let pixelBuffer else {
                throw TestVideoError("Could not create a pixel buffer.")
            }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
                memset(baseAddress, frame % 2 == 0 ? 0x22 : 0x44, CVPixelBufferGetDataSize(pixelBuffer))
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            let presentationTime = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(frameRate))
            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? TestVideoError("Could not append a pixel buffer.")
            }
        }

        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: CMTimeScale(frameRate)))
        input.markAsFinished()
        let writerBox = AssetWriterBox(writer)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if let error = writerBox.writer.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

private final class AssetWriterBox: @unchecked Sendable {
    let writer: AVAssetWriter

    init(_ writer: AVAssetWriter) {
        self.writer = writer
    }
}

private struct TestVideoError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
