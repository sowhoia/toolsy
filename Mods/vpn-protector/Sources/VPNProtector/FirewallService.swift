import Darwin
import Foundation

/// What `status` found. `unconfirmed` carries the reason shown to the user.
enum ProtectionState {
    case off
    case active
    case unconfirmed(String)
}

struct FirewallService {
    private static let label = "org.vpnprotector.guard"
    private static let launchTarget = "system/" + label
    private static let directory = URL(fileURLWithPath: "/Library/VPNProtector", isDirectory: true)
    private static let systemConfig = URL(fileURLWithPath: "/etc/pf.conf")
    private static let launchPlist = URL(fileURLWithPath: "/Library/LaunchDaemons/\(label).plist")
    private static let launchctl = "/bin/launchctl"
    private static let backup = directory.appendingPathComponent("pf.conf.original")
    private static let installation = directory.appendingPathComponent("installation.json")
    private static let referenceFile = directory.appendingPathComponent("pf-reference.json")
    private static let binary = directory.appendingPathComponent("vpn-protector")
    private static let filterAttachment = #"anchor "\#(Policy.anchor)" quick all"#
    private static let appleAttachment = Policy.appleAttachment + " all"
    private static let appleScrubAttachment = #"scrub-anchor "com.apple/*" all fragment reassemble"#

    private struct Installation: Codable, Equatable {
        let mainRules: String
        let compiledRules: [String]
    }

    private struct Reference: Codable {
        let token: String
        let ready: Bool
    }

    private let files = FileManager.default

    static func compile(_ rules: String) throws -> [String] {
        let output = try SystemCommand.pf(["-o", "none", "-n", "-v", "-a", Policy.anchor, "-f", "-"], input: rules)
        let compiled = output.commandLines.filter { $0.hasPrefix("pass ") || $0.hasPrefix("block ") }
        guard compiled.first == "pass quick on lo0 all no state", compiled.last == "block drop quick all" else {
            throw GuardError("pfctl не подтвердил политику блокировки.")
        }
        return compiled
    }

    static func check(_ rules: String) throws -> String {
        _ = try compile(rules)
        let stock = Policy.stockStatements.joined(separator: "\n") + "\n"
        let main = try Policy.mainRules(stock: stock, policy: rules)
        _ = try SystemCommand.pf(["-n", "-f", "-"], input: main)
        return "Конфигурация и синтаксис правил PF корректны."
    }

    func withLock<T>(createDirectory: Bool = false, _ operation: () throws -> T) throws -> T {
        guard geteuid() == 0 else { throw GuardError("Для этой команды нужен sudo.") }
        if !files.fileExists(atPath: Self.directory.path) {
            guard createDirectory else {
                return try operation()
            }
            do {
                try files.createDirectory(at: Self.directory, withIntermediateDirectories: false,
                                          attributes: [.posixPermissions: 0o700])
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && error.code == NSFileWriteFileExistsError {
                // Another invocation created the directory before acquiring the lock.
            }
        }
        try verifyOwner(of: Self.directory, type: .typeDirectory)
        let lockPath = Self.directory.appendingPathComponent("operation.lock").path
        let descriptor = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw GuardError("Не удалось открыть блокировку службы.") }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR { throw GuardError("Не удалось заблокировать параллельный запуск службы.") }
        }
        return try operation()
    }

    func enable(_ rules: String) throws -> String {
        let current = try readSystemConfig()
        let previous = try readInstallation()
        let stock = try originalConfig() ?? current
        let plan = Installation(mainRules: try Policy.mainRules(stock: stock, policy: rules),
                                compiledRules: try Self.compile(rules))
        guard previous == nil || previous == plan else {
            throw GuardError("Служба уже настроена с другими правилами. Остановите чувствительные приложения и выполните disable перед сменой конфигурации.")
        }
        guard current == stock || current == plan.mainRules else { throw modifiedConfig }

        try verifyLivePrerequisites()
        _ = try SystemCommand.pf(["-n", "-f", "-"], input: plan.mainRules)
        if !files.fileExists(atPath: Self.backup.path) {
            try Data(stock.utf8).write(to: Self.backup, options: .atomic)
        }
        try save(plan, to: Self.installation)
        try installLauncher()
        if current != plan.mainRules {
            try Data(plan.mainRules.utf8).write(to: Self.systemConfig, options: .atomic)
        }
        try arm(plan)
        _ = try SystemCommand.require(Self.launchctl, ["enable", Self.launchTarget])
        if try !launcherIsLoaded() {
            _ = try SystemCommand.require(Self.launchctl, ["bootstrap", "system", Self.launchPlist.path])
        }
        return "Фильтр включён. Проверьте VPN и отсутствие утечек по инструкции VALIDATION.md."
    }

    func boot() throws {
        guard let plan = try readInstallation() else { return }
        guard try readSystemConfig() == plan.mainRules else { throw modifiedConfig }
        try arm(plan)
    }

    func status() throws -> String {
        switch try protectionState() {
        case .off:
            return "VPN Protector выключен."
        case .unconfirmed(let reason):
            throw GuardError(reason)
        case .active:
            return "Фильтр активен и настроен на запуск при загрузке. Состояние самого VPN проверяйте в его клиенте."
        }
    }

    func protectionState() throws -> ProtectionState {
        guard let plan = try readInstallation() else { return .off }
        do {
            guard try readSystemConfig() == plan.mainRules,
                  try isArmed(plan),
                  try launcherIsLoaded() else {
                return .unconfirmed("Защита не подтверждена. Проверьте правила PF и повторите enable с той же конфигурацией.")
            }
        } catch {
            return .unconfirmed(error.localizedDescription)
        }
        return .active
    }

    func disable() throws -> String {
        guard let stock = try originalConfig() else {
            guard try readInstallation() == nil else {
                throw GuardError("Не найдена резервная копия /etc/pf.conf.")
            }
            return "VPN Protector выключен."
        }
        let current = try readSystemConfig()
        let plan = try readInstallation()
        guard current == stock || current == plan?.mainRules else { throw modifiedConfig }
        try verifyMainAttachments()
        _ = try SystemCommand.pf(["-n", "-f", "-"], input: stock)
        if try launcherIsLoaded() {
            _ = try SystemCommand.require(Self.launchctl, ["bootout", Self.launchTarget])
        }
        try removeIfPresent(Self.launchPlist)
        if current != stock {
            try Data(stock.utf8).write(to: Self.systemConfig, options: .atomic)
        }
        _ = try SystemCommand.pf(["-o", "none", "-R", "-f", Self.systemConfig.path])
        if let reference = try readOwnReference() {
            _ = try SystemCommand.pf(["-X", reference.token])
        }
        try removeIfPresent(Self.referenceFile)
        try removeIfPresent(Self.installation)
        try removeIfPresent(Self.backup)
        return "Фильтр VPN Protector выключен. Системная конфигурация PF восстановлена."
    }

    /// Deletes what `disable` leaves in `directory`: the copied binary, the boot log and the lock.
    func uninstall() throws -> String {
        let markers = [Self.installation, Self.backup, Self.referenceFile, Self.launchPlist]
        guard !markers.contains(where: { files.fileExists(atPath: $0.path) }) else {
            throw GuardError("Защита ещё установлена. Сначала выполните disable.")
        }
        guard files.fileExists(atPath: Self.directory.path) else {
            return "Файлов VPN Protector не осталось."
        }
        try verifyOwner(of: Self.directory, type: .typeDirectory)
        let leftovers: Set = [Self.binary.lastPathComponent, "launch.log", "operation.lock"]
        let names = try files.contentsOfDirectory(atPath: Self.directory.path)
        let unknown = names.filter { !leftovers.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw GuardError("В \(Self.directory.path) есть посторонние файлы: \(unknown.joined(separator: ", ")). Папка оставлена без изменений.")
        }
        // unlink and rmdir never follow symbolic links and never delete recursively.
        for name in names {
            let path = Self.directory.appendingPathComponent(name).path
            guard unlink(path) == 0 else {
                throw GuardError("Не удалось удалить \(path): \(String(cString: strerror(errno)))")
            }
        }
        guard rmdir(Self.directory.path) == 0 else {
            throw GuardError("Не удалось удалить \(Self.directory.path): \(String(cString: strerror(errno)))")
        }
        return "Файлы VPN Protector удалены из \(Self.directory.path)."
    }

    private func arm(_ plan: Installation) throws {
        if try isArmed(plan) { return }
        try verifyLivePrerequisites()
        var reference = try readOwnReference()
        if let reference {
            try save(Reference(token: reference.token, ready: false), to: Self.referenceFile)
        }
        _ = try SystemCommand.pf(["-o", "none", "-R", "-f", Self.systemConfig.path])
        try verifyGuardRules(plan)
        if reference == nil {
            reference = try acquireReference()
        }
        guard let reference, try pfIsEnabled() else {
            throw GuardError("PF не включился после установки правил.")
        }
        // PF consults its state table before filtering. Clear flows from the old policy
        // only after the new policy is loaded and PF is enabled.
        _ = try SystemCommand.pf(["-F", "states"])
        try verifyGuardRules(plan)
        try save(Reference(token: reference.token, ready: true), to: Self.referenceFile)
    }

    private func isArmed(_ plan: Installation) throws -> Bool {
        guard try readOwnReference()?.ready == true, try pfIsEnabled() else { return false }
        try verifyLivePrerequisites()
        return try guardRulesMatch(plan)
    }

    private func guardRulesMatch(_ plan: Installation) throws -> Bool {
        let main = try liveFilterRules()
        guard main.first == Self.filterAttachment else { return false }
        let active = try SystemCommand.pf(["-a", Policy.anchor, "-s", "rules"]).commandLines
        return active == plan.compiledRules
    }

    private func verifyGuardRules(_ plan: Installation) throws {
        try verifyLivePrerequisites()
        guard try guardRulesMatch(plan) else {
            throw GuardError("Активные правила PF отличаются от ожидаемых. Защита не подтверждена.")
        }
    }

    private func verifyMainAttachments() throws {
        let rules = try liveFilterRules()
        guard rules == [Self.filterAttachment, Self.appleAttachment]
                || rules == [Self.appleAttachment] || rules.isEmpty else {
            throw GuardError("Обнаружены другие активные правила PF. Операция остановлена.")
        }
    }

    private func liveFilterRules() throws -> [String] {
        let rules = try SystemCommand.pf(["-s", "rules"]).commandLines
        // macOS prints its stock packet normalization hook before the filter rules.
        return rules.first == Self.appleScrubAttachment ? Array(rules.dropFirst()) : rules
    }

    private func verifyLivePrerequisites() throws {
        try verifyMainAttachments()
        let interfaces = try SystemCommand.pf(["-v", "-s", "Interfaces"])
        let skippedInterfaces = interfaces.commandLines.filter { $0.hasSuffix(" (skip)") && $0 != "lo0 (skip)" }
        guard skippedInterfaces.isEmpty else { throw GuardError("PF пропускает один или несколько сетевых интерфейсов.") }
        let translations = try SystemCommand.pf(["-a", "*", "-s", "nat"]).commandLines
        guard !translations.contains(where: { $0.hasPrefix("nat ") || $0.hasPrefix("rdr ") || $0.hasPrefix("binat ") }) else {
            throw GuardError("Обнаружены активные правила трансляции PF. Выключите раздачу интернета и другие службы, меняющие PF.")
        }
    }

    private func pfIsEnabled() throws -> Bool {
        try SystemCommand.pf(["-s", "info"]).commandLines.contains { $0.hasPrefix("Status: Enabled") }
    }

    private func acquireReference() throws -> Reference {
        let output = try SystemCommand.pf(["-E"])
        guard let line = output.commandLines.first(where: { $0.hasPrefix("Token : ") }),
              let value = line.split(whereSeparator: \.isWhitespace).last,
              UInt64(value) != nil else {
            throw GuardError("Не удалось прочитать токен включения PF.")
        }
        let reference = Reference(token: String(value), ready: false)
        do {
            try save(reference, to: Self.referenceFile)
        } catch {
            _ = try? SystemCommand.pf(["-X", reference.token])
            throw error
        }
        return reference
    }

    private func readOwnReference() throws -> Reference? {
        guard let reference = try read(Reference.self, at: Self.referenceFile) else { return nil }
        let references = try SystemCommand.pf(["-s", "References"]).commandLines
        let held = references.contains { line in
            let columns = line.split(maxSplits: 3, whereSeparator: \.isWhitespace)
            return columns.count == 4 && columns[1] == "pfctl" && columns[2] == reference.token
        }
        return held ? reference : nil
    }

    private func installLauncher() throws {
        guard let executable = Bundle.main.executableURL else {
            throw GuardError("Не удалось определить путь к исполняемому файлу.")
        }
        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [Self.binary.path, "boot"],
            "RunAtLoad": true,
            "StandardErrorPath": Self.directory.appendingPathComponent("launch.log").path,
        ]
        if executable.resolvingSymlinksInPath() != Self.binary {
            try Data(contentsOf: executable).write(to: Self.binary, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Self.binary.path)
        }
        let payload = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try payload.write(to: Self.launchPlist, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o644], ofItemAtPath: Self.launchPlist.path)
    }

    private func launcherIsLoaded() throws -> Bool {
        try SystemCommand.run(Self.launchctl, ["print", Self.launchTarget]).status == 0
    }

    private var modifiedConfig: GuardError {
        GuardError("/etc/pf.conf был изменён. Файл оставлен без изменений, оригинал хранится в \(Self.backup.path).")
    }

    private func readSystemConfig() throws -> String {
        try verifyOwner(of: Self.systemConfig, type: .typeRegular)
        return try String(contentsOf: Self.systemConfig, encoding: .utf8)
    }

    private func originalConfig() throws -> String? {
        guard files.fileExists(atPath: Self.backup.path) else { return nil }
        return try String(contentsOf: Self.backup, encoding: .utf8)
    }

    private func readInstallation() throws -> Installation? {
        try read(Installation.self, at: Self.installation)
    }

    private func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T? {
        guard files.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private func save<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    private func verifyOwner(of url: URL, type: FileAttributeType) throws {
        let attributes = try files.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == type,
              (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
              let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              mode & 0o022 == 0 else {
            throw GuardError("Небезопасный владелец, тип файла или права доступа: \(url.path)")
        }
    }

    private func removeIfPresent(_ url: URL) throws {
        if files.fileExists(atPath: url.path) {
            try files.removeItem(at: url)
        }
    }
}
