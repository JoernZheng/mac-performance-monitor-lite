import Darwin
import Foundation

private typealias FSStatBuffer = statfs

public final class BootVolumeReader {
    public struct Capacity: Sendable, Equatable {
        public var totalBytes: UInt64
        public var freeBytes: UInt64
    }

    private let source: () -> Capacity?
    private let minInterval: TimeInterval
    private var cached: Capacity?
    private var lastReadAt: Date?

    public convenience init() {
        self.init(source: Self.readRoot)
    }

    init(minInterval: TimeInterval = 60, source: @escaping () -> Capacity?) {
        self.minInterval = minInterval
        self.source = source
    }

    public func read(now: Date = Date()) -> Capacity? {
        let due = lastReadAt.map { now.timeIntervalSince($0) >= minInterval } ?? true
        if due {
            // Gate on time regardless of the result, so a failing statfs also
            // stops retrying every tick (the battery reader's convention).
            cached = source() ?? cached
            lastReadAt = now
        }
        return cached
    }

    public func reset() {
        cached = nil
        lastReadAt = nil
    }

    private static func readRoot() -> Capacity? {
        var fs = FSStatBuffer()
        guard statfs("/", &fs) == 0 else { return nil }
        let blockSize = UInt64(fs.f_bsize)
        return Capacity(
            totalBytes: fs.f_blocks * blockSize,
            freeBytes: UInt64(max(0, fs.f_bavail)) * blockSize)
    }
}
