import Darwin
import Dispatch
import Foundation
import MacPerfMonitorCore

public final class RecorderService {
    public let configuration: RecorderConfiguration
    private let store: RecorderStore
    private let sampler = Sampler()
    private var networkProcessReader: NetworkProcessReader?
    private let queue = DispatchQueue(label: "personal.mac-performance-monitor-lite", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var deadline: DispatchSourceTimer?
    private var pressure: DispatchSourceMemoryPressure?
    private var signals: [DispatchSourceSignal] = []
    private var previousWall: Double?
    private var previousMonotonic: Double?
    private var lastProcessAt: Double?
    private var lastMaintenanceAt: Double?
    private var lastProcessSampleTime: Date?
    private var unreadable = 0
    private var processCount = 0
    private var stopped = false
    private var result: Result<Void, Error> = .success(())
    private let finished = DispatchSemaphore(value: 0)

    public init(url: URL, configuration: RecorderConfiguration) throws {
        self.configuration = configuration
        self.store = try RecorderStore(url: url, configuration: configuration)
    }

    public func run(duration: TimeInterval = 0) throws {
        guard duration.isFinite, duration >= 0 else {
            throw RecorderError.message("Duration must be finite and nonnegative.")
        }
        if configuration.perAppNetwork {
            let reader = NetworkProcessReader(refreshInterval: configuration.processInterval)
            networkProcessReader = reader
            sampler.setNetworkProcessReader(reader)
        }
        for number in [SIGINT, SIGTERM] {
            Darwin.signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in self?.stop(reason: "signal_\(number)") }
            source.resume()
            signals.append(source)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(), repeating: configuration.interval,
            leeway: .milliseconds(Int(min(1, configuration.interval * 0.1) * 1000)))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
        let pressure = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: queue)
        pressure.setEventHandler { [weak self] in self?.tick() }
        self.pressure = pressure
        pressure.resume()
        if duration > 0 {
            let end = DispatchSource.makeTimerSource(queue: queue)
            end.schedule(deadline: .now() + duration)
            end.setEventHandler { [weak self] in self?.stop(reason: "duration_complete") }
            deadline = end
            end.resume()
        }
        finished.wait()
        try result.get()
    }

    private func tick() {
        guard !stopped else { return }
        autoreleasepool {
            do { try capture() } catch { stop(reason: "recording_error", error: error) }
        }
    }

    private func capture() throws {
        let now = Date()
        let monotonic = RecorderClock.monotonicSeconds()
        let coverage = RecorderClock.coveredSeconds(
            previousWall: previousWall, previousMonotonic: previousMonotonic,
            wall: now.timeIntervalSince1970, monotonic: monotonic, interval: configuration.interval)
        if coverage == nil {
            sampler.reset()
            lastProcessAt = nil
            lastProcessSampleTime = nil
        }
        let (system, cpu, battery, network, disk, gpu) = sampler.tickSystem(
            now: now, readGPU: true, gpuReadInterval: configuration.interval)
        let activitySignals = ActivitySignals.read()
        let hasBaseline = coverage != nil
        let activity = ActivityClassifier.classify(
            activitySignals,
            cpuFraction: hasBaseline && !cpu.cores.isEmpty ? system.cpuLoad : nil,
            gpuPercent: hasBaseline ? system.gpuUtilization : nil,
            diskBytesPerSecond: hasBaseline && disk != nil
                ? system.diskReadBytesPerSec + system.diskWriteBytesPerSec : nil,
            networkBytesPerSecond: hasBaseline && network != nil
                ? system.networkInBytesPerSec + system.networkOutBytesPerSec : nil,
            configuration: configuration)
        var processes: [ProcessSample]?
        if lastProcessAt.map({ monotonic - $0 >= configuration.processInterval }) ?? true {
            let scanned = sampler.tickProcesses(now: now)
            processes = scanned.processes
            unreadable = scanned.unreadableProcessCount
            processCount = scanned.processes.count
            lastProcessAt = monotonic
            lastProcessSampleTime = now
        }
        var recorded = RecordedSnapshot(
            system: system, cpu: cpu, gpu: gpu, battery: battery,
            network: network, disk: disk, activitySignals: activitySignals, activity: activity,
            processSampleTime: lastProcessSampleTime, unreadableProcessCount: unreadable,
            processCount: processCount)
        let networkAt = networkProcessReader?.latestSampleTime()
        recorded.metricAvailability = [
            "native_pressure": system.pressureSampleValid == true ? "available" : "unavailable",
            "memory": system.vmSampleValid == true ? "available" : "unavailable",
            "cpu_rates": !cpu.cores.isEmpty && hasBaseline
                ? "available" : "baseline_or_unavailable",
            "gpu": gpu == nil ? "unavailable" : "available",
            "ane_watts": system.anePowerWatts == nil
                ? "unavailable_without_privileged_provider" : "available",
            "network": network == nil ? "unavailable" : "available",
            "disk": disk == nil ? "unavailable" : "available",
            "battery": battery == nil ? "unavailable_or_not_present" : "available",
            "per_app_network": !configuration.perAppNetwork
                ? "disabled"
                : (networkAt.map {
                    now.timeIntervalSince($0) < max(60, configuration.processInterval * 3)
                } == true ? "available" : "baseline_stale_or_unavailable"),
            "processes": unreadable > 0 ? "partial_user_permissions" : "available",
        ]
        try store.append(recorded, coveredSeconds: coverage ?? 0, processes: processes)
        previousWall = now.timeIntervalSince1970
        previousMonotonic = monotonic
        if lastMaintenanceAt.map({ monotonic - $0 >= 60 }) ?? true {
            try store.maintain(configuration: configuration, now: now)
            lastMaintenanceAt = monotonic
        }
    }

    private func stop(reason: String, error: Error? = nil) {
        guard !stopped else { return }
        stopped = true
        timer?.cancel()
        deadline?.cancel()
        pressure?.cancel()
        signals.forEach { $0.cancel() }
        var failure = error
        if error == nil {
            do { try capture() } catch { failure = error }
        }
        sampler.setNetworkProcessReader(nil)
        sampler.stopANEPowerSampling()
        do {
            let detail = failure.map { ": " + String($0.localizedDescription.prefix(1024)) } ?? ""
            try store.finish(reason: reason + detail)
            result = failure.map { .failure($0) } ?? .success(())
        } catch { result = .failure(error) }
        finished.signal()
    }
}
