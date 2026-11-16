// swift-tools-version: 6.2
import PackageDescription

// Everything that runs as root or talks to it: the helper daemon, its XPC interface and the
// client the app uses. Kept in one small package so the privileged code is easy to audit.
let package = Package(
    name: "ToolsyPrivileged",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ToolsyHelperClient", targets: ["ToolsyHelperClient"]),
        .executable(name: "ToolsyHelper", targets: ["ToolsyHelper"]),
    ],
    dependencies: [
        .package(path: "../ToolsyShared"),
    ],
    targets: [
        // The XPC protocol and the fixed paths both sides agree on.
        .target(name: "ToolsyHelperXPC"),
        // The daemon's logic, separate from its entry point so it can be tested.
        .target(
            name: "ToolsyHelperCore",
            dependencies: ["ToolsyHelperXPC", .product(name: "ToolsyShared", package: "ToolsyShared")]
        ),
        .target(
            name: "ToolsyHelperClient",
            dependencies: ["ToolsyHelperXPC", .product(name: "ToolsyShared", package: "ToolsyShared")]
        ),
        .executableTarget(name: "ToolsyHelper", dependencies: ["ToolsyHelperCore"]),
        // The same daemon with a configuration taken from its arguments, for the smoke test in the
        // user's own launchd domain. Not a product: it is never bundled or installed.
        .executableTarget(name: "ToolsyHelperTestDaemon", dependencies: ["ToolsyHelperCore"]),
        .testTarget(
            name: "ToolsyPrivilegedTests",
            dependencies: [
                "ToolsyHelperCore", "ToolsyHelperClient", "ToolsyHelperXPC",
                // Only so that both daemons are built before the tests that start them.
                "ToolsyHelper", "ToolsyHelperTestDaemon",
            ]
        ),
    ]
)
