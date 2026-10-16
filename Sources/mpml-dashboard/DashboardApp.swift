import AppKit
import Charts
import RecorderKit
import SwiftUI

@main
struct DashboardApp: App {
    @NSApplicationDelegateAdaptor(DashboardDelegate.self) private var delegate
    var body: some Scene {
        Window("Mac Performance Monitor Lite", id: "dashboard") {
            DashboardView(database: Self.database)
        }
        .defaultSize(width: 1180, height: 850)
        .windowResizability(.contentMinSize)
    }

    private static var database: URL {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--db"), index + 1 < arguments.count {
            return URL(fileURLWithPath: arguments[index + 1])
        }
        return RecorderConfiguration.defaultDatabaseURL
    }
}

final class DashboardDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

private enum TimeRange: String, CaseIterable, Identifiable {
    case fiveMinutes = "5 min", thirtyMinutes = "30 min", hour = "1 hr"
    case sixHours = "6 hr", day = "24 hr", week = "7 days"
    var id: String { rawValue }
    var seconds: Double {
        switch self {
        case .fiveMinutes: return 300
        case .thirtyMinutes: return 1800
        case .hour: return 3600
        case .sixHours: return 21600
        case .day: return 86400
        case .week: return 604800
        }
    }
}

private enum ActivityFilter: String, CaseIterable, Identifiable {
    case all = "All periods", active = "User active", busy = "Background busy"
    case idle = "Idle", unknown = "Unknown"
    var id: String { rawValue }
    var kind: ActivityKind? {
        switch self {
        case .all: return nil
        case .active: return .userActive
        case .busy: return .backgroundBusy
        case .idle: return .idle
        case .unknown: return .unknown
        }
    }
}

@MainActor
private final class DashboardModel: ObservableObject {
    @Published var data: DashboardData?
    @Published var loading = false
    @Published var error: String?
    @Published var refreshed: Date?

    func load(database: URL, seconds: Double, activity: ActivityKind?) async {
        loading = true
        data = nil
        error = nil
        let worker = Task.detached(priority: .utility) {
            let end = Date().timeIntervalSince1970
            return try RecorderQuery(url: database).dashboard(
                window: QueryWindow(from: end - seconds, to: end), activity: activity)
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            data = result
            refreshed = Date()
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
        loading = false
    }
}

private struct DashboardView: View {
    let database: URL
    @StateObject private var model = DashboardModel()
    @State private var range = TimeRange.day
    @State private var filter = ActivityFilter.all
    @State private var refreshID = 0
    @Environment(\.scenePhase) private var phase
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let error = model.error {
                        ContentUnavailableView(
                            "History unavailable",
                            systemImage: "externaldrive.badge.exclamationmark",
                            description: Text(
                                error
                                    + " Start collection with mpml install, or choose a recorded database with --db."
                            ))
                    } else if let data = model.data {
                        coverage(data)
                        if data.selectedSeconds > 0 {
                            pressure(data)
                            headlineCards(data)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                                MetricPanel(
                                    title: "Processor", unit: "% of whole Mac",
                                    metrics: [.cpu, .gpu], data: data, ceiling: 100)
                                MetricPanel(
                                    title: "Memory", unit: "GiB",
                                    metrics: [
                                        .appMemory, .wired, .compressed, .cached, .free, .swap,
                                    ], data: data)
                                MetricPanel(
                                    title: "Network", unit: "MB/s", metrics: [.download, .upload],
                                    data: data)
                                MetricPanel(
                                    title: "Disk", unit: "MB/s", metrics: [.diskRead, .diskWrite],
                                    data: data)
                                MetricPanel(
                                    title: "Temperature", unit: "°C",
                                    metrics: [.cpuTemperature, .gpuTemperature], data: data)
                                MetricPanel(
                                    title: "Custom pressure index",
                                    unit: "Index / 100, not an Apple percentage",
                                    metrics: [.pressureIndex], data: data, ceiling: 100)
                                MetricPanel(
                                    title: "Disk operations", unit: "IOPS", metrics: [.iops],
                                    data: data)
                                MetricPanel(
                                    title: "Power", unit: "W",
                                    metrics: [.systemPower, .gpuPower, .anePower], data: data)
                            }
                            latest(data)
                            rankings(data)
                        } else {
                            ContentUnavailableView(
                                "No matching recorded time", systemImage: "chart.xyaxis.line",
                                description: Text(
                                    "Choose another time range or activity. Missing recordings are never counted as idle or normal pressure."
                                ))
                        }
                    } else {
                        ProgressView("Reading local history…").frame(
                            maxWidth: .infinity, minHeight: 300)
                    }
                    Text(database.path).font(.caption).foregroundStyle(.secondary).textSelection(
                        .enabled)
                }
                .padding(24)
            }
        }
        .frame(minWidth: 940, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: "\(range.id)-\(filter.id)-\(refreshID)-\(phase)") {
            guard phase == .active else { return }
            while !Task.isCancelled {
                await model.load(database: database, seconds: range.seconds, activity: filter.kind)
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Performance history").font(.title2.bold())
                Text("Mac Performance Monitor Lite · Read-only viewer").font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("History", selection: $range) {
                ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
            }.frame(width: 150)
            Picker("Activity", selection: $filter) {
                ForEach(ActivityFilter.allCases) { Text($0.rawValue).tag($0) }
            }.frame(width: 200)
            Button {
                refreshID += 1
            } label: {
                Image(systemName: "arrow.clockwise")
            }.help("Refresh history").disabled(model.loading)
            if model.loading { ProgressView().controlSize(.small) }
        }.padding(20)
    }

    private func coverage(_ data: DashboardData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(filter.rawValue).font(.headline)
                Text("\(duration(data.selectedSeconds)) selected").foregroundStyle(.secondary)
                Spacer()
                if let refreshed = model.refreshed {
                    Text("Updated \(refreshed.formatted(date: .omitted, time: .standard))").font(
                        .caption
                    ).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 20) {
                ForEach(ActivityFilter.allCases.filter { $0.kind != nil }) { item in
                    Text(
                        "\(item.rawValue): \(duration(data.activitySeconds[item.kind!, default: 0]))"
                    )
                }
                Spacer()
                Text("Unrecorded: \(duration(data.unrecordedSeconds))").foregroundStyle(.secondary)
            }.font(.caption)
            Text(
                "Activity is estimated from input, session and resource signals. Sleep and collection gaps are excluded. Refreshes every minute while this window is active."
            )
            .font(.caption).foregroundStyle(.secondary)
        }.panel()
    }

    private func pressure(_ data: DashboardData) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("macOS native memory pressure").font(.headline)
            HStack(spacing: 24) {
                ForEach(PressureState.all) { state in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(state.name, systemImage: "circle.fill").foregroundStyle(state.color)
                        Text(
                            String(
                                format: "%.1f%%",
                                data.pressureSeconds[state.id, default: 0] / data.selectedSeconds
                                    * 100)
                        )
                        .font(.title2.monospacedDigit().bold())
                        Text(duration(data.pressureSeconds[state.id, default: 0])).font(.caption)
                            .foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Chart {
                ForEach(data.buckets) { bucket in
                    ForEach(PressureState.all) { state in
                        let seconds = bucket.pressureSeconds[state.id, default: 0]
                        if seconds > 0 {
                            let lower = PressureState.all.prefix(while: { $0.id != state.id })
                                .reduce(0.0) { $0 + bucket.pressureSeconds[$1.id, default: 0] }
                            RectangleMark(
                                xStart: .value("Start", Date(timeIntervalSince1970: bucket.start)),
                                xEnd: .value("End", Date(timeIntervalSince1970: bucket.end)),
                                yStart: .value("State starts", lower),
                                yEnd: .value("State ends", lower + seconds)
                            )
                            .foregroundStyle(state.color)
                        }
                    }
                }
            }
            .chartXScale(
                domain: Date(
                    timeIntervalSince1970: data.from)...Date(timeIntervalSince1970: data.to)
            )
            .chartYAxisLabel("Covered seconds / bucket")
            .frame(height: 120)
            Text(
                "Percentages above are shares of selected recorded time, including unknown readings. The timeline stacks covered seconds by state; shorter bars expose incomplete buckets. This is not an Apple pressure percentage."
            )
            .font(.caption).foregroundStyle(.secondary)
        }.panel()
    }

    private func headlineCards(_ data: DashboardData) -> some View {
        HStack(spacing: 12) {
            ForEach(
                [DashboardMetric.cpu, .appMemory, .compressed, .swap, .pressureIndex], id: \.self
            ) { metric in
                VStack(alignment: .leading, spacing: 6) {
                    Text(metric.label).font(.caption).foregroundStyle(.secondary)
                    Text(
                        data.means[metric].map { formatted($0.mean, metric: metric) }
                            ?? "Unavailable"
                    )
                    .font(.title3.monospacedDigit().bold())
                    Text("Selected-time mean").font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).panel()
            }
        }
    }

    private func latest(_ data: DashboardData) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let latest = data.latest {
                HStack {
                    Text("Latest matching sample").font(.headline)
                    Text(
                        Date(timeIntervalSince1970: latest.timestamp),
                        format: .dateTime.month().day().hour().minute().second()
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.0f GiB RAM", latest.totalRAM / 1_073_741_824)).font(
                        .caption)
                }
                if Date().timeIntervalSince1970 - latest.timestamp > 60 {
                    Label(
                        "Historical sample; it does not describe the Mac right now.",
                        systemImage: "clock"
                    )
                    .font(.caption).foregroundStyle(.orange)
                }
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Per-core CPU").font(.subheadline.bold())
                        if latest.cores.isEmpty { Text("Unavailable").foregroundStyle(.secondary) }
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.flexible(), alignment: .leading), count: 4),
                            alignment: .leading, spacing: 12
                        ) {
                            ForEach(latest.cores) { core in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(
                                        "\(core.kind == "efficiency" ? "E" : "P")\(core.id): \(Int(core.percent))%"
                                    )
                                    .font(.caption.monospacedDigit()).fixedSize()
                                    ProgressView(value: min(100, max(0, core.percent)), total: 100)
                                        .tint(core.kind == "efficiency" ? .teal : .blue)
                                }.frame(maxWidth: .infinity, alignment: .leading)

                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Memory counters").font(.subheadline.bold())
                        ForEach(
                            [
                                DashboardMetric.appMemory, .wired, .compressed, .cached, .free,
                                .swap,
                            ], id: \.self
                        ) { metric in
                            HStack {
                                Text(metric.label)
                                Spacer()
                                Text(
                                    latest.values[metric].map { formatted($0, metric: metric) }
                                        ?? "Unavailable"
                                ).monospacedDigit()
                            }.font(.caption)
                        }
                    }.frame(width: 240)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Thermal state: \(latest.thermalState ?? "Unavailable")")
                        Text(
                            "Fan: \(latest.values[.fan].map { String(format: "%.0f rpm", $0) } ?? "Unavailable")"
                        )
                        Text(
                            "Load (1 min): \(latest.loadAverage.map { String(format: "%.2f", $0) } ?? "Unavailable")"
                        )
                        Text(
                            "Battery: \(latest.values[.charge].map { String(format: "%.0f%%", $0) } ?? "Unavailable")"
                        )
                    }.font(.caption).frame(width: 180, alignment: .leading)
                }
                Text(
                    "Memory counters can overlap and are not forced into a stacked total. Swap is disk-backed storage, separate from physical RAM."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }.panel()
    }

    private func rankings(_ data: DashboardData) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Processes during selected periods").font(.headline)
            HStack(alignment: .top, spacing: 24) {
                ranking("CPU", data.topCPU) { String(format: "%.1f%%", $0.meanCPU) }
                ranking("Memory", data.topMemory) {
                    String(format: "%.0f MB", $0.meanMemoryMB ?? 0)
                }
                ranking("Disk", data.topDisk) {
                    String(format: "%.2f MB/s", ($0.meanDiskBytesPerSecond ?? 0) / 1_000_000)
                }
            }
            Text(
                "Estimates from completed minute/hour rollups, weighted by overlap with selected activity. Mixed periods cannot be attributed exactly. CPU is a share of the whole Mac; memory is mean footprint. Disk rates use consecutive cumulative-counter differences. Current/incomplete minutes and unavailable counters may be absent."
            )
            .font(.caption).foregroundStyle(.secondary)
        }.panel()
    }

    private func ranking(
        _ title: String, _ rows: [DashboardProcess], value: @escaping (DashboardProcess) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.subheadline.bold())
            if rows.isEmpty {
                Text("No completed process data").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                HStack {
                    Text(row.name).lineLimit(1).help(row.name)
                    Spacer(minLength: 8)
                    Text(value(row)).monospacedDigit()
                }.font(.caption)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PressureState: Identifiable {
    let id: Int
    let name: String
    let color: Color
    static let all = [
        PressureState(id: 1, name: "Normal", color: .green),
        PressureState(id: 2, name: "Warning", color: .orange),
        PressureState(id: 4, name: "Critical", color: .red),
        PressureState(id: 0, name: "Unknown", color: .gray),
    ]
}

private struct PlotPoint: Identifiable {
    let id: String
    let date: Date
    let value: DashboardValue
    let series: String
    let group: String
}

private struct MetricPanel: View {
    let title: String
    let unit: String
    let metrics: [DashboardMetric]
    let data: DashboardData
    var ceiling: Double?
    @State private var hoveredDate: Date?

    private var points: [PlotPoint] {
        metrics.flatMap { metric in
            var segment = 0
            var previousSegment: Int?
            var previousPartial = false
            return data.buckets.compactMap { bucket -> PlotPoint? in
                guard let value = bucket.values[metric] else {
                    segment += 1
                    previousSegment = nil
                    return nil
                }
                let partial = value.seconds < bucket.seconds - 0.25
                if previousSegment != bucket.segment || partial || previousPartial { segment += 1 }
                previousSegment = bucket.segment
                previousPartial = partial
                return PlotPoint(
                    id: "\(metric.rawValue)-\(bucket.id)", date: bucket.date,
                    value: value, series: metric.label, group: "\(metric.rawValue)-\(segment)")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            if points.isEmpty {
                Text("No available readings in selected periods")
                    .font(.caption).foregroundStyle(.secondary).frame(
                        maxWidth: .infinity, minHeight: 190)
            } else {
                Chart {
                    ForEach(points) { point in
                        AreaMark(
                            x: .value("Time", point.date),
                            yStart: .value("Minimum", point.value.minimum),
                            yEnd: .value("Maximum", point.value.maximum),
                            series: .value("Segment", point.group)
                        )
                        .foregroundStyle(by: .value("Metric", point.series)).opacity(0.12)
                        LineMark(
                            x: .value("Time", point.date), y: .value("Mean", point.value.mean),
                            series: .value("Segment", point.group)
                        )
                        .foregroundStyle(by: .value("Metric", point.series))
                        PointMark(
                            x: .value("Time", point.date), y: .value("Mean", point.value.mean)
                        )
                        .foregroundStyle(by: .value("Metric", point.series)).symbolSize(5)
                    }
                    if let hoveredDate {
                        RuleMark(x: .value("Selected time", hoveredDate)).foregroundStyle(
                            .secondary.opacity(0.2))
                    }
                }
                .chartXScale(
                    domain: Date(
                        timeIntervalSince1970: data.from)...Date(timeIntervalSince1970: data.to)
                )
                .chartYScale(
                    domain: 0...(ceiling ?? max(1, points.map(\.value.maximum).max()! * 1.1))
                )
                .chartXSelection(value: $hoveredDate)
                .frame(height: 190)
            }
            if let hoveredDate,
                let nearest = points.min(by: {
                    abs($0.date.timeIntervalSince(hoveredDate))
                        < abs($1.date.timeIntervalSince(hoveredDate))
                }), abs(nearest.date.timeIntervalSince(hoveredDate)) <= data.bucketSeconds
            {
                Text(
                    "\(nearest.date.formatted(date: .abbreviated, time: .shortened)): "
                        + points.filter {
                            $0.date == nearest.date
                        }.map {
                            String(
                                format: "%@: %.2f (%.2f...%.2f)", $0.series, $0.value.mean,
                                $0.value.minimum, $0.value.maximum)
                        }.joined(separator: " · ")
                )
                .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(
                    "Time-weighted means; shading shows recorded min/max. Gaps remain unconnected."
                )
                .font(.caption2).foregroundStyle(.secondary)
            }
        }.panel()
    }
}

private func duration(_ seconds: Double) -> String {
    if seconds < 60 { return String(format: "%.0fs", seconds) }
    if seconds < 3600 { return String(format: "%.1fm", seconds / 60) }
    return String(format: "%.1fh", seconds / 3600)
}

private func formatted(_ value: Double, metric: DashboardMetric) -> String {
    switch metric {
    case .cpu, .gpu, .charge: return String(format: "%.1f%%", value)
    case .pressureIndex: return String(format: "%.1f / 100", value)
    default: return String(format: "%.2f GiB", value)
    }
}

private extension View {
    func panel() -> some View {
        padding(16)
            .background(
                Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.08)))
    }
}
