import Foundation
import GRDB

public struct QueryTable {
    public var columns: [String]
    public var rows: [[Any]]
    public var truncated: Bool

    public func jsonObject() -> [String: Any] {
        [
            "columns": columns,
            "rows": rows.map { row in
                Dictionary(uniqueKeysWithValues: zip(columns, row))
            }, "truncated": truncated,
        ]
    }
    public func csv() throws -> String {
        guard !truncated else {
            throw RecorderError.message(
                "Result exceeds the row limit. Narrow --from/--to or use export for streaming output."
            )
        }
        return
            ([columns.map(Self.cell).joined(separator: ",")]
            + rows.map { $0.map(Self.cell).joined(separator: ",") }).joined(separator: "\n") + "\n"
    }
    static func cell(_ value: Any) -> String {
        let text = value is NSNull ? "" : String(describing: value)
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

public struct QueryWindow {
    public let from: Double
    public let to: Double
    public init(from: Double, to: Double) throws {
        guard from.isFinite, to.isFinite, from < to else {
            throw RecorderError.message("A finite --from earlier than --to is required.")
        }
        self.from = from
        self.to = to
    }
}

public final class RecorderQuery {
    let pool: DatabasePool
    public init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RecorderError.message("No recorded history at \(url.path). Start record first.")
        }
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(3)
        configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA query_only=ON") }
        pool = try DatabasePool(path: url.path, configuration: configuration)
        let ready = try pool.read { try $0.tableExists("recorder_samples") }
        guard ready else {
            throw RecorderError.message("This is not a Mac Performance Monitor Lite database.")
        }
    }

    public func query(
        _ sql: String, arguments: StatementArguments = StatementArguments(),
        limit: Int = 500, timeout: TimeInterval = 20
    ) throws -> QueryTable {
        guard (1...10000).contains(limit) else {
            throw RecorderError.message("Query limit must be 1...10000.")
        }
        try Self.validateSQL(sql)
        let timer = DispatchWorkItem { [pool] in pool.interrupt() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        defer { timer.cancel() }
        return try pool.read { db in
            let statement = try db.makeStatement(sql: sql)
            guard statement.isReadonly else {
                throw RecorderError.message("Only read-only SQL is supported.")
            }
            let columns = statement.columnNames
            guard Set(columns).count == columns.count else {
                throw RecorderError.message("Query columns need unique names. Use SQL aliases.")
            }
            let cursor = try Row.fetchCursor(statement, arguments: arguments)
            var rows: [[Any]] = []
            var truncated = false
            while let row = try cursor.next() {
                if rows.count == limit {
                    truncated = true
                    break
                }
                rows.append(row.databaseValues.map(Self.object))
            }
            return QueryTable(columns: columns, rows: rows, truncated: truncated)
        }
    }

    public func status(now: Date = Date()) throws -> [String: Any] {
        let runs = try query("SELECT * FROM recorder_runs ORDER BY started_at DESC LIMIT 1")
        let sample = try query(
            """
            SELECT timestamp,activity,pressure_level,covered_seconds,cpu_fraction,gpu_percent,
                swap_used,memory_used,compressed,idle_seconds,locked,unreadable_processes
            FROM recorder_samples ORDER BY timestamp DESC LIMIT 1
            """)
        let coverage = try query(
            "SELECT MIN(timestamp) AS first_sample,MAX(timestamp) AS last_sample,COUNT(*) AS samples,SUM(covered_seconds) AS covered_seconds FROM recorder_samples"
        )
        let last = sample.rows.first?.first as? Double
        let run =
            runs.rows.first.map { Dictionary(uniqueKeysWithValues: zip(runs.columns, $0)) } ?? [:]
        let isStopped = !(run["ended_at"] is NSNull) && run["ended_at"] != nil
        let interval: Double =
            (run["configuration_json"] as? String).flatMap {
                try? JSONDecoder().decode(RecorderConfiguration.self, from: Data($0.utf8)).interval
            } ?? 10
        return [
            "latest_run": run, "latest_sample": sample.jsonObject(),
            "coverage": coverage.jsonObject(),
            "recording_recently": !isStopped
                && (last.map {
                    (0..<max(60, interval * 3)).contains(now.timeIntervalSince1970 - $0)
                } ?? false),
            "freshness_is_not_a_process_liveness_check": true,
        ]
    }

    public func summary(window: QueryWindow, activity: ActivityKind? = nil) throws -> [String: Any]
    {
        let predicate = activity.map { " AND activity='\($0.rawValue)'" } ?? ""
        let table = try query(
            """
            WITH selected AS (
              SELECT *,MAX(0,MIN(timestamp,?)-MAX(interval_start,?)) AS weight
              FROM recorder_samples WHERE timestamp > ? AND timestamp < ?
                AND interval_start < ? AND covered_seconds > 0 \(predicate)
            )
            SELECT activity,COUNT(*) AS samples,SUM(weight) AS covered_seconds,
              SUM(CASE WHEN pressure_level=1 THEN weight ELSE 0 END) AS normal_seconds,
              SUM(CASE WHEN pressure_level=2 THEN weight ELSE 0 END) AS warning_seconds,
              SUM(CASE WHEN pressure_level=4 THEN weight ELSE 0 END) AS critical_seconds,
              SUM(CASE WHEN pressure_level IS NULL THEN weight ELSE 0 END) AS unknown_pressure_seconds,
              SUM(CASE WHEN pressure_level=1 THEN weight ELSE 0 END)/NULLIF(SUM(weight),0)*100 AS normal_percent,
              SUM(CASE WHEN pressure_level=2 THEN weight ELSE 0 END)/NULLIF(SUM(weight),0)*100 AS warning_percent,
              SUM(CASE WHEN pressure_level=4 THEN weight ELSE 0 END)/NULLIF(SUM(weight),0)*100 AS critical_percent,
              SUM(CASE WHEN pressure_level IS NULL THEN weight ELSE 0 END)/NULLIF(SUM(weight),0)*100 AS unknown_pressure_percent,
              SUM(cpu_fraction*weight)/NULLIF(SUM(CASE WHEN cpu_fraction IS NOT NULL THEN weight ELSE 0 END),0)*100 AS mean_cpu_percent_of_machine,
              SUM(gpu_percent*weight)/NULLIF(SUM(CASE WHEN gpu_percent IS NOT NULL THEN weight ELSE 0 END),0) AS mean_gpu_percent,
              SUM(swap_used*weight)/NULLIF(SUM(CASE WHEN swap_used IS NOT NULL THEN weight ELSE 0 END),0)/1073741824.0 AS mean_swap_gib,
              MAX(swap_used)/1073741824.0 AS peak_swap_gib,
              SUM(memory_used*weight)/NULLIF(SUM(CASE WHEN memory_used IS NOT NULL THEN weight ELSE 0 END),0)/1073741824.0 AS mean_used_memory_gib
            FROM selected WHERE weight > 0 GROUP BY activity ORDER BY activity
            """, arguments: [window.to, window.from, window.from, window.to + 750, window.to],
            limit: 10)
        let index = table.columns.firstIndex(of: "covered_seconds")!
        let seconds = table.rows.reduce(0.0) { $0 + (($1[index] as? Double) ?? 0) }
        return [
            "from": window.from, "to": window.to, "requested_seconds": window.to - window.from,
            "selected_recorded_seconds": seconds,
            "unrecorded_seconds": activity == nil
                ? max(0, window.to - window.from - seconds) : NSNull(),
            "activity_is_a_configurable_estimate": true,
            "pressure_source":
                "macOS kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical; null unavailable",
            "duration_precision":
                "Sampled interval estimates; sleep, restart, and long gaps are excluded.",
            "activities": table.jsonObject(),
        ]
    }

    public func processes(window: QueryWindow, limit: Int = 20) throws -> QueryTable {
        try query(
            """
            SELECT process_key,name,app,kind,
              SUM(memory_mb*covered_seconds)/NULLIF(SUM(CASE WHEN memory_mb IS NOT NULL THEN covered_seconds ELSE 0 END),0) AS mean_memory_mb,
              MAX(memory_peak_mb) AS peak_memory_mb,
              SUM(cpu_percent_of_one_core*covered_seconds)/NULLIF(SUM(covered_seconds),0) AS mean_cpu_percent_of_one_core,
              SUM(cpu_share_of_mac_percent*covered_seconds)/NULLIF(SUM(covered_seconds),0) AS mean_cpu_percent_of_machine,
              COUNT(*) AS stored_points
            FROM agent_process_usage WHERE ts >= ? AND ts < ?
            GROUP BY process_key ORDER BY peak_memory_mb DESC LIMIT ?
            """, arguments: [window.from, window.to, limit], limit: limit)
    }

    /// Streams without holding an entire month of detailed snapshots in memory.
    /// The SQLite snapshot is read-only; use JSONL for all nested metric fields.
    public func export(window: QueryWindow, format: String, output: FileHandle) throws -> Int {
        guard ["jsonl", "csv"].contains(format) else {
            throw RecorderError.message("Export format is jsonl or csv.")
        }
        let timer = DispatchWorkItem { [pool] in pool.interrupt() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timer)
        defer { timer.cancel() }
        return try pool.read { db in
            let cursor = try Row.fetchCursor(
                db,
                sql:
                    "SELECT * FROM recorder_samples WHERE timestamp>=? AND timestamp<? ORDER BY timestamp",
                arguments: [window.from, window.to])
            var count = 0
            while let row = try cursor.next() {
                let names = Array(row.columnNames)
                let values = row.databaseValues.map(Self.object)
                if format == "csv" {
                    if count == 0 {
                        try output.write(
                            contentsOf: Data(
                                (names.map(QueryTable.cell).joined(separator: ",") + "\n").utf8))
                    }
                    try output.write(
                        contentsOf: Data(
                            (values.map(QueryTable.cell).joined(separator: ",") + "\n").utf8))
                } else {
                    var object = Dictionary(uniqueKeysWithValues: zip(names, values))
                    if let text = object.removeValue(forKey: "snapshot_json") as? String {
                        object["snapshot"] = try JSONSerialization.jsonObject(with: Data(text.utf8))
                    }
                    var data = try JSONSerialization.data(
                        withJSONObject: object, options: [.sortedKeys])
                    data.append(10)
                    try output.write(contentsOf: data)
                }
                count += 1
            }
            return count
        }
    }

    private static func validateSQL(_ sql: String) throws {
        let clean = sql.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard
            ["select ", "select\n", "with ", "with\n", "explain "].contains(where: clean.hasPrefix),
            !clean.contains(";"),
            !["attach", "detach", "pragma", "load_extension"].contains(where: {
                clean.range(of: "\\b\($0)\\b", options: .regularExpression) != nil
            })
        else {
            throw RecorderError.message(
                "Use one SELECT, WITH, or EXPLAIN statement without semicolons.")
        }
    }

    private static func object(_ value: DatabaseValue) -> Any {
        switch value.storage {
        case .null: return NSNull()
        case .int64(let value): return value
        case .double(let value): return value.isFinite ? value : NSNull()
        case .string(let value): return value
        case .blob(let value): return value.base64EncodedString()
        }
    }
}
