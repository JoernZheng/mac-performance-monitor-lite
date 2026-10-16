import Foundation

public struct RecorderConfiguration: Codable, Equatable {
    public var interval: TimeInterval = 10
    public var processInterval: TimeInterval = 30
    public var retentionDays: Double = 30
    public var maxDatabaseMB: Int = 2048
    public var userIdleSeconds: TimeInterval = 300
    public var busyCPUFraction: Double = 0.15
    public var busyGPUPercent: Double = 20
    public var busyDiskBytesPerSecond: Double = 5_000_000
    public var busyNetworkBytesPerSecond: Double = 1_000_000
    public var perAppNetwork = true

    public init() {}

    public func validate() throws {
        guard interval.isFinite, (1...300).contains(interval),
            processInterval.isFinite, processInterval >= interval, processInterval <= 3600,
            retentionDays.isFinite, (1...365).contains(retentionDays),
            (64...65536).contains(maxDatabaseMB),
            userIdleSeconds.isFinite, (1...3600).contains(userIdleSeconds),
            busyCPUFraction.isFinite, (0...1).contains(busyCPUFraction),
            busyGPUPercent.isFinite, (0...100).contains(busyGPUPercent),
            busyDiskBytesPerSecond.isFinite, busyDiskBytesPerSecond >= 0,
            busyNetworkBytesPerSecond.isFinite, busyNetworkBytesPerSecond >= 0
        else {
            throw RecorderError.message(
                "Invalid sampling, retention, size, or activity configuration.")
        }
    }

    public static var defaultDatabaseURL: URL {
        // Keep the original recorder directory across the Lite rename.
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/MacPerformanceRecorder/history.sqlite")
    }
}

public enum RecorderError: Error, LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}
