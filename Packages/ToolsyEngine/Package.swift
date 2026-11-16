// swift-tools-version: 6.2
import PackageDescription

// The mod runtime: installing, loading and running mods, and the observable model the UI renders.
// No UI code and no knowledge of how privileged commands are executed.
let package = Package(
    name: "ToolsyEngine",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ToolsyEngine", targets: ["ToolsyEngine"]),
        .executable(name: "toolsy-mod", targets: ["toolsy-mod"]),
    ],
    dependencies: [
        .package(path: "../ToolsyShared"),
    ],
    targets: [
        .target(
            name: "ToolsyEngine",
            dependencies: [.product(name: "ToolsyShared", package: "ToolsyShared")]
        ),
        // Checks and packs mods; ships inside the app as Contents/Helpers/toolsy-mod.
        .executableTarget(
            name: "toolsy-mod",
            dependencies: ["ToolsyEngine", .product(name: "ToolsyShared", package: "ToolsyShared")]
        ),
        .testTarget(
            name: "ToolsyEngineTests",
            dependencies: ["ToolsyEngine", "toolsy-mod", .product(name: "ToolsyShared", package: "ToolsyShared")]
        ),
    ]
)
