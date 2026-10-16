import CoreGraphics
import Darwin
import Foundation
import IOKit

public enum ActivityKind: String, Codable, CaseIterable {
    case userActive = "user_active"
    case backgroundBusy = "background_busy"
    case idle
    case unknown
}

public struct ActivitySignals: Codable, Equatable {
    public var idleSeconds: Double?
    public var locked: Bool?
    public var onConsole: Bool?

    public init(idleSeconds: Double?, locked: Bool?, onConsole: Bool? = true) {
        self.idleSeconds = idleSeconds
        self.locked = locked
        self.onConsole = onConsole
    }

    public static func read() -> ActivitySignals {
        var idle: Double?
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            if let value = IORegistryEntryCreateCFProperty(
                service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                as? NSNumber
            {
                let seconds = value.doubleValue / 1_000_000_000
                if seconds.isFinite, seconds >= 0 { idle = seconds }
            }
        }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return ActivitySignals(
            idleSeconds: idle,
            locked: session?["CGSSessionScreenIsLocked"] as? Bool,
            onConsole: session?[kCGSessionOnConsoleKey as String] as? Bool)
    }
}

public enum ActivityClassifier {
    public static func classify(
        _ signals: ActivitySignals, cpuFraction: Double?, gpuPercent: Double?,
        diskBytesPerSecond: Double?, networkBytesPerSecond: Double?,
        configuration: RecorderConfiguration
    ) -> ActivityKind {
        let unavailableSession = signals.onConsole == false || signals.locked == true
        if !unavailableSession, let idle = signals.idleSeconds,
            idle.isFinite, idle >= 0, idle < configuration.userIdleSeconds
        {
            return .userActive
        }
        guard
            unavailableSession
                || (signals.idleSeconds.map { $0 >= configuration.userIdleSeconds } ?? false)
        else { return .unknown }
        let busy =
            (cpuFraction.map { $0 >= configuration.busyCPUFraction } ?? false)
            || (gpuPercent.map { $0 >= configuration.busyGPUPercent } ?? false)
            || (diskBytesPerSecond.map { $0 >= configuration.busyDiskBytesPerSecond } ?? false)
            || (networkBytesPerSecond.map { $0 >= configuration.busyNetworkBytesPerSecond } ?? false)
        if busy { return .backgroundBusy }
        guard cpuFraction != nil else { return .unknown }
        return .idle
    }
}

/// Excludes sleep; comparing it with wall time exposes suspend and clock changes.
public enum RecorderClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()
    public static func monotonicSeconds() -> Double {
        Double(mach_absolute_time()) * Double(timebase.numer) / Double(timebase.denom)
            / 1_000_000_000
    }

    public static func coveredSeconds(
        previousWall: Double?, previousMonotonic: Double?, wall: Double, monotonic: Double,
        interval: Double
    ) -> Double? {
        guard let pw = previousWall, let pm = previousMonotonic else { return nil }
        let elapsed = monotonic - pm
        let wallElapsed = wall - pw
        guard elapsed > 0, elapsed <= interval * 2.5,
            abs(wallElapsed - elapsed) <= max(2, interval * 0.2)
        else { return nil }
        return elapsed
    }
}
