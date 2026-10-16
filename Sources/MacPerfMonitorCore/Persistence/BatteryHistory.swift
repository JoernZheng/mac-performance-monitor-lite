import CryptoKit
import Foundation
import GRDB

public enum BatteryHistoryMetric: String, CaseIterable, Sendable {
    case charge, power, flow, temperature, runtime
    case fullRuntime = "full_runtime"
    case timeToFull = "to_full"

    var column: String { "energy_" + rawValue }
}

private struct BatteryHistoryValues {
    public enum PowerState: String, Sendable {
        case battery, charging, adapter, noBattery
    }

    public var observedAt: Date
    public var batteryID: String?
    public var state: PowerState?
    public var estimateSource: BatteryRuntimeEstimate.Source?
    public var values: [BatteryHistoryMetric: Double]

    public init(sample: BatterySample) {
        observedAt = sample.timestamp
        batteryID = sample.isPresent ? BatteryIdentity.identifier(for: sample.serialNumber) : nil
        state =
            !sample.isPresent
            ? .noBattery : (sample.isCharging ? .charging : (sample.isOnAC ? .adapter : .battery))
        values = [:]
        if sample.systemPowerWatts.isFinite, sample.systemPowerWatts > 0 {
            values[.power] = sample.systemPowerWatts
        }
        estimateSource = sample.runtimeEstimate?.source
        if sample.isPresent {
            if sample.chargePercent.isFinite, (0...100).contains(sample.chargePercent) {
                values[.charge] = sample.chargePercent
            }
            if sample.voltageMilliVolts > 0, sample.powerWatts.isFinite, sample.powerWatts >= 0 {
                values[.flow] = sample.isCharging ? sample.powerWatts : -sample.powerWatts
            }
            if let temperature = sample.temperatureCelsius, temperature.isFinite {
                values[.temperature] = temperature
            }
            if state == .battery {
                if let estimate = sample.runtimeEstimate {
                    values[.runtime] = estimate.minutesRemaining
                    values[.fullRuntime] = estimate.fullChargeMinutes
                } else if let minutes = sample.timeToEmptyMinutes, minutes >= 0 {
                    values[.runtime] = Double(minutes)
                    estimateSource = .macOS
                }
            } else if state == .charging, let minutes = sample.timeToFullMinutes, minutes >= 0 {
                values[.timeToFull] = Double(minutes)
            }
        }
        values = values.filter { $0.value.isFinite }
    }

}

public enum BatteryIdentity {
    public static func identifier(for serial: String?) -> String? {
        guard let serial else { return nil }
        let normalized = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= 512 else { return nil }
        return SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

extension SampleStore {
    static func recordDailyBattery(_ battery: BatterySample, db: Database) throws {
        guard battery.isPresent,
            let identifier = BatteryIdentity.identifier(for: battery.serialNumber)
        else { return }
        let timestamp = battery.timestamp.timeIntervalSince1970
        guard timestamp.isFinite, timestamp > 0 else { return }
        let health = battery.healthPercent.flatMap {
            $0.isFinite && (0...100).contains($0) ? $0 : nil
        }
        let cycles = battery.cycleCount.flatMap { $0 >= 0 ? $0 : nil }
        let full = battery.maxCapacitymAh.flatMap { $0 > 0 ? $0 : nil }
        let design = battery.designCapacitymAh.flatMap { $0 > 0 ? $0 : nil }
        guard health != nil || cycles != nil || full != nil || design != nil else { return }
        let day = floor(timestamp / 86_400) * 86_400
        try db.cachedStatement(
            sql: """
                INSERT INTO battery_daily
                    (battery_id, day, observed_at, health_percent, cycle_count, full_capacity_mah, design_capacity_mah)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(battery_id, day) DO UPDATE SET
                    observed_at = excluded.observed_at,
                    health_percent = COALESCE(excluded.health_percent, battery_daily.health_percent),
                    cycle_count = COALESCE(excluded.cycle_count, battery_daily.cycle_count),
                    full_capacity_mah = COALESCE(excluded.full_capacity_mah, battery_daily.full_capacity_mah),
                    design_capacity_mah = COALESCE(excluded.design_capacity_mah, battery_daily.design_capacity_mah)
                WHERE excluded.observed_at >= battery_daily.observed_at
                    AND excluded.observed_at - battery_daily.observed_at >= 60
                """
        ).execute(arguments: [identifier, day, timestamp, health, cycles, full, design])
    }

    static func recordBatteryHistory(
        _ sample: BatterySample?, timestamp: Date, db: Database
    ) throws {
        guard let sample,
            sample.timestamp <= timestamp,
            timestamp.timeIntervalSince(sample.timestamp) <= 60
        else { return }
        let point = BatteryHistoryValues(sample: sample)
        let metrics = BatteryHistoryMetric.allCases
        let assignments = metrics.map { "\($0.column) = ?" }.joined(separator: ", ")
        var arguments: [any DatabaseValueConvertible] = [
            point.batteryID, point.state?.rawValue, point.estimateSource?.rawValue,
            point.observedAt.timeIntervalSince1970,
        ]
        arguments += metrics.map { point.values[$0] as (any DatabaseValueConvertible) }
        arguments.append(timestamp.timeIntervalSince1970)
        try db.cachedStatement(
            sql: """
                UPDATE system_samples SET energy_battery_id = ?, energy_state = ?,
                    energy_estimate_source = ?, energy_observed_at = ?, \(assignments)
                WHERE timestamp = ?
                """
        ).execute(arguments: StatementArguments(arguments))
        try recordDailyBattery(sample, db: db)
    }

    static func rollBatteryHistory(
        _ db: Database, source: String, destination: String, bucket: Int,
        since: Double, until: Double
    ) throws {
        let raw = source == "system_samples"
        let time = raw ? "timestamp" : "bucket"
        var expressions = [
            "MAX(energy_observed_at) AS energy_observed_at",
            "CASE WHEN COUNT(DISTINCT energy_battery_id) = 1 THEN MIN(energy_battery_id) END AS energy_battery_id",
            "CASE WHEN COUNT(energy_state) = COUNT(*) AND MIN(energy_state) = MAX(energy_state) THEN MIN(energy_state) END AS energy_state",
            "CASE WHEN COUNT(DISTINCT energy_estimate_source) = 1 THEN MIN(energy_estimate_source) END AS energy_estimate_source",
        ]
        var columns = [
            "energy_observed_at", "energy_battery_id", "energy_state", "energy_estimate_source",
        ]
        for metric in BatteryHistoryMetric.allCases {
            let column = metric.column
            let weight = raw ? "1" : column + "_samples"
            let samePack = "COUNT(DISTINCT energy_battery_id) <= 1"
            let consistentState =
                "COUNT(energy_state) = COUNT(*) AND MIN(energy_state) = MAX(energy_state)"
            let gate: String
            switch metric {
            case .power: gate = "1"
            case .runtime, .fullRuntime, .timeToFull: gate = samePack + " AND " + consistentState
            default: gate = samePack
            }
            expressions += [
                "CASE WHEN \(gate) THEN SUM(\(column) * \(weight)) / NULLIF(SUM(CASE WHEN \(column) IS NOT NULL THEN \(weight) END), 0) END AS \(column)",
                "CASE WHEN \(gate) THEN MIN(\(raw ? column : column + "_min")) END AS \(column)_min",
                "CASE WHEN \(gate) THEN MAX(\(raw ? column : column + "_max")) END AS \(column)_max",
                "CASE WHEN \(gate) THEN SUM(CASE WHEN \(column) IS NOT NULL THEN \(weight) END) END AS \(column)_samples",
            ]
            columns += [column, column + "_min", column + "_max", column + "_samples"]
        }
        let assignments = columns.map { "\($0) = incoming.\($0)" }.joined(separator: ", ")
        try db.execute(
            sql: """
                UPDATE \(destination) AS target SET \(assignments)
                FROM (SELECT CAST(\(time) / \(bucket) AS INTEGER) * \(bucket) AS energy_bucket,
                    \(expressions.joined(separator: ", "))
                    FROM \(source) WHERE \(time) >= ? AND \(time) < ? GROUP BY energy_bucket) AS incoming
                WHERE target.bucket = incoming.energy_bucket
                """, arguments: [since, until])
    }

}
