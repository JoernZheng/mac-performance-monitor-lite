import GRDB
import XCTest

@testable import MacPerfMonitorCore

final class LeakBoardTests: XCTestCase {
    private var tempURL: URL!
    private var store: SampleStore!

    private let startTime = Date(timeIntervalSince1970: 1_000_000)
    private let mb: UInt64 = 1024 * 1024

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macperfmonitor-leakboard-\(UUID().uuidString).sqlite")
        store = try SampleStore(url: tempURL)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("shm"))
    }

    private func insertTick(_ timestamp: Date, _ processes: [ProcessSample]) throws {
        try store.insert(
            Sampler.Snapshot(
                system: Make.system(timestamp: timestamp),
                processes: processes,
                unreadableProcessCount: 0))
    }

    /// A deliberately leaky process must be flagged while a stable one and a
    /// too-short-lived one are not. This is the M6 acceptance criterion.
    func testLeakBoardFlagsLeakyProcessOnly() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let spacing = 20.0
        let count = 70  // 70 samples over 1380 s (23 min) — past the 20-minute duration floor

        for i in 0..<count {
            let ts = base.addingTimeInterval(Double(i) * spacing)
            // Leaky: +4 MB every step (≈200 KB/s), perfectly linear.
            let leaky = Make.process(
                timestamp: ts, pid: 1000, startTime: startTime,
                name: "Leaky", footprint: (100 + UInt64(i) * 4) * mb)
            // Stable: flat, never flagged.
            let stable = Make.process(
                timestamp: ts, pid: 2000, startTime: startTime,
                name: "Stable", footprint: 100 * mb)
            var processes = [leaky, stable]
            // Short-lived fast riser: present for only the first 5 ticks, so it
            // never reaches the minimum sample count / duration.
            if i < 5 {
                processes.append(
                    Make.process(
                        timestamp: ts, pid: 4000, startTime: startTime,
                        name: "Brief", footprint: (200 + UInt64(i) * 10) * mb))
            }
            try insertTick(ts, processes)
        }

        let now = base.addingTimeInterval(Double(count - 1) * spacing)
        let board = try store.leakBoard(now: now)

        XCTAssertEqual(board.count, 1, "only the leaky process should be flagged")
        let flagged = try XCTUnwrap(board.first)
        XCTAssertEqual(flagged.identity.pid, 1000)
        XCTAssertEqual(flagged.name, "Leaky")
        XCTAssertFalse(
            board.contains { $0.identity.pid == 2000 }, "stable process must not be flagged")
        XCTAssertFalse(
            board.contains { $0.identity.pid == 4000 }, "short-lived process must not be flagged")

        // The finding should reflect the synthetic ~200 KB/s slope and high fit.
        XCTAssertGreaterThan(flagged.finding.slopeBytesPerSecond, 8 * 1024)
        XCTAssertEqual(
            flagged.finding.slopeBytesPerSecond, 4 * Double(mb) / spacing, accuracy: 5_000)
        XCTAssertGreaterThan(flagged.finding.rSquared, 0.99)
        XCTAssertGreaterThan(flagged.finding.confidence, 0)
        XCTAssertEqual(flagged.latestFootprint, (100 + UInt64(count - 1) * 4) * mb)
    }

    func testLeakBoardSortsMostConfidentFirst() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let spacing = 20.0
        let count = 70  // ~23 min span — past the 20-minute duration floor

        for i in 0..<count {
            let ts = base.addingTimeInterval(Double(i) * spacing)
            // Clean linear leak (high R²).
            let clean = Make.process(
                timestamp: ts, pid: 1000, startTime: startTime,
                name: "Clean", footprint: (100 + UInt64(i) * 4) * mb)
            // Noisy leak: same trend with a small alternating wobble (lower R²).
            let wobble: UInt64 = (i % 2 == 0) ? 0 : 6
            let noisy = Make.process(
                timestamp: ts, pid: 3000, startTime: startTime,
                name: "Noisy", footprint: (100 + UInt64(i) * 4 + wobble) * mb)
            try insertTick(ts, [clean, noisy])
        }

        let now = base.addingTimeInterval(Double(count - 1) * spacing)
        let board = try store.leakBoard(now: now)

        XCTAssertEqual(board.count, 2)
        XCTAssertEqual(board.first?.identity.pid, 1000, "the cleaner trend should rank first")
        XCTAssertGreaterThanOrEqual(board[0].finding.confidence, board[1].finding.confidence)
    }

    func testLeakBoardEmptyWithoutData() throws {
        let board = try store.leakBoard(now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(board.isEmpty)
    }

    private func seedGrowth(count: Int = 81, processes: Int = 1) throws -> Date {
        let base = Date(timeIntervalSince1970: 1_700_000_040)
        for i in 0..<count {
            let ts = base.addingTimeInterval(Double(i) * 30)
            try insertTick(
                ts,
                (0..<processes).map { index in
                    Make.process(
                        timestamp: ts, pid: Int32(1000 + index), startTime: startTime,
                        name: "Growth\(index)", footprint: (100 + UInt64(i) * 4) * mb)
                })
        }
        return base.addingTimeInterval(Double(count - 1) * 30)
    }

    func testLiveIdentityFilteringMatchesFullScanAndRejectsReusedPID() throws {
        let now = try seedGrowth(processes: 40)
        let all = try store.leakBoard(now: now)
        XCTAssertEqual(all.count, 40)
        let identity = ProcessIdentity(pid: 1015, startTime: startTime)
        let live = try store.leakBoard(now: now, liveIdentities: [identity])
        XCTAssertEqual(live, all.filter { $0.identity == identity })
        XCTAssertTrue(try store.leakBoard(now: now, liveIdentities: []).isEmpty)
        XCTAssertTrue(
            try store.leakBoard(
                now: now,
                liveIdentities: [.init(pid: 1015, startTime: now)]
            ).isEmpty)
    }

    func testCompletedMinuteTrendUsesExactLatestRawFootprint() throws {
        let now = try seedGrowth()
        try Retention.run(store.databasePool, now: now)
        let board = try store.leakBoard(now: now)
        let row = try XCTUnwrap(board.first)
        XCTAssertGreaterThan(row.finding.durationSeconds, 30 * 60)
        XCTAssertEqual(row.latestFootprint, 420 * mb)
        try store.databasePool.write { db in
            try db.execute(sql: "DELETE FROM process_samples")
        }
        let minuteOnly = try store.leakBoard(now: now)
        XCTAssertEqual(minuteOnly.first?.finding, row.finding)
        XCTAssertNotEqual(minuteOnly.first?.latestFootprint, row.latestFootprint)
    }

    func testRejectedLongTrendCannotFallBackToRisingRawTail() throws {
        let now = try seedGrowth()
        XCTAssertEqual(try store.leakBoard(now: now).count, 1)
        try Retention.run(store.databasePool, now: now)
        try store.databasePool.write { db in
            try db.execute(sql: "UPDATE process_minute SET footprint_avg = 104857600")
        }
        XCTAssertTrue(try store.leakBoard(now: now).isEmpty)
        try store.databasePool.write { db in
            try db.execute(
                sql: "DELETE FROM process_minute WHERE bucket < ?",
                arguments: [now.addingTimeInterval(-5 * 60).timeIntervalSince1970])
        }
        XCTAssertEqual(try store.leakBoard(now: now).count, 1)
    }

    func testFreshnessUsesRawBucketMeanAndIgnoresFutureAndUnreadableRows() throws {
        let end = try seedGrowth()
        try insertTick(
            end.addingTimeInterval(20),
            [
                Make.process(
                    timestamp: end.addingTimeInterval(20), pid: 1000,
                    startTime: startTime, footprint: 424 * mb)
            ])
        var config = LeakDetector.Config.default
        config.maximumGap = 120
        XCTAssertEqual(
            try store.leakBoard(config: config, now: end.addingTimeInterval(129)).count, 1)
        XCTAssertTrue(
            try store.leakBoard(config: config, now: end.addingTimeInterval(131)).isEmpty)
        let baseline = try store.leakBoard(now: end.addingTimeInterval(2))
        var unreadable = Make.process(
            timestamp: end.addingTimeInterval(1), pid: 1000, startTime: startTime, footprint: 0)
        unreadable.footprintReadable = false
        try insertTick(end.addingTimeInterval(1), [unreadable])
        XCTAssertEqual(try store.leakBoard(now: end.addingTimeInterval(2)), baseline)
        XCTAssertEqual(baseline.first?.latestFootprint, 420 * mb)
    }

    func testIncompleteMinuteBucketsDoNotExtendTheTrend() throws {
        let now = try seedGrowth(count: 41)
        try Retention.run(store.databasePool, now: now.addingTimeInterval(60))
        let tooShort = try store.leakBoard(now: now.addingTimeInterval(-1))
        XCTAssertTrue(tooShort.isEmpty)
    }

    /// An established slow leak must be flagged from the minute aggregates:
    /// the growth here ended 20 minutes before "now", outside the raw fast
    /// path's window, so only the minute tier can see it.
    func testLeakBoardDoesNotFlagAnEstablishedTrendWithoutFreshEvidence() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let spacing = 60.0
        let count = 80  // 80 minutes of +2 MB/min growth, ~35 KB/s

        for i in 0..<count {
            let ts = base.addingTimeInterval(Double(i) * spacing)
            try insertTick(
                ts,
                [
                    Make.process(
                        timestamp: ts, pid: 1000, startTime: startTime,
                        name: "SlowLeak", footprint: (100 + UInt64(i) * 2) * mb)
                ])
        }

        let now = base.addingTimeInterval(100 * 60)
        try Retention.run(store.databasePool, now: now)

        let board = try store.leakBoard(now: now)
        XCTAssertTrue(board.isEmpty)
    }
}
