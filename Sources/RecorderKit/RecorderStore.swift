import Darwin
import Foundation
import GRDB
import MacPerfMonitorCore

public struct RecordedSnapshot: Codable {
    public var system: SystemSample
    public var cpu: CPUSample
    public var gpu: GPUSample?
    public var battery: BatterySample?
    public var network: NetworkSample?
    public var disk: DiskSample?
    public var activitySignals: ActivitySignals
    public var activity: ActivityKind
    public var processSampleTime: Date?
    public var unreadableProcessCount: Int
    public var processCount: Int
    public var metricAvailability: [String: String] = [:]
}

public final class RecorderStore {
    public let samples: SampleStore
    public let pool: DatabasePool
    private var lockFD: Int32 = -1
    public let runID: String
    public let url: URL

    public init(url: URL, configuration: RecorderConfiguration, now: Date = Date()) throws {
        try configuration.validate()
        self.url = url
        self.runID = UUID().uuidString
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(url.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw RecorderError.message("Cannot create recorder lock.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw RecorderError.message("Another recorder already owns this database.")
        }
        lockFD = descriptor
        do {
            pool = try MacPerfMonitorDatabase.makePool(url: url)
            samples = SampleStore(pool: pool)
            try pool.write { db in
                try db.execute(
                    sql: """
                        CREATE TABLE IF NOT EXISTS recorder_runs (
                            id TEXT PRIMARY KEY, started_at REAL NOT NULL, ended_at REAL,
                            last_sample_at REAL, configuration_json TEXT NOT NULL,
                            stop_reason TEXT, schema_version INTEGER NOT NULL DEFAULT 1
                        );
                        CREATE TABLE IF NOT EXISTS recorder_samples (
                            timestamp REAL PRIMARY KEY, run_id TEXT NOT NULL,
                            interval_start REAL NOT NULL, covered_seconds REAL NOT NULL,
                            activity TEXT NOT NULL, pressure_level INTEGER,
                            cpu_fraction REAL, gpu_percent REAL, swap_used INTEGER,
                            memory_used INTEGER, compressed INTEGER,
                            network_bytes_per_second REAL, disk_bytes_per_second REAL,
                            idle_seconds REAL, locked INTEGER, unreadable_processes INTEGER NOT NULL,
                            snapshot_json TEXT NOT NULL
                        );
                        CREATE INDEX IF NOT EXISTS recorder_samples_activity_time
                            ON recorder_samples(activity, timestamp);
                        """)
                let config = try Self.encode(configuration)
                try db.execute(
                    sql:
                        "INSERT INTO recorder_runs(id, started_at, configuration_json) VALUES (?,?,?)",
                    arguments: [runID, now.timeIntervalSince1970, config])
            }
            // WAL and the DB must not expose process names to other local users.
            for suffix in ["", "-wal", "-shm"] {
                if FileManager.default.fileExists(atPath: url.path + suffix) {
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o600], ofItemAtPath: url.path + suffix)
                }
            }
        } catch {
            flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            lockFD = -1
            throw error
        }
    }

    deinit {
        if lockFD >= 0 {
            flock(lockFD, LOCK_UN)
            Darwin.close(lockFD)
        }
    }

    public func append(
        _ snapshot: RecordedSnapshot, coveredSeconds: Double,
        processes: [ProcessSample]?
    ) throws {
        let system = snapshot.system
        let time = system.timestamp.timeIntervalSince1970
        guard time.isFinite, coveredSeconds.isFinite, coveredSeconds >= 0 else {
            throw RecorderError.message("Invalid sample timestamp or duration.")
        }
        if let processes {
            try samples.insertChanged(
                system, processes: processes, bucket: 60, battery: snapshot.battery)
            samples.pruneProcessIDCache(keeping: Set(processes.map(\.id)))
            samples.touchLastSeen(keeping: Set(processes.map(\.id)), now: system.timestamp)
        } else {
            try samples.insert(systemSample: system, battery: snapshot.battery)
        }
        let raw = try Self.encode(snapshot)
        let data = try Self.redactIdentifiers(raw)
        let hasBaseline = coveredSeconds > 0
        let nativeLevel: Int? =
            system.pressureSampleValid == true ? system.pressureLevel.rawValue : nil
        let vmValid = system.vmSampleValid == true
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO recorder_samples
                        (timestamp,run_id,interval_start,covered_seconds,activity,pressure_level,
                        cpu_fraction,gpu_percent,swap_used,memory_used,compressed,
                        network_bytes_per_second,disk_bytes_per_second,idle_seconds,locked,
                        unreadable_processes,snapshot_json)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """,
                arguments: [
                    time, runID, time - coveredSeconds, coveredSeconds, snapshot.activity.rawValue,
                    nativeLevel, hasBaseline && !snapshot.cpu.cores.isEmpty ? system.cpuLoad : nil,
                    hasBaseline ? system.gpuUtilization : nil,
                    system.swapSampleValid == true ? Int64(clamping: system.swapUsed) : nil,
                    vmValid
                        ? Int64(clamping: system.appMemory + system.wired + system.compressed)
                        : nil,
                    vmValid ? Int64(clamping: system.compressed) : nil,
                    hasBaseline && snapshot.network != nil
                        ? system.networkInBytesPerSec + system.networkOutBytesPerSec : nil,
                    hasBaseline && snapshot.disk != nil
                        ? system.diskReadBytesPerSec + system.diskWriteBytesPerSec : nil,
                    snapshot.activitySignals.idleSeconds, snapshot.activitySignals.locked,
                    snapshot.unreadableProcessCount, data,
                ])
            try db.execute(
                sql: "UPDATE recorder_runs SET last_sample_at=? WHERE id=?",
                arguments: [time, runID])
        }
    }

    public func maintain(configuration: RecorderConfiguration, now: Date = Date()) throws {
        let cutoff = now.timeIntervalSince1970 - configuration.retentionDays * 86400
        try pool.write { db in
            try db.execute(
                sql: "DELETE FROM recorder_samples WHERE timestamp < ?", arguments: [cutoff])
            try db.execute(
                sql: "DELETE FROM recorder_runs WHERE ended_at < ? AND id != ?",
                arguments: [cutoff, runID])
        }
        try Retention.run(
            pool, now: now,
            policy: RetentionPolicy(
                rawWindow: 2 * 3600, minuteWindow: configuration.retentionDays * 86400,
                hourWindow: 90 * 86400))
        // Retain native-state history ahead of disposable fine process detail.
        let cap = configuration.maxDatabaseMB * 1024 * 1024
        let tiers = [
            ("process_samples", "timestamp"), ("system_samples", "timestamp"),
            ("process_minute", "bucket"), ("process_hour", "bucket"),
            ("system_minute", "bucket"), ("system_hour", "bucket"),
            ("recorder_samples", "timestamp"),
        ]
        for _ in 0..<20 {
            let withinBudget = try pool.read { db in
                let pages =
                    (try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0)
                    - (try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0)
                return pages * (try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 4096) <= cap
            }
            if withinBudget { break }
            let deleted = try pool.write { db -> Bool in
                for (table, column) in tiers {
                    try db.execute(
                        sql:
                            "DELETE FROM \(table) WHERE rowid IN (SELECT rowid FROM \(table) ORDER BY \(column) LIMIT 10000)"
                    )
                    if db.changesCount > 0 {
                        try db.execute(sql: "PRAGMA incremental_vacuum(2000)")
                        return true
                    }
                }
                return false
            }
            if !deleted { break }
        }
        samples.checkpoint()
    }

    public func finish(reason: String, now: Date = Date()) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE recorder_runs SET ended_at=?,stop_reason=? WHERE id=?",
                arguments: [now.timeIntervalSince1970, reason, runID])
        }
        samples.checkpoint()
    }

    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func redactIdentifiers(_ string: String) throws -> String {
        func clean(_ value: Any) -> Any {
            if let object = value as? [String: Any] {
                return object.filter { !$0.key.lowercased().contains("serial") }.mapValues(clean)
            }
            if let array = value as? [Any] { return array.map(clean) }
            return value
        }
        let value = try JSONSerialization.jsonObject(with: Data(string.utf8))
        return String(
            decoding: try JSONSerialization.data(
                withJSONObject: clean(value), options: [.sortedKeys]), as: UTF8.self)
    }
}
