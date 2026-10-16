import Foundation
import GRDB
import MacPerfMonitorCore
import XCTest

@testable import RecorderKit

final class RecorderTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private var url: URL { directory.appendingPathComponent("history.sqlite") }

    private func sample(
        at time: Double, level: PressureLevel = .normal,
        valid: Bool = true, activity: ActivityKind = .userActive
    ) -> RecordedSnapshot {
        var system = SystemSample(
            timestamp: Date(timeIntervalSince1970: time), totalRAM: 16 << 30,
            free: 1 << 30, active: 4 << 30, inactive: 2 << 30, wired: 2 << 30, speculative: 0,
            compressed: 1 << 30, appMemory: 4 << 30, cachedFiles: 1 << 30, swapTotal: 8 << 30,
            swapUsed: 2 << 30, pressureLevel: level, pressurePercent: 0,
            pageIns: 0, pageOuts: 0, compressions: 0, decompressions: 0, cpuLoad: 0.25)
        system.pressureSampleValid = valid
        system.vmSampleValid = true
        system.swapSampleValid = true
        return RecordedSnapshot(
            system: system, cpu: .zero, gpu: nil, battery: nil, network: nil, disk: nil,
            activitySignals: ActivitySignals(idleSeconds: 10, locked: false), activity: activity,
            processSampleTime: nil, unreadableProcessCount: 3, processCount: 5)
    }
    private func number(_ row: [String: Any], _ key: String) -> Double {
        (row[key] as? NSNumber)?.doubleValue ?? .nan
    }

    func testNativeLevelIsIndependentOfCustomIndexAndInvalidIsNull() throws {
        let store = try RecorderStore(url: url, configuration: RecorderConfiguration())
        try store.append(sample(at: 10, level: .critical), coveredSeconds: 10, processes: nil)
        try store.append(sample(at: 20, valid: false), coveredSeconds: 10, processes: nil)
        let result = try RecorderQuery(url: url).query(
            "SELECT pressure_level FROM recorder_samples ORDER BY timestamp")
        XCTAssertEqual((result.rows[0][0] as? NSNumber)?.intValue, 4)
        XCTAssertTrue(result.rows[1][0] is NSNull)
    }

    func testWeightedSummaryClipsIntervalsAndDoesNotCountGaps() throws {
        let store = try RecorderStore(url: url, configuration: RecorderConfiguration())
        try store.append(sample(at: 20), coveredSeconds: 10, processes: nil)
        try store.append(sample(at: 50, level: .warning), coveredSeconds: 30, processes: nil)
        try store.append(sample(at: 100, level: .critical), coveredSeconds: 0, processes: nil)
        let summary = try RecorderQuery(url: url).summary(window: QueryWindow(from: 15, to: 35))
        XCTAssertEqual(summary["selected_recorded_seconds"] as? Double, 20)
        let table = try XCTUnwrap(summary["activities"] as? [String: Any])
        let rows = try XCTUnwrap(table["rows"] as? [[String: Any]])
        XCTAssertEqual(number(rows[0], "normal_seconds"), 5, accuracy: 0.0001)
        XCTAssertEqual(number(rows[0], "warning_seconds"), 15, accuracy: 0.0001)
        XCTAssertEqual(number(rows[0], "warning_percent"), 75, accuracy: 0.0001)
        let all = try RecorderQuery(url: url).summary(window: QueryWindow(from: 0, to: 110))
        XCTAssertEqual(all["selected_recorded_seconds"] as? Double, 40)
        XCTAssertEqual(all["unrecorded_seconds"] as? Double, 70)
    }

    func testSummarySeparatesActivityAndUnknownPressure() throws {
        let store = try RecorderStore(url: url, configuration: RecorderConfiguration())
        try store.append(sample(at: 10, activity: .userActive), coveredSeconds: 10, processes: nil)
        try store.append(
            sample(at: 20, level: .critical, activity: .backgroundBusy), coveredSeconds: 10,
            processes: nil)
        try store.append(
            sample(at: 30, valid: false, activity: .idle), coveredSeconds: 10, processes: nil)
        let query = try RecorderQuery(url: url)
        let result = try query.summary(window: QueryWindow(from: 0, to: 30), activity: .idle)
        let table = try XCTUnwrap(result["activities"] as? [String: Any])
        let row = try XCTUnwrap((table["rows"] as? [[String: Any]])?.first)
        XCTAssertEqual(number(row, "unknown_pressure_seconds"), 10)
        XCTAssertEqual(number(row, "unknown_pressure_percent"), 100)
        XCTAssertTrue(row["mean_cpu_percent_of_machine"] is NSNull)
    }

    func testQueryCannotCreateOrMutateHistoryAndMakesTruncationExplicit() throws {
        XCTAssertThrowsError(try RecorderQuery(url: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let store = try RecorderStore(url: url, configuration: RecorderConfiguration())
        try store.append(sample(at: 10), coveredSeconds: 10, processes: nil)
        try store.append(sample(at: 20), coveredSeconds: 10, processes: nil)
        let query = try RecorderQuery(url: url)
        for sql in [
            "DELETE FROM recorder_samples", "ATTACH DATABASE '/tmp/no' AS x",
            "PRAGMA user_version=10", "SELECT 1; DELETE FROM recorder_samples",
        ] {
            XCTAssertThrowsError(try query.query(sql))
        }
        let result = try query.query("SELECT * FROM recorder_samples", limit: 1)
        XCTAssertTrue(result.truncated)
        XCTAssertThrowsError(try result.csv())
        XCTAssertEqual(
            try query.query("SELECT COUNT(*) FROM recorder_samples").rows.first?.first as? Int64, 2)
    }

    func testSecondWriterIsRejectedButReadersRemainUsable() throws {
        let store = try RecorderStore(url: url, configuration: RecorderConfiguration())
        XCTAssertThrowsError(try RecorderStore(url: url, configuration: RecorderConfiguration()))
        try store.append(sample(at: 10), coveredSeconds: 10, processes: nil)
        XCTAssertEqual(
            try RecorderQuery(url: url).query("SELECT COUNT(*) FROM recorder_samples").rows.count, 1
        )
    }

    func testEmptySummaryRetainsColumnsAndReportsNoCoverage() throws {
        let store = try RecorderStore(url: url, configuration: RecorderConfiguration())
        let query = try RecorderQuery(url: url)
        let result = try query.summary(window: QueryWindow(from: 0, to: 100))
        XCTAssertEqual(result["selected_recorded_seconds"] as? Double, 0)
        XCTAssertEqual(result["unrecorded_seconds"] as? Double, 100)
        let activities = try XCTUnwrap(result["activities"] as? [String: Any])
        XCTAssertTrue((activities["columns"] as? [String])?.contains("covered_seconds") == true)
        XCTAssertEqual((activities["rows"] as? [[String: Any]])?.count, 0)
        try store.append(sample(at: 10), coveredSeconds: 10, processes: nil)
        let absent = try query.summary(window: QueryWindow(from: 0, to: 100), activity: .idle)
        XCTAssertEqual(absent["selected_recorded_seconds"] as? Double, 0)
    }

    func testDuplicateSQLColumnsAreRejectedWithoutCrashingJSON() throws {
        let store = try RecorderStore(url: url, configuration: RecorderConfiguration())
        try store.append(sample(at: 10), coveredSeconds: 10, processes: nil)
        let query = try RecorderQuery(url: url)
        XCTAssertThrowsError(try query.query("SELECT 1 AS value, 2 AS value"))
        XCTAssertEqual(try query.query("SELECT 1 AS first, 2 AS second").rows.count, 1)
    }

    func testRetentionAndFinishPreserveCoverageAndEndState() throws {
        var config = RecorderConfiguration()
        config.retentionDays = 1
        let store = try RecorderStore(
            url: url, configuration: config, now: Date(timeIntervalSince1970: 100000))
        try store.append(sample(at: 1), coveredSeconds: 1, processes: nil)
        try store.append(sample(at: 100000), coveredSeconds: 10, processes: nil)
        try store.maintain(configuration: config, now: Date(timeIntervalSince1970: 100000))
        try store.finish(reason: "test_complete", now: Date(timeIntervalSince1970: 100001))
        let status = try RecorderQuery(url: url).status(now: Date(timeIntervalSince1970: 100002))
        XCTAssertEqual(status["recording_recently"] as? Bool, false)
        XCTAssertEqual(
            try RecorderQuery(url: url).query("SELECT COUNT(*) FROM recorder_samples").rows[0][0]
                as? Int64, 1)
    }

    func testExportStreamsAllRowsAndRedactsHardwareSerials() throws {
        let store = try RecorderStore(url: url, configuration: RecorderConfiguration())
        try store.append(sample(at: 10), coveredSeconds: 10, processes: nil)
        try store.append(sample(at: 20), coveredSeconds: 10, processes: nil)
        let outputURL = directory.appendingPathComponent("export.jsonl")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let count = try RecorderQuery(url: url).export(
            window: QueryWindow(from: 0, to: 30), format: "jsonl", output: output)
        try output.close()
        XCTAssertEqual(count, 2)
        let lines = try String(contentsOf: outputURL, encoding: .utf8).split(separator: "\n")
        let row = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertNotNil(row["snapshot"])
        let redacted = try RecorderStore.redactIdentifiers(
            "{\"battery\":{\"serial\":\"private\",\"power\":3}}")
        XCTAssertFalse(redacted.contains("private"))
        XCTAssertTrue(redacted.contains("power"))
    }
    private func process(at time: Double, memoryMB: UInt64, readable: Bool = true) -> ProcessSample
    {
        let bytes = memoryMB * 1024 * 1024
        return ProcessSample(
            timestamp: Date(timeIntervalSince1970: time), pid: 12345, ppid: 1,
            name: "Fixture", executablePath: "/Applications/Fixture.app/Contents/MacOS/Fixture",
            bundleID: "test.fixture", physFootprint: bytes, residentSize: bytes, virtualSize: bytes,
            lifetimeMaxFootprint: bytes, cpuPercent: 25, cpuTimeUser: 0, cpuTimeSystem: 0,
            threadCount: 1, fdTotal: 1, fdVnode: 1, fdSocket: 0, fdPipe: 0, fdOther: 0,
            diskBytesRead: 0, diskBytesWritten: 0, isTranslated: false, architecture: .arm64,
            startTime: Date(timeIntervalSince1970: 500), uid: 501, dataSource: .directUserRead,
            footprintReadable: readable)
    }

    func testProcessQueryWeightsPartialMinutesByActualCoveredSeconds() throws {
        let store = try RecorderStore(url: url, configuration: RecorderConfiguration())
        for (time, memory) in [(1000.0, UInt64(100)), (1030.0, 200), (1060.0, 300)] {
            try store.samples.insert(
                sample(at: time).system, processes: [process(at: time, memoryMB: memory)])
        }
        try store.maintain(
            configuration: RecorderConfiguration(), now: Date(timeIntervalSince1970: 1141))
        let result = try RecorderQuery(url: url).processes(window: QueryWindow(from: 0, to: 1200))
        let rows = try XCTUnwrap(result.jsonObject()["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(number(rows[0], "mean_memory_mb"), 200, accuracy: 0.001)
        XCTAssertEqual(number(rows[0], "peak_memory_mb"), 300)
    }

    func testUnreadableProcessMemoryIsNotReportedAsZero() throws {
        let store = try RecorderStore(url: url, configuration: RecorderConfiguration())
        try store.samples.insert(
            sample(at: 1000).system, processes: [process(at: 1000, memoryMB: 0, readable: false)])
        try store.maintain(
            configuration: RecorderConfiguration(), now: Date(timeIntervalSince1970: 1081))
        let result = try RecorderQuery(url: url).processes(window: QueryWindow(from: 0, to: 1200))
        let rows = try XCTUnwrap(result.jsonObject()["rows"] as? [[String: Any]])
        XCTAssertTrue(rows[0]["mean_memory_mb"] is NSNull)
        XCTAssertTrue(rows[0]["peak_memory_mb"] is NSNull)
    }

    func testDashboardSplitsClippedIntervalsAndKeepsNativePressureSeparate() throws {
        let store = try RecorderStore(url: url, configuration: RecorderConfiguration())
        var first = sample(at: 20, level: .critical)
        first.system.pressurePercent = 12
        var second = sample(at: 50, level: .warning)
        second.system.appMemory = 8 << 30
        try store.append(first, coveredSeconds: 20, processes: nil)
        try store.append(second, coveredSeconds: 30, processes: nil)
        let query = try RecorderQuery(url: url)
        let data = try query.dashboard(window: QueryWindow(from: 15, to: 35), bucketCount: 12)
        XCTAssertEqual(data.selectedSeconds, 20, accuracy: 0.0001)
        XCTAssertEqual(data.pressureSeconds[4], 5)
        XCTAssertEqual(data.pressureSeconds[2], 15)
        XCTAssertEqual(try XCTUnwrap(data.means[.appMemory]).mean, 7, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(data.means[.appMemory]).minimum, 4)
        XCTAssertEqual(try XCTUnwrap(data.means[.appMemory]).maximum, 8)
        XCTAssertEqual(try XCTUnwrap(data.means[.pressureIndex]).mean, 3, accuracy: 0.0001)
        XCTAssertNil(data.means[.cpu])
        XCTAssertNil(data.means[.download])
        XCTAssertEqual(data.buckets.count, 12)
        XCTAssertEqual(data.buckets.reduce(0) { $0 + $1.seconds }, 20, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(data.latest).values[.free], 1)
    }

    func testDashboardFiltersAllPanelsAndDoesNotBridgeExcludedOrMissingTime() throws {
        let store = try RecorderStore(url: url, configuration: RecorderConfiguration())
        try store.append(sample(at: 30), coveredSeconds: 10, processes: nil)
        try store.append(
            sample(at: 40, activity: .backgroundBusy), coveredSeconds: 10, processes: nil)
        try store.append(sample(at: 50), coveredSeconds: 10, processes: nil)
        try store.append(sample(at: 120, valid: false), coveredSeconds: 10, processes: nil)
        try store.append(sample(at: 1000, activity: .idle), coveredSeconds: 0, processes: nil)
        let query = try RecorderQuery(url: url)
        let data = try query.dashboard(
            window: QueryWindow(from: 0, to: 1200), activity: .userActive, bucketCount: 12)
        XCTAssertEqual(data.recordedSeconds, 40)
        XCTAssertEqual(data.unrecordedSeconds, 1160)
        XCTAssertEqual(data.selectedSeconds, 30)
        XCTAssertEqual(data.activitySeconds[.backgroundBusy], 10)
        XCTAssertEqual(data.pressureSeconds[0], 10)
        XCTAssertEqual(data.buckets.count, 2)
        XCTAssertNotEqual(data.buckets[0].segment, data.buckets[1].segment)
        XCTAssertNil(data.buckets[1].values[.pressureIndex])
        let absent = try query.dashboard(window: QueryWindow(from: 0, to: 1200), activity: .idle)
        XCTAssertEqual(absent.selectedSeconds, 0)
        XCTAssertEqual(absent.recordedSeconds, 40)
        XCTAssertNil(absent.latest)
        XCTAssertTrue(absent.topCPU.isEmpty)
        XCTAssertThrowsError(try query.dashboard(window: QueryWindow(from: 0, to: 8 * 86400)))
    }

    func testDashboardReaderLeavesSchemaHistoryAndConcurrentWriterIntact() throws {
        let store = try RecorderStore(url: url, configuration: RecorderConfiguration())
        let query = try RecorderQuery(url: url)
        let schema = try query.query("SELECT name,sql FROM sqlite_master ORDER BY name").csv()
        let empty = try query.dashboard(window: QueryWindow(from: 0, to: 60))
        XCTAssertEqual(empty.unrecordedSeconds, 60)
        try store.append(sample(at: 10), coveredSeconds: 10, processes: nil)
        _ = try query.dashboard(window: QueryWindow(from: 0, to: 60))
        XCTAssertThrowsError(
            try query.pool.write { db in
                try db.execute(sql: "DELETE FROM recorder_samples")
            })
        try store.append(sample(at: 20), coveredSeconds: 10, processes: nil)
        let result = try query.dashboard(window: QueryWindow(from: 0, to: 60))
        XCTAssertEqual(result.selectedSeconds, 20)
        XCTAssertEqual(
            try query.query("SELECT name,sql FROM sqlite_master ORDER BY name").csv(), schema)
        XCTAssertEqual(
            try query.query("SELECT COUNT(*) AS n FROM recorder_runs").rows[0][0] as? Int64, 1)
        XCTAssertEqual(
            try query.query("SELECT MIN(timestamp) AS first FROM recorder_samples").rows[0][0]
                as? Double, 10)
    }

    func testDashboardProcessRankingsRespectActivityOverlap() throws {
        let store = try RecorderStore(url: url, configuration: RecorderConfiguration())
        try store.append(sample(at: 90), coveredSeconds: 30, processes: nil)
        try store.append(sample(at: 120, activity: .idle), coveredSeconds: 30, processes: nil)
        try store.pool.write { db in
            try db.execute(
                sql:
                    "INSERT INTO processes (pid,name,executable_path,bundle_id,start_time,uid,first_seen,last_seen,is_translated,architecture) VALUES (42,'Fixture','/tmp/Fixture',NULL,1,501,60,180,0,'arm64')"
            )
            let id = db.lastInsertedRowID
            // One process exists only in the selected minute, another only in an excluded minute.
            try db.execute(
                sql:
                    "INSERT INTO process_minute (bucket,process_id,footprint_min,footprint_avg,footprint_max,cpu_avg,samples) VALUES (60,?,104857600,104857600,104857600,20,60)",
                arguments: [id])
            try db.execute(
                sql:
                    "INSERT INTO processes (pid,name,executable_path,bundle_id,start_time,uid,first_seen,last_seen,is_translated,architecture) VALUES (43,'Excluded','/tmp/Excluded',NULL,1,501,180,240,0,'arm64')"
            )
            let excluded = db.lastInsertedRowID
            try db.execute(
                sql:
                    "INSERT INTO process_minute (bucket,process_id,footprint_min,footprint_avg,footprint_max,cpu_avg,samples) VALUES (180,?,104857600,104857600,104857600,80,60)",
                arguments: [excluded])
        }
        let data = try RecorderQuery(url: url).dashboard(
            window: QueryWindow(from: 60, to: 240), activity: .userActive)
        XCTAssertEqual(data.topCPU.map(\.name), ["Fixture"])
        XCTAssertEqual(data.topMemory.first?.meanMemoryMB, 100)
        XCTAssertNil(data.topDisk.first)  // No earlier counter to calculate a rate.
    }

}
