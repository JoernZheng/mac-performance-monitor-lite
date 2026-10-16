import Foundation
import XCTest

@testable import RecorderKit

final class ServiceManagerTests: XCTestCase {
    private var root: URL!
    private var source: URL!
    private var launchd: FakeLaunchd!

    private var support: URL {
        root.appendingPathComponent("Library/Application Support/MacPerformanceRecorder")
    }
    private var binary: URL { support.appendingPathComponent("bin/mac-recorder") }
    private var plist: URL {
        root.appendingPathComponent("Library/LaunchAgents/\(ServiceManager.label).plist")
    }
    private var manager: ServiceManager {
        ServiceManager(
            homeDirectory: root, executableURL: source, userID: 501,
            commandRunner: launchd.call)
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        source = root.appendingPathComponent("mpml")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)
        launchd = FakeLaunchd()
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func manifest(arguments: [String]? = nil, label: String = ServiceManager.label) throws {
        try FileManager.default.createDirectory(
            at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        let value: [String: Any] = [
            "Label": label,
            "ProgramArguments": arguments ?? [binary.path, "record"],
            "RunAtLoad": true, "KeepAlive": true,
        ]
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
            .write(to: plist)
    }

    func testInstallRegistersStableServicePathsAndStartsIt() throws {
        _ = try manager.install()
        let value = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil)
                as? [String: Any])
        XCTAssertEqual(value["Label"] as? String, ServiceManager.label)
        XCTAssertEqual(
            value["ProgramArguments"] as? [String],
            [binary.path, "record", "--db", support.appendingPathComponent("history.sqlite").path])
        XCTAssertEqual(value["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(value["KeepAlive"] as? Bool, true)
        XCTAssertEqual(try Data(contentsOf: binary), try Data(contentsOf: source))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: support.appendingPathComponent("bin/mpml").path), "mac-recorder")
        XCTAssertTrue(launchd.loaded)
        XCTAssertEqual(launchd.calls.filter { $0.first == "bootstrap" }.count, 1)
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: plist.path)[.posixPermissions]
                as? NSNumber)?.intValue,
            0o600)
    }

    func testRepeatedInstallDoesNotRewriteOrRestartRunningService() throws {
        _ = try manager.install()
        let originalManifest = try Data(contentsOf: plist)
        let originalBinary = try Data(contentsOf: binary)
        let history = support.appendingPathComponent("history.sqlite")
        try Data("existing history".utf8).write(to: history)
        try Data("a different candidate executable".utf8).write(to: source)
        launchd.calls = []
        let result = try manager.install()
        XCTAssertTrue(result.contains("already installed"))
        XCTAssertEqual(try Data(contentsOf: plist), originalManifest)
        XCTAssertEqual(try Data(contentsOf: binary), originalBinary)
        XCTAssertEqual(try String(contentsOf: history, encoding: .utf8), "existing history")
        XCTAssertEqual(launchd.calls.map { $0.first! }, ["print"])
    }

    func testStoppedInstallationPreservesCustomRecordingArgumentsAndHistory() throws {
        let args = [
            binary.path, "record", "--db", root.appendingPathComponent("custom.sqlite").path,
            "--interval", "22",
        ]
        try manifest(arguments: args)
        let history = root.appendingPathComponent("custom.sqlite")
        try Data("custom history".utf8).write(to: history)
        _ = try manager.install()
        let value = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil)
                as? [String: Any])
        XCTAssertEqual(value["ProgramArguments"] as? [String], args)
        XCTAssertEqual(try String(contentsOf: history, encoding: .utf8), "custom history")
    }

    func testUninstallRemovesOnlyServiceAndKeepsHistoryLogsAndCommand() throws {
        _ = try manager.install()
        for name in ["history.sqlite", "history.sqlite-wal", "service.log"] {
            try Data(name.utf8).write(to: support.appendingPathComponent(name))
        }
        _ = try manager.uninstall()
        XCTAssertFalse(launchd.loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: binary.path))
        for name in ["history.sqlite", "history.sqlite-wal", "service.log"] {
            XCTAssertEqual(
                try String(contentsOf: support.appendingPathComponent(name), encoding: .utf8), name)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: support.appendingPathComponent("bin/mpml").path))
    }

    func testUninstallWithoutAnInstallationIsIdempotent() throws {
        _ = try manager.uninstall()
        _ = try manager.uninstall()
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
        XCTAssertEqual(launchd.calls.map { $0.first! }, ["print", "print"])
    }

    func testUnrelatedManifestIsNeverRewrittenOrRemoved() throws {
        try manifest(label: "unrelated.service")
        let original = try Data(contentsOf: plist)
        XCTAssertThrowsError(try manager.install())
        XCTAssertThrowsError(try manager.uninstall())
        XCTAssertEqual(try Data(contentsOf: plist), original)
        XCTAssertTrue(launchd.calls.isEmpty)
    }

    func testFailedBootoutPreservesLoginManifestAndSurfacesFailure() throws {
        _ = try manager.install()
        launchd.failBootout = true
        XCTAssertThrowsError(try manager.uninstall())
        XCTAssertTrue(launchd.loaded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plist.path))
    }

    func testBootstrapFailureDoesNotClaimSuccessOrDeleteExistingHistory() throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let history = support.appendingPathComponent("history.sqlite")
        try Data("history".utf8).write(to: history)
        launchd.failBootstrap = true
        XCTAssertThrowsError(try manager.install())
        XCTAssertFalse(launchd.loaded)
        XCTAssertEqual(try String(contentsOf: history, encoding: .utf8), "history")
    }

    private final class FakeLaunchd {
        var loaded = false
        var failBootout = false
        var failBootstrap = false
        var calls: [[String]] = []
        func call(_ arguments: [String]) throws -> ServiceManager.CommandResult {
            calls.append(arguments)
            switch arguments.first {
            case "print":
                return .init(status: loaded ? 0 : 113, output: loaded ? "loaded" : "not found")
            case "bootstrap":
                if failBootstrap { return .init(status: 5, output: "bootstrap failed") }
                loaded = true
                return .init(status: 0, output: "")
            case "bootout":
                if failBootout { return .init(status: 5, output: "bootout failed") }
                loaded = false
                return .init(status: 0, output: "")
            default: throw RecorderError.message("Unexpected launchctl call")
            }
        }
    }
}
