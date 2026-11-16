import Foundation

/// `vpn-protector COMMAND --toolsy`: the Toolsy mod command protocol. Configuration arrives as the
/// mod's settings in the JSON command input on stdin; the result is one JSON state patch on stdout.
enum ToolsyMode {
    static let flag = "--toolsy"
    /// Bounds what is read from stdin; this runs as root on data from a user-level process.
    static let inputLimit = 1 << 20

    static func run(_ command: String, service: FirewallService) throws -> String {
        let patch: StatePatch
        switch command {
        case "check":
            let rules = try ToolsySettings.decode(readInput()).policy().rules()
            patch = StatePatch(checkResult: try FirewallService.check(rules))
        case "enable":
            let rules = try ToolsySettings.decode(readInput()).policy().rules()
            _ = try service.withLock(createDirectory: true) { try service.enable(rules) }
            patch = .protectionOn
        case "disable":
            _ = try service.withLock { try service.disable() }
            patch = .protectionOff
        case "status":
            patch = StatePatch(try service.withLock { try service.protectionState() })
        case "uninstall":
            _ = try service.withLock { try service.uninstall() }
            patch = StatePatch()
        default:
            throw GuardError("Неизвестная команда: \(command)")
        }
        return try patch.json()
    }

    /// Toolsy shows the last line of stderr as the error, so the whole message goes on one line.
    static func errorLine(_ error: any Error) -> String {
        error.localizedDescription.commandLines.filter { !$0.isEmpty }.joined(separator: " ") + "\n"
    }

    private static func readInput() throws -> Data {
        var data = Data()
        while let chunk = try FileHandle.standardInput.read(upToCount: 65_536), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= inputLimit else {
                throw GuardError("Входные данные Toolsy превышают \(inputLimit) байт.")
            }
        }
        return data
    }
}

/// The JSON object a Toolsy command prints. Unset fields are left out of the patch.
struct StatePatch: Encodable {
    enum Level: String, Encodable {
        case ok, off, error
    }

    var enabled: Bool?
    var status: String?
    var level: Level?
    var error: String?
    var checkResult: String?

    static let protectionOn = StatePatch(enabled: true, status: "Защита включена", level: .ok)
    static let protectionOff = StatePatch(enabled: false, status: "Защита выключена", level: .off)

    func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

extension StatePatch {
    /// `enabled` stays true while an installation exists, so the user can switch the mod off to clean up.
    init(_ state: ProtectionState) {
        switch state {
        case .off: self = .protectionOff
        case .active: self = .protectionOn
        case .unconfirmed(let reason):
            self.init(enabled: true, status: "Защита не подтверждена", level: .error, error: reason)
        }
    }
}
