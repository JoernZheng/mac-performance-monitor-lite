// SPDX-License-Identifier: MIT
import AppKit
import GRDB
import MacPerfMonitorCore
import SwiftUI
import XCTest
import os

@testable import MacPerfMonitor

@MainActor
final class MenuMemoryTests: XCTestCase {
    func testBenchmarkTeardownReleasesItsHostAndWindow() async throws {
        _ = NSApplication.shared
        XCTAssertFalse(ChartBenchmark.Options(arguments: []).teardown)
        let options = ChartBenchmark.Options(arguments: [
            "--scenario", "dashboardPage", "--points", "60",
            "--range", "fiveMinutes", "--mode", "host", "--teardown",
        ])
        XCTAssertTrue(options.teardown)
        let runner = ChartBenchmark.HostModeRunner(options: options)
        weak var window: NSWindow?
        weak var host: NSView?
        autoreleasepool {
            runner.prepareWindow()
            window = runner.window
            host = runner.window?.contentView
            XCTAssertNotNil(host)
            runner.tearDownWindow()
        }
        await settle()
        XCTAssertNil(runner.window)
        XCTAssertNil(host, "the benchmark must not retain the UI being measured")
        XCTAssertNil(window)
    }

    func testSlowLeakScansAreCoalescedAndCanRunAgain() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-scan-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path.path + suffix)
            }
        }
        let initial = try SampleStore(url: path)
        let release = DispatchSemaphore(value: 0)
        let entered = expectation(description: "leak query entered")
        let scanReads = OSAllocatedUnfairLock(initialState: 0)
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            db.trace { event in
                guard event.expandedDescription.contains("FROM processes WHERE pid") else { return }
                let first = scanReads.withLock {
                    $0 += 1
                    return $0 == 1
                }
                if first {
                    entered.fulfill()
                    _ = release.wait(timeout: .now() + 10)
                }
            }
        }
        let pool = try DatabasePool(path: path.path, configuration: configuration)
        let store = SampleStore(pool: pool)
        let model = SamplerModel(interval: 0.25, store: store, persistenceEnabled: true)
        model.addPopoverProcessConsumer(.footprint)
        model.start()
        await settle()
        model.stop()
        await settle()
        // The completed process snapshot supplies the live identities to the scan.
        model.scheduleLeakScan(store)
        await fulfillment(of: [entered], timeout: 5)
        for _ in 0..<20 { model.scheduleLeakScan(store) }
        await settle()
        release.signal()
        await settle()
        let firstPassReads = scanReads.withLock { $0 }
        XCTAssertGreaterThan(firstPassReads, 0)
        model.scheduleLeakScan(store)
        await settle()
        XCTAssertEqual(scanReads.withLock { $0 }, 2 * firstPassReads)
        withExtendedLifetime(initial) {}
    }

    func testBitmapReuseScaleAndLiveUpdates() throws {
        _ = NSApplication.shared
        let view = MenuBitmapChartView(frame: CGRect(x: 0, y: 0, width: 404, height: 104))
        let values = (0..<60).map { Double($0) }
        var model = MenuBitmapChart.Model(
            series: [.init(values: values, color: .red)],
            domain: 0...100, capacity: 60)
        view.update(model, colors: [NSColor.red.cgColor])
        let count = view.renderCount
        view.update(model, colors: [NSColor.red.cgColor])
        XCTAssertEqual(view.renderCount, count, "identical ticks must reuse the image")
        let image = try XCTUnwrap(view.layer?.contents) as! CGImage
        XCTAssertEqual(image.width, 808)
        XCTAssertEqual(image.height, 208)
        for i in 0..<120 {
            model.series[0].values.removeFirst()
            model.series[0].values.append(Double(i % 100))
            view.update(model, colors: [NSColor.red.cgColor])
        }
        XCTAssertEqual(view.renderCount, count + 120)
        XCTAssertEqual((try XCTUnwrap(view.layer?.contents) as! CGImage).width, 808)
    }

    func testBitmapPreservesDirectionAndMissingGaps() throws {
        let bitmap = ChartBitmap()
        let model = MenuBitmapChart.Model(
            series: [
                .init(
                    values: [50, 50, .nan, 50, 50], color: .red,
                    smooth: false, fill: false, lineWidth: 2),
                .init(
                    values: [50, 50], color: .blue, smooth: false, fill: false,
                    downward: true, lineWidth: 2),
            ],
            domain: -100...100, capacity: nil, inset: 0)
        let image = try XCTUnwrap(
            bitmap.render(size: CGSize(width: 100, height: 100), scale: 1) {
                MenuBitmapChartView.draw(
                    model, colors: [NSColor.red.cgColor, NSColor.blue.cgColor],
                    in: $0, size: CGSize(width: 100, height: 100))
            })
        let rep = NSBitmapImageRep(cgImage: image)
        let upper = try XCTUnwrap(rep.colorAt(x: 10, y: 25)?.usingColorSpace(.deviceRGB))
        let lower = try XCTUnwrap(rep.colorAt(x: 10, y: 75)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(upper.redComponent, 0.9)
        XCTAssertGreaterThan(lower.blueComponent, 0.9)
        XCTAssertEqual(rep.colorAt(x: 50, y: 25)?.alphaComponent, 0)
    }

    func testIdleCleanupRetainsHistoryAndHonoursConsumerHandoffs() async throws {
        let model = SamplerModel(persistenceEnabled: false)
        let now = Date()
        let sample = ProcessSample(
            timestamp: now, pid: 1234, ppid: 1, name: "Fixture",
            physFootprint: 100, residentSize: 100, virtualSize: 100, lifetimeMaxFootprint: 100,
            cpuPercent: 5, cpuTimeUser: 0, cpuTimeSystem: 0, threadCount: 1,
            fdTotal: 0, fdVnode: 0, fdSocket: 0, fdPipe: 0, fdOther: 0,
            diskBytesRead: 0, diskBytesWritten: 0, isTranslated: false, architecture: .arm64,
            startTime: now, uid: 501, dataSource: .directUserRead, footprintReadable: true)
        model.publishForBenchmark(
            .init(
                system: SystemSample(
                    timestamp: now, totalRAM: 1000, free: 700, active: 100, inactive: 100,
                    wired: 100, speculative: 0, compressed: 0, appMemory: 100, cachedFiles: 100,
                    swapTotal: 1000, swapUsed: 0, pressureLevel: .normal, pressurePercent: 10,
                    pageIns: 0, pageOuts: 0, compressions: 0, decompressions: 0),
                processes: [sample], unreadableProcessCount: 0))
        let historyCount = model.systemHistory.count
        model.addPopoverProcessConsumer(.footprint)
        model.setPopoverVisible(true)
        model.removePopoverProcessConsumer(.footprint)
        model.setPopoverVisible(false)
        model.addProcessConsumer()
        model.setWindowOpen(true)
        await settle()
        XCTAssertNotNil(model.currentSample(for: sample.id))
        XCTAssertFalse(model.trailSamples(for: sample.id).isEmpty)
        model.removeProcessConsumer()
        model.setWindowOpen(false)
        model.addPopoverProcessConsumer(.cpu)
        model.setPopoverVisible(true)
        await settle()
        XCTAssertTrue(model.displayProcesses.isEmpty)
        XCTAssertFalse(model.trailSamples(for: sample.id).isEmpty)
        model.removePopoverProcessConsumer(.cpu)
        model.setPopoverVisible(false)
        await settle()
        XCTAssertNil(model.latest)
        XCTAssertTrue(model.trailSamples(for: sample.id).isEmpty)
        XCTAssertEqual(model.systemHistory.count, historyCount)
        XCTAssertTrue(model.menuLists.topCPU.isEmpty)
        XCTAssertTrue(model.menuLists.topFootprint.isEmpty)
    }

    func testMenuOnlySamplingDoesNotBuildFullTableOrOtherRankings() async {
        let model = SamplerModel(interval: 0.25, persistenceEnabled: false)
        model.addPopoverProcessConsumer(.footprint)
        model.setPopoverVisible(true)
        model.start()
        defer { model.stop() }
        await settle()
        XCTAssertFalse(model.menuLists.topFootprint.isEmpty)
        XCTAssertTrue(model.displayProcesses.isEmpty)
        XCTAssertTrue(model.menuLists.topCPU.isEmpty)
        XCTAssertTrue(model.menuLists.topEnergy.isEmpty)
        XCTAssertFalse(model.menuLists.gpuListScanned)
        model.removePopoverProcessConsumer(.footprint)
        model.setPopoverVisible(false)
        await settle()
        XCTAssertNil(model.latest)
        XCTAssertTrue(model.menuLists.topFootprint.isEmpty)
    }

    private func settle() async {
        let ready = expectation(description: "serial work and idle debounce settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 5)
    }
}
