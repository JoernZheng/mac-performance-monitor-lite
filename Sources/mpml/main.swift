import Darwin
import Foundation
import RecorderKit

struct Options {
    var command = "help"
    var values: [String: String] = [:]
    var switches = Set<String>()
    var positional: [String] = []
    init(_ arguments: [String]) throws {
        guard let command = arguments.first else { return }
        self.command = command
        let valued = Set([
            "--db", "--interval", "--process-interval", "--duration", "--retention-days",
            "--max-database-mb", "--user-idle-seconds", "--busy-cpu-percent", "--busy-gpu-percent",
            "--last", "--from", "--to", "--activity", "--format", "--limit", "--output",
        ])
        let flags = Set(["--no-per-app-network", "--per-app-network", "--help"])
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if valued.contains(argument) {
                guard index + 1 < arguments.count else {
                    throw RecorderError.message("Missing value for \(argument).")
                }
                values[argument] = arguments[index + 1]
                index += 2
            } else if flags.contains(argument) {
                switches.insert(argument)
                index += 1
            } else if argument.hasPrefix("--") {
                throw RecorderError.message("Unknown option: \(argument)")
            } else {
                positional.append(argument)
                index += 1
            }
        }
    }
    func number(_ key: String, default value: Double) throws -> Double {
        guard let raw = values[key] else { return value }
        guard let number = Double(raw), number.isFinite else {
            throw RecorderError.message("Invalid number for \(key).")
        }
        return number
    }
    var database: URL {
        values["--db"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? RecorderConfiguration.defaultDatabaseURL
    }
    func window() throws -> QueryWindow {
        func timestamp(_ raw: String) throws -> Double {
            if let number = Double(raw), number.isFinite { return number }
            if let date = ISO8601DateFormatter().date(from: raw) {
                return date.timeIntervalSince1970
            }
            throw RecorderError.message(
                "Use a Unix timestamp or ISO 8601 time with timezone for --from/--to.")
        }
        let end = try values["--to"].map(timestamp) ?? Date().timeIntervalSince1970
        if let raw = values["--from"] { return try QueryWindow(from: timestamp(raw), to: end) }
        let text = values["--last"] ?? "7d"
        let multipliers: [Character: Double] = ["s": 1, "m": 60, "h": 3600, "d": 86400]
        guard let unit = text.last, let factor = multipliers[unit],
            let number = Double(text.dropLast()), number.isFinite, number > 0,
            number * factor <= 365 * 86400
        else {
            throw RecorderError.message(
                "--last expects a duration such as 30m, 6h, or 7d (up to 365d).")
        }
        return try QueryWindow(from: end - number * factor, to: end)
    }
}

func printJSON(_ object: Any) throws {
    var data = try JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    data.append(10)
    try FileHandle.standardOutput.write(contentsOf: data)
}

let help = """
    Mac Performance Monitor Lite: local background capture and read-only analysis.

      mpml install                 Install and start this user's login service
      mpml uninstall               Stop/remove login startup; keep history and CLI
      mpml record [options]        Record all available performance metric families
      mpml status                  Latest recording run and actual data coverage
      mpml dashboard [--db PATH]   Open the optional read-only history window
      mpml summary --last 7d       Time-weighted native pressure by activity class
      mpml processes --last 7d     Per-process historical memory and CPU
      mpml sql 'SELECT ...'        One read-only query (max 10,000 rows)
      mpml export --last 7d        Stream complete metric snapshots (JSONL or CSV)

    Common: --db PATH
    Install/uninstall: no options; run as your logged-in user without sudo.
    Repeating install leaves an already-running configured service unchanged.
    Queries: --last 7d | --from UNIX_OR_ISO8601 --to UNIX_OR_ISO8601
             --format json|csv --limit 500 (sql/processes)
    Summary: --activity user_active|background_busy|idle|unknown (default: all)
    Export:  --format jsonl|csv --output PATH (default: stdout)
    Record:  --interval 10 --process-interval 30 --duration 0 (until SIGTERM/SIGINT)
             --retention-days 30 --max-database-mb 2048 --user-idle-seconds 300
             --busy-cpu-percent 15 --busy-gpu-percent 20 --no-per-app-network

    Native pressure is recorder_samples.pressure_level: 1 normal, 2 warning,
    4 critical, NULL unavailable. The upstream pressure index is a separate custom
    metric. Activity is an estimate based on input-idle/session and resource signals.
    No keystroke contents, screenshots, model calls, or telemetry are collected.
    Ordinary user mode may not read some system-process metrics or ANE watts.
    SQLite: \(RecorderConfiguration.defaultDatabaseURL.path)
    """

do {
    let options = try Options(Array(CommandLine.arguments.dropFirst()))
    if options.switches.contains("--help") || ["help", "-h", "--help"].contains(options.command) {
        print(help)
        exit(0)
    }
    switch options.command {
    case "install", "uninstall":
        guard options.values.isEmpty, options.switches.isEmpty, options.positional.isEmpty else {
            throw RecorderError.message(
                "install/uninstall take no options. Use --help for service behavior.")
        }
        guard let executable = Bundle.main.executableURL else {
            throw RecorderError.message("Cannot determine the mpml executable path.")
        }
        let manager = ServiceManager(executableURL: executable)
        print(try options.command == "install" ? manager.install() : manager.uninstall())
    case "record":
        var configuration = RecorderConfiguration()
        configuration.interval = try options.number("--interval", default: 10)
        configuration.processInterval = try options.number(
            "--process-interval", default: max(30, configuration.interval))
        configuration.retentionDays = try options.number("--retention-days", default: 30)
        let maxMB = try options.number("--max-database-mb", default: 2048)
        guard maxMB.rounded() == maxMB, (64...65536).contains(maxMB) else {
            throw RecorderError.message("--max-database-mb must be an integer in 64...65536.")
        }
        configuration.maxDatabaseMB = Int(maxMB)
        configuration.userIdleSeconds = try options.number("--user-idle-seconds", default: 300)
        configuration.busyCPUFraction = try options.number("--busy-cpu-percent", default: 15) / 100
        configuration.busyGPUPercent = try options.number("--busy-gpu-percent", default: 20)
        configuration.perAppNetwork = !options.switches.contains("--no-per-app-network")
        let duration = try options.number("--duration", default: 0)
        guard duration >= 0 else { throw RecorderError.message("Duration cannot be negative.") }
        let service = try RecorderService(url: options.database, configuration: configuration)
        FileHandle.standardError.write(
            Data(
                "Recording to \(options.database.path); interval \(configuration.interval)s, processes \(configuration.processInterval)s.\n"
                    .utf8))
        try service.run(duration: duration)
    case "status":
        try printJSON(RecorderQuery(url: options.database).status())
    case "dashboard":
        guard options.values.keys.allSatisfy({ $0 == "--db" }),
            options.switches.isEmpty, options.positional.isEmpty,
            let executable = Bundle.main.executableURL
        else { throw RecorderError.message("dashboard accepts only --db PATH.") }
        let viewer = executable.resolvingSymlinksInPath().deletingLastPathComponent()
            .appendingPathComponent("Mac Performance Monitor Lite.app")
        guard
            FileManager.default.isExecutableFile(
                atPath: viewer.appendingPathComponent("Contents/MacOS/mpml-dashboard").path)
        else {
            throw RecorderError.message(
                "Dashboard is not installed. Build and run Scripts/install-cli.sh to install both executables."
            )
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments =
            (options.values["--db"] == nil ? [] : ["-n"])
            + ["-a", viewer.path, "--args", "--db", options.database.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RecorderError.message("macOS could not open the Dashboard application.")
        }
        print("Opened the read-only Dashboard. Background recording is unchanged.")
    case "summary":
        let activity: ActivityKind?
        if let raw = options.values["--activity"] {
            guard let parsed = ActivityKind(rawValue: raw) else {
                throw RecorderError.message("Unknown activity class.")
            }
            activity = parsed
        } else {
            activity = nil
        }
        try printJSON(
            RecorderQuery(url: options.database).summary(
                window: options.window(), activity: activity))
    case "sql", "processes":
        let rawLimit = try options.number("--limit", default: options.command == "sql" ? 500 : 20)
        guard rawLimit.rounded() == rawLimit, (1...10000).contains(rawLimit) else {
            throw RecorderError.message("--limit must be an integer in 1...10000.")
        }
        let query = try RecorderQuery(url: options.database)
        let table: QueryTable
        if options.command == "sql" {
            guard options.positional.count == 1 else {
                throw RecorderError.message("Pass one quoted SQL statement.")
            }
            table = try query.query(options.positional[0], limit: Int(rawLimit))
        } else {
            table = try query.processes(window: options.window(), limit: Int(rawLimit))
        }
        let format = options.values["--format"] ?? "json"
        guard ["json", "csv"].contains(format) else {
            throw RecorderError.message("Query format is json or csv.")
        }
        if format == "csv" {
            print(try table.csv(), terminator: "")
        } else {
            try printJSON(table.jsonObject())
        }
    case "export":
        let output: FileHandle
        if let path = options.values["--output"] {
            let expanded = (path as NSString).expandingTildeInPath
            let descriptor = Darwin.open(expanded, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else {
                throw RecorderError.message("Cannot create export file, or it already exists.")
            }
            output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        } else {
            output = .standardOutput
        }
        let count = try RecorderQuery(url: options.database).export(
            window: options.window(),
            format: options.values["--format"] ?? "jsonl", output: output)
        FileHandle.standardError.write(Data("Exported \(count) snapshots.\n".utf8))
    default: throw RecorderError.message("Unknown command: \(options.command). Use help.")
    }
} catch {
    FileHandle.standardError.write(Data("mpml: \(error.localizedDescription)\n".utf8))
    exit(1)
}
