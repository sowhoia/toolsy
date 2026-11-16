import Foundation
import ToolsyHelperCore

// The helper daemon as a launchd agent of the current user, for the smoke test only.
// Arguments: <store root> <Mach service name> [files deleted on uninstall…]
let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: ToolsyHelperTestDaemon <store root> <service name> [installed files…]\n".utf8))
    exit(64)
}
let label = arguments[2]
HelperDaemon.run(HelperConfiguration(
    machServiceName: label,
    storeRoot: URL(filePath: arguments[1], directoryHint: .isDirectory),
    installedFiles: arguments.dropFirst(3).map { URL(filePath: $0) },
    ownerUID: getuid(),
    launchdJobRemoval: ["bootout", "gui/\(getuid())/\(label)"],
    idleInterval: 2
))
