// swift-tools-version: 6.2
import PackageDescription

// The menu bar app. Everything that is not UI lives in the local packages under Packages/.
let package = Package(
    name: "Toolsy",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "Packages/ToolsyShared"),
        .package(path: "Packages/ToolsyEngine"),
        .package(path: "Packages/ToolsyPrivileged"),
    ],
    targets: [
        .executableTarget(
            name: "Toolsy",
            dependencies: [
                .product(name: "ToolsyShared", package: "ToolsyShared"),
                .product(name: "ToolsyEngine", package: "ToolsyEngine"),
                .product(name: "ToolsyHelperClient", package: "ToolsyPrivileged"),
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "ToolsyTests",
            dependencies: ["Toolsy"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
