import Foundation

public enum RecordingDurationPlan {
    public static func availableHistoryDuration(
        rawDuration: TimeInterval,
        retentionDuration: TimeInterval
    ) -> TimeInterval {
        min(max(0, rawDuration), max(0, retentionDuration))
    }

    public static func perDisplayAvailableHistoryDurations(
        rawDurations: [TimeInterval],
        retentionDuration: TimeInterval
    ) -> [TimeInterval] {
        rawDurations.map { rawDuration in
            availableHistoryDuration(rawDuration: rawDuration, retentionDuration: retentionDuration)
        }
    }

    public static func perDisplayExportDurations(
        requestedDuration: TimeInterval,
        availableDurations: [TimeInterval]
    ) -> [TimeInterval] {
        let requestedDuration = max(0, requestedDuration)
        return availableDurations.map { availableDuration in
            min(requestedDuration, max(0, availableDuration))
        }
    }
}
