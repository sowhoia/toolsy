// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VPNProtector",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "vpn-protector", targets: ["VPNProtector"])],
    targets: [
        .executableTarget(name: "VPNProtector"),
        .testTarget(name: "VPNProtectorTests", dependencies: ["VPNProtector"]),
    ]
)
