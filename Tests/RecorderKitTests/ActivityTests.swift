import XCTest

@testable import RecorderKit

final class ActivityTests: XCTestCase {
    private func classify(
        idle: Double?, locked: Bool? = false, console: Bool? = true,
        cpu: Double? = 0.01, gpu: Double? = nil, disk: Double? = nil
    ) -> ActivityKind {
        ActivityClassifier.classify(
            ActivitySignals(idleSeconds: idle, locked: locked, onConsole: console),
            cpuFraction: cpu, gpuPercent: gpu, diskBytesPerSecond: disk, networkBytesPerSecond: nil,
            configuration: RecorderConfiguration())
    }
    func testHumanInteractionTakesPrecedenceOverBackgroundLoad() {
        XCTAssertEqual(classify(idle: 10, cpu: 0.8), .userActive)
    }
    func testLockedAndAwaySessionsCannotCountAsHumanActive() {
        XCTAssertEqual(classify(idle: 1, locked: true, cpu: 0.8), .backgroundBusy)
        XCTAssertEqual(classify(idle: 1, console: false), .idle)
    }
    func testGPUAndDiskWorkRemainBusyWithLowCPU() {
        XCTAssertEqual(classify(idle: 600, gpu: 80), .backgroundBusy)
        XCTAssertEqual(classify(idle: 600, disk: 10_000_000), .backgroundBusy)
    }
    func testMissingSignalsAreUnknownRatherThanIdle() {
        XCTAssertEqual(classify(idle: nil, cpu: 0.8), .unknown)
        XCTAssertEqual(classify(idle: 600, cpu: nil), .unknown)
        XCTAssertEqual(classify(idle: 600), .idle)
    }
    func testSleepLongGapsAndClockChangesDoNotBecomeCoveredTime() {
        XCTAssertNil(
            RecorderClock.coveredSeconds(
                previousWall: nil, previousMonotonic: nil, wall: 10, monotonic: 10, interval: 10))
        XCTAssertEqual(
            RecorderClock.coveredSeconds(
                previousWall: 10, previousMonotonic: 10, wall: 20, monotonic: 20, interval: 10), 10)
        XCTAssertNil(
            RecorderClock.coveredSeconds(
                previousWall: 10, previousMonotonic: 10, wall: 1000, monotonic: 20, interval: 10))
        XCTAssertNil(
            RecorderClock.coveredSeconds(
                previousWall: 10, previousMonotonic: 10, wall: 1000, monotonic: 1000, interval: 10))
        XCTAssertNil(
            RecorderClock.coveredSeconds(
                previousWall: 10, previousMonotonic: 10, wall: 5, monotonic: 20, interval: 10))
    }
    func testInvalidConfigurationAndQueryWindowAreRejected() {
        var config = RecorderConfiguration()
        config.interval = .nan
        XCTAssertThrowsError(try config.validate())
        config = RecorderConfiguration()
        config.processInterval = 1
        XCTAssertThrowsError(try config.validate())
        XCTAssertThrowsError(try QueryWindow(from: 20, to: 10))
        XCTAssertThrowsError(try QueryWindow(from: .nan, to: 10))
    }
}
