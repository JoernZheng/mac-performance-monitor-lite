import Darwin
import Foundation

/// Manages only the current user's login service. History and CLI files survive removal.
public final class ServiceManager {
    public static let label = "org.joernzheng.mac-performance-recorder"

    struct CommandResult {
        let status: Int32
        let output: String
    }

    private let home: URL
    private let executable: URL
    private let userID: uid_t
    private let run: ([String]) throws -> CommandResult
    private let files = FileManager.default

    public convenience init(executableURL: URL) {
        self.init(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            executableURL: executableURL, userID: getuid(), commandRunner: Self.launchctl)
    }

    init(
        homeDirectory: URL, executableURL: URL, userID: uid_t,
        commandRunner: @escaping ([String]) throws -> CommandResult
    ) {
        home = homeDirectory
        executable = executableURL.resolvingSymlinksInPath()
        self.userID = userID
        run = commandRunner
    }

    private var support: URL {
        home.appendingPathComponent("Library/Application Support/MacPerformanceRecorder")
    }
    private var binary: URL { support.appendingPathComponent("bin/mac-recorder") }
    private var plist: URL {
        home.appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")
    }
    private var domain: String { "gui/\(userID)" }
    private var service: String { "\(domain)/\(Self.label)" }

    public func install() throws -> String {
        try requireUserSession()
        let existing = try existingManifest()
        if try isLoaded() {
            guard let existing, existing["RunAtLoad"] as? Bool == true,
                existing["KeepAlive"] as? Bool == true
            else {
                throw RecorderError.message(
                    "A running service has different login settings. It was left unchanged; uninstall it before reconfiguring."
                )
            }
            return
                "Login startup is already installed. The loaded service was left unchanged; check mpml status."
        }
        guard files.isExecutableFile(atPath: executable.path) else {
            throw RecorderError.message("Cannot locate the mpml executable to install.")
        }
        for directory in [support, binary.deletingLastPathComponent()] {
            try files.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        try files.createDirectory(
            at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        // An atomic replacement also works when invoked from an installed copy.
        try Data(contentsOf: executable).write(to: binary, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        for name in ["mpml", "mpm-lite"] {
            let alias = binary.deletingLastPathComponent().appendingPathComponent(name)
            if !files.fileExists(atPath: alias.path),
                (try? files.destinationOfSymbolicLink(atPath: alias.path)) == nil
            {
                try files.createSymbolicLink(
                    atPath: alias.path, withDestinationPath: "mac-recorder")
            }
        }
        // Preserve existing recording arguments, including custom databases and intervals.
        var manifest =
            existing ?? [
                "Label": Self.label,
                "ProgramArguments": [
                    binary.path, "record", "--db",
                    support.appendingPathComponent("history.sqlite").path,
                ],
                "ThrottleInterval": 30,
                "ProcessType": "Background",
                "StandardOutPath": "/dev/null",
                "StandardErrorPath": support.appendingPathComponent("service.log").path,
            ]
        manifest["RunAtLoad"] = true
        manifest["KeepAlive"] = true
        let data = try PropertyListSerialization.data(
            fromPropertyList: manifest, format: .xml, options: 0)
        try data.write(to: plist, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plist.path)
        let result = try run(["bootstrap", domain, plist.path])
        guard result.status == 0 else { throw commandError("install login startup", result) }
        guard try isLoaded() else {
            throw RecorderError.message(
                "launchd did not load the service. Check service.log and mpml status.")
        }
        return "Login startup installed and started. Check collection with: mpml status"
    }

    public func uninstall() throws -> String {
        try requireUserSession()
        _ = try existingManifest()
        if try isLoaded() {
            let result = try run(["bootout", service])
            if try isLoaded() { throw commandError("stop login startup", result) }
        }
        if files.fileExists(atPath: plist.path) { try files.removeItem(at: plist) }
        return
            "Login startup removed and recording stopped. History, logs and the mpml command were kept."
    }

    private func requireUserSession() throws {
        guard userID != 0 else {
            throw RecorderError.message("Run this command as your logged-in user, without sudo.")
        }
    }

    private func existingManifest() throws -> [String: Any]? {
        guard files.fileExists(atPath: plist.path) else { return nil }
        guard
            let value = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: plist), options: [], format: nil) as? [String: Any],
            value["Label"] as? String == Self.label,
            let arguments = value["ProgramArguments"] as? [String],
            arguments.first == binary.path, arguments.dropFirst().first == "record"
        else {
            throw RecorderError.message(
                "The existing login plist is not the expected recorder service; it was left unchanged."
            )
        }
        return value
    }

    private func isLoaded() throws -> Bool {
        let result = try run(["print", service])
        if result.status == 0 { return true }
        if [3, 113].contains(result.status) { return false }
        throw commandError("inspect login startup", result)
    }

    private func commandError(_ action: String, _ result: CommandResult) -> RecorderError {
        .message(
            "Cannot \(action): \(result.output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2048)) (exit \(result.status))."
        )
    }

    private static func launchctl(_ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
