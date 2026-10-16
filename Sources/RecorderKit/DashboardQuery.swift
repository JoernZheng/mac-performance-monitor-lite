import Foundation
import GRDB
import MacPerfMonitorCore

public enum DashboardMetric: String, CaseIterable, Sendable {
    case cpu, gpu, pressureIndex, appMemory, wired, compressed, cached, free, swap
    case download, upload, diskRead, diskWrite, iops, cpuTemperature, gpuTemperature
    case fan, charge, systemPower, gpuPower, anePower

    public var label: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .pressureIndex: return "Custom pressure index"
        case .appMemory: return "App"
        case .wired: return "Wired"
        case .compressed: return "Compressed"
        case .cached: return "Cached files"
        case .free: return "Free pages"
        case .swap: return "Swap"
        case .download: return "Download"
        case .upload: return "Upload"
        case .diskRead: return "Read"
        case .diskWrite: return "Write"
        case .iops: return "IOPS"
        case .cpuTemperature: return "CPU die"
        case .gpuTemperature: return "GPU die"
        case .fan: return "Fan"
        case .charge: return "Battery charge"
        case .systemPower: return "System"
        case .gpuPower: return "GPU power"
        case .anePower: return "ANE power"
        }
    }
}

public struct DashboardValue: Sendable {
    public let mean: Double
    public let minimum: Double
    public let maximum: Double
    public let seconds: Double
}

public struct DashboardBucket: Sendable, Identifiable {
    public let id: Int
    public let start: Double
    public let end: Double
    public let seconds: Double
    public let segment: Int
    public let values: [DashboardMetric: DashboardValue]
    /// Duration of each native pressure state, including unknown (key 0).
    public let pressureSeconds: [Int: Double]
    public var date: Date { Date(timeIntervalSince1970: (start + end) / 2) }
}

public struct DashboardCore: Sendable, Identifiable {
    public let id: Int
    public let kind: String
    public let percent: Double
}

public struct DashboardLatest: Sendable {
    public let timestamp: Double
    public let totalRAM: Double
    public let nativePressure: Int?
    public let values: [DashboardMetric: Double]
    public let cores: [DashboardCore]
    public let thermalState: String?
    public let loadAverage: Double?
}

public struct DashboardProcess: Sendable, Identifiable {
    public let id: Int64
    public let name: String
    public let meanCPU: Double
    public let meanMemoryMB: Double?
    public let meanDiskBytesPerSecond: Double?
}

public struct DashboardData: Sendable {
    public let from: Double
    public let to: Double
    public let bucketSeconds: Double
    public let activitySeconds: [ActivityKind: Double]
    public let selectedSeconds: Double
    public let pressureSeconds: [Int: Double]
    public let means: [DashboardMetric: DashboardValue]
    public let buckets: [DashboardBucket]
    public let latest: DashboardLatest?
    public let topCPU: [DashboardProcess]
    public let topMemory: [DashboardProcess]
    public let topDisk: [DashboardProcess]
    public var recordedSeconds: Double { activitySeconds.values.reduce(0, +) }
    public var unrecordedSeconds: Double { max(0, to - from - recordedSeconds) }
}

private struct WeightedValue {
    var sum = 0.0
    var seconds = 0.0
    var minimum = Double.infinity
    var maximum = -Double.infinity
    mutating func add(_ value: Double, seconds weight: Double) {
        guard value.isFinite else { return }
        sum += value * weight
        seconds += weight
        minimum = min(minimum, value)
        maximum = max(maximum, value)
    }
    var value: DashboardValue {
        DashboardValue(mean: sum / seconds, minimum: minimum, maximum: maximum, seconds: seconds)
    }
}

private struct BucketBuilder {
    var start = Double.infinity
    var end = -Double.infinity
    var seconds = 0.0
    var values: [DashboardMetric: WeightedValue] = [:]
    var pressure: [Int: Double] = [:]
    mutating func add(
        start: Double, end: Double, values sample: [DashboardMetric: Double], pressure level: Int
    ) {
        let weight = end - start
        self.start = min(self.start, start)
        self.end = max(self.end, end)
        seconds += weight
        pressure[level, default: 0] += weight
        for (metric, value) in sample {
            values[metric, default: WeightedValue()].add(value, seconds: weight)
        }
    }
}

// Decode only what the viewer uses, leaving hardware identifiers and nested device lists alone.
private struct DisplaySnapshot: Decodable {
    let system: SystemSample
    let cpu: CPUSample
}

extension RecorderQuery {
    /// A bounded in-memory result, streamed from one read-only SQLite snapshot.
    /// Samples crossing a chart/minute boundary are split by actual interval overlap.
    public func dashboard(
        window: QueryWindow, activity: ActivityKind? = nil, bucketCount: Int = 240
    ) throws -> DashboardData {
        guard (12...1000).contains(bucketCount), window.to - window.from <= 7 * 86400 else {
            throw RecorderError.message(
                "Dashboard supports up to 7 days and 12...1000 chart buckets.")
        }
        let timer = DispatchWorkItem { [pool] in pool.interrupt() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timer)
        defer { timer.cancel() }
        return try pool.read { db in
            let width = max(1, (window.to - window.from) / Double(bucketCount))
            var builders: [Int: BucketBuilder] = [:]
            var totals: [DashboardMetric: WeightedValue] = [:]
            var activities: [ActivityKind: Double] = [:]
            var pressure: [Int: Double] = [:]
            var selected = 0.0
            var latest: DashboardLatest?
            // Selected seconds in each minute also weight the coarser process rollups.
            var selectedMinutes: [Int: Double] = [:]
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let cursor = try Row.fetchCursor(
                db,
                sql: """
                    SELECT * FROM recorder_samples
                    WHERE timestamp > ? AND timestamp < ? AND interval_start < ?
                      AND covered_seconds > 0 ORDER BY timestamp
                    """, arguments: [window.from, window.to + 750, window.to])
            while let row = try cursor.next() {
                try Task.checkCancellation()
                let start = max(window.from, row["interval_start"] as Double)
                let end = min(window.to, row["timestamp"] as Double)
                guard end > start else { continue }
                let kind = ActivityKind(rawValue: row["activity"]) ?? .unknown
                activities[kind, default: 0] += end - start
                guard activity == nil || activity == kind else { continue }
                let snapshot = try decoder.decode(
                    DisplaySnapshot.self, from: Data((row["snapshot_json"] as String).utf8))
                let values = Self.dashboardValues(row: row, sample: snapshot)
                let level: Int? = row["pressure_level"]
                pressure[level ?? 0, default: 0] += end - start
                selected += end - start
                for (metric, value) in values {
                    totals[metric, default: WeightedValue()].add(value, seconds: end - start)
                }
                let firstBucket = max(0, min(bucketCount - 1, Int((start - window.from) / width)))
                let lastBucket = max(
                    firstBucket, min(bucketCount - 1, Int((end - window.from) / width)))
                for index in firstBucket...lastBucket {
                    let clippedStart = max(start, window.from + Double(index) * width)
                    let clippedEnd = min(end, window.from + Double(index + 1) * width)
                    guard clippedEnd > clippedStart else { continue }
                    builders[index, default: BucketBuilder()].add(
                        start: clippedStart, end: clippedEnd, values: values, pressure: level ?? 0)
                }
                var position = start
                while position < end {
                    let minute = Int(floor(position / 60))
                    let boundary = min(end, Double(minute + 1) * 60)
                    selectedMinutes[minute, default: 0] += boundary - position
                    position = boundary
                }
                latest = DashboardLatest(
                    timestamp: row["timestamp"], totalRAM: Double(snapshot.system.totalRAM),
                    nativePressure: level, values: values,
                    cores: (row["cpu_fraction"] as Double?) == nil
                        ? []
                        : snapshot.cpu.cores.map {
                            DashboardCore(
                                id: $0.index, kind: $0.kind.rawValue, percent: $0.usage * 100)
                        }, thermalState: snapshot.system.thermalPressure?.label,
                    loadAverage: (row["cpu_fraction"] as Double?) == nil
                        ? nil : snapshot.system.loadAverage1)
            }
            var buckets: [DashboardBucket] = []
            var segment = 0
            var previous: BucketBuilder?
            for index in builders.keys.sorted() {
                let b = builders[index]!
                // Sub-second wall/monotonic clock jitter is below sampling precision.
                let partial = b.seconds < b.end - b.start - 0.25
                if let p = previous,
                    b.start > p.end + 0.25 || partial || p.seconds < p.end - p.start - 0.25
                {
                    segment += 1
                }
                buckets.append(
                    DashboardBucket(
                        id: index, start: b.start, end: b.end, seconds: b.seconds, segment: segment,
                        values: b.values.mapValues(\.value), pressureSeconds: b.pressure))
                previous = b
            }
            let processes = try Self.dashboardProcesses(
                db, window: window, minutes: selectedMinutes)
            return DashboardData(
                from: window.from, to: window.to, bucketSeconds: width,
                activitySeconds: activities, selectedSeconds: selected, pressureSeconds: pressure,
                means: totals.mapValues(\.value), buckets: buckets, latest: latest,
                topCPU: Array(processes.sorted { $0.meanCPU > $1.meanCPU }.prefix(8)),
                topMemory: Array(
                    processes.filter { $0.meanMemoryMB != nil }.sorted {
                        $0.meanMemoryMB! > $1.meanMemoryMB!
                    }.prefix(8)),
                topDisk: Array(
                    processes.filter { $0.meanDiskBytesPerSecond != nil }.sorted {
                        $0.meanDiskBytesPerSecond! > $1.meanDiskBytesPerSecond!
                    }.prefix(8)))
        }
    }

    private static func dashboardValues(
        row: Row, sample: DisplaySnapshot
    ) -> [DashboardMetric: Double] {
        let s = sample.system
        let gib = 1_073_741_824.0
        var values: [DashboardMetric: Double] = [:]
        if let cpu: Double = row["cpu_fraction"] { values[.cpu] = cpu * 100 }
        values[.gpu] = row["gpu_percent"] as Double?
        if (row["pressure_level"] as Int?) != nil { values[.pressureIndex] = s.pressurePercent }
        if (row["memory_used"] as Double?) != nil {
            values[.appMemory] = Double(s.appMemory) / gib
            values[.wired] = Double(s.wired) / gib
            values[.compressed] = Double(s.compressed) / gib
            values[.cached] = Double(s.cachedFiles) / gib
            values[.free] = Double(s.free) / gib
        }
        if let swap: Double = row["swap_used"] { values[.swap] = swap / gib }
        if (row["network_bytes_per_second"] as Double?) != nil {
            values[.download] = s.networkInBytesPerSec / 1_000_000
            values[.upload] = s.networkOutBytesPerSec / 1_000_000
        }
        if (row["disk_bytes_per_second"] as Double?) != nil {
            values[.diskRead] = s.diskReadBytesPerSec / 1_000_000
            values[.diskWrite] = s.diskWriteBytesPerSec / 1_000_000
            values[.iops] = s.diskReadOperationsPerSec + s.diskWriteOperationsPerSec
        }
        values[.cpuTemperature] = s.cpuDieC
        values[.gpuTemperature] = s.gpuDieC
        values[.fan] = s.fanRPM
        if s.batteryPresent { values[.charge] = s.batteryCharge }
        // Older snapshots use zero when no system-power sensor is available.
        if s.batterySystemPowerWatts > 0 { values[.systemPower] = s.batterySystemPowerWatts }
        values[.gpuPower] = s.gpuPowerWatts
        values[.anePower] = s.reportedANEPowerWatts
        return values.filter { $0.value.isFinite }
    }

    private struct ProcessBuilder {
        var name: String
        var cpu = WeightedValue()
        var memory = WeightedValue()
        var disk = WeightedValue()
    }

    private static func dashboardProcesses(
        _ db: Database, window: QueryWindow, minutes: [Int: Double]
    ) throws -> [DashboardProcess] {
        guard !minutes.isEmpty else { return [] }
        var processes: [Int64: ProcessBuilder] = [:]
        let cursor = try Row.fetchCursor(
            db,
            sql: """
                WITH points AS (
                  SELECT *,LAG(ts) OVER p AS previous_ts,
                    LAG(disk_read_total_bytes+disk_written_total_bytes) OVER p AS previous_disk
                  FROM agent_process_usage WHERE ts >= ? AND ts < ?
                  WINDOW p AS (PARTITION BY process_key ORDER BY ts)
                ) SELECT * FROM points WHERE ts+resolution_seconds > ? ORDER BY ts
                """, arguments: [window.from - 7200, window.to, window.from])
        while let row = try cursor.next() {
            try Task.checkCancellation()
            let time: Double = row["ts"]
            let resolution: Double = row["resolution_seconds"]
            var overlap = 0.0
            for minute in Int(floor(time / 60))..<Int(ceil((time + resolution) / 60)) {
                overlap += minutes[minute, default: 0]
            }
            let covered: Double = row["covered_seconds"]
            let weight = min(resolution, covered) * min(1, overlap / resolution)
            guard weight > 0 else { continue }
            let id: Int64 = row["process_key"]
            var p = processes[id] ?? ProcessBuilder(name: row["name"])
            p.cpu.add(row["cpu_share_of_mac_percent"], seconds: weight)
            if let memory: Double = row["memory_mb"] { p.memory.add(memory, seconds: weight) }
            if let previousTime: Double = row["previous_ts"],
                let previousDisk: Double = row["previous_disk"],
                let read: Double = row["disk_read_total_bytes"],
                let written: Double = row["disk_written_total_bytes"],
                time > previousTime, time - previousTime <= resolution * 1.01,
                read + written >= previousDisk
            {
                p.disk.add((read + written - previousDisk) / (time - previousTime), seconds: weight)
            }
            processes[id] = p
        }
        return processes.map { id, p in
            DashboardProcess(
                id: id, name: p.name, meanCPU: p.cpu.value.mean,
                meanMemoryMB: p.memory.seconds > 0 ? p.memory.value.mean : nil,
                meanDiskBytesPerSecond: p.disk.seconds > 0 ? p.disk.value.mean : nil)
        }
    }
}
