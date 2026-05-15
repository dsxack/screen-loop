import Foundation

public struct RecordingPaths {
    public let bufferDirectory: URL
    public let recordingsDirectory: URL

    public init(
        bufferDirectory: URL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenRecorder", isDirectory: true)
            .appendingPathComponent("Buffer", isDirectory: true),
        recordingsDirectory: URL = FileManager.default
            .urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screen Recorder", isDirectory: true)
    ) {
        self.bufferDirectory = bufferDirectory
        self.recordingsDirectory = recordingsDirectory
    }

    public func prepareForLaunch(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: bufferDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
    }

    public func makeSegmentURL(startDate: Date = Date()) -> URL {
        bufferDirectory.appendingPathComponent("segment-\(Self.fileStamp(from: startDate))-\(UUID().uuidString).mov")
    }

    public static func segmentStartDate(from url: URL) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent
        let prefix = "segment-"
        let stampLength = 19
        guard name.hasPrefix(prefix), name.count > prefix.count + stampLength else {
            return nil
        }

        let stampStart = name.index(name.startIndex, offsetBy: prefix.count)
        let stampEnd = name.index(stampStart, offsetBy: stampLength)
        guard name[stampEnd] == "-" else {
            return nil
        }

        return fileStampFormatter().date(from: String(name[stampStart..<stampEnd]))
    }

    public func makeRecordingURL(duration: TimeInterval, date: Date = Date()) -> URL {
        recordingsDirectory.appendingPathComponent("Screen Recording \(Self.fileStamp(from: date)) - Last \(Self.durationStamp(duration)).mov")
    }

    public static func durationStamp(_ duration: TimeInterval) -> String {
        let totalSeconds = max(1, Int(duration.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60

        switch (minutes, seconds) {
        case (0, let seconds):
            return "\(seconds)s"
        case (let minutes, 0):
            return "\(minutes)m"
        default:
            return "\(minutes)m\(String(format: "%02d", seconds))s"
        }
    }

    private static func fileStamp(from date: Date) -> String {
        fileStampFormatter().string(from: date)
    }

    private static func fileStampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter
    }
}
