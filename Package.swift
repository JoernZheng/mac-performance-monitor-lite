// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacPerformanceMonitorLite",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "mpm-lite", targets: ["mpm-lite"]),
        .executable(name: "mac-recorder", targets: ["mpm-lite"]),
        .library(name: "RecorderKit", targets: ["RecorderKit"]),
    ],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.0")],
    targets: [
        .target(name: "CMacPerfMonitor"),
        .target(
            name: "MacPerfMonitorCore",
            dependencies: ["CMacPerfMonitor", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(
            name: "RecorderKit",
            dependencies: ["MacPerfMonitorCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "mpm-lite", dependencies: ["RecorderKit"]),
        .testTarget(
            name: "MacPerfMonitorCoreTests",
            dependencies: ["MacPerfMonitorCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(
            name: "RecorderKitTests",
            dependencies: [
                "RecorderKit", "MacPerfMonitorCore", .product(name: "GRDB", package: "GRDB.swift"),
            ]),
    ],
    swiftLanguageModes: [.v5]
)
