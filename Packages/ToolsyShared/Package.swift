// swift-tools-version: 6.2
import PackageDescription

// The contract every other part of Toolsy builds on: the mod format, the command
// protocol and the privileged-execution interface. Foundation only, so the root
// helper can link it without pulling in anything else.
let package = Package(
    name: "ToolsyShared",
    platforms: [.macOS(.v26)],
    products: [.library(name: "ToolsyShared", targets: ["ToolsyShared"])],
    targets: [
        .target(name: "ToolsyShared"),
        .testTarget(name: "ToolsySharedTests", dependencies: ["ToolsyShared"]),
    ]
)
