import Darwin
import Foundation

let usage = """
VPN Protector — системный kill switch для macOS.

  vpn-protector check CONFIG
  sudo vpn-protector enable CONFIG
  sudo /Library/VPNProtector/vpn-protector status
  sudo /Library/VPNProtector/vpn-protector disable
  sudo /Library/VPNProtector/vpn-protector uninstall
"""

let arguments = Array(CommandLine.arguments.dropFirst())
let toolsyMode = arguments.count == 2 && arguments[1] == ToolsyMode.flag

do {
    let service = FirewallService()
    if toolsyMode {
        print(try ToolsyMode.run(arguments[0], service: service))
    } else {
        switch arguments.first {
        case nil, "help", "--help", "-h":
            print(usage)
        case "check", "enable":
            guard arguments.count == 2 else { throw GuardError(usage) }
            let rules = try Policy.read(arguments[1]).rules()
            if arguments[0] == "check" {
                print(try FirewallService.check(rules))
            } else {
                print(try service.withLock(createDirectory: true) { try service.enable(rules) })
            }
        case "status", "disable", "boot", "uninstall":
            guard arguments.count == 1 else { throw GuardError(usage) }
            try service.withLock {
                switch arguments[0] {
                case "status": print(try service.status())
                case "disable": print(try service.disable())
                case "uninstall": print(try service.uninstall())
                default: try service.boot()
                }
            }
        default:
            throw GuardError(usage)
        }
    }
} catch {
    let message = toolsyMode
        ? ToolsyMode.errorLine(error)
        : "VPN Protector — \(error.localizedDescription)\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(EXIT_FAILURE)
}
