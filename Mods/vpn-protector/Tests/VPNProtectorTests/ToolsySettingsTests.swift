import Foundation
import Testing
@testable import VPNProtector

/// The message of the error `body` throws, or nil if it does not throw.
private func failure(_ body: () throws -> Void) -> String? {
    do {
        try body()
        return nil
    } catch {
        return error.localizedDescription
    }
}

private func settings(
    addresses: String = "198.18.0.1", interfaces: String = "", endpoints: String = "udp://192.0.2.10:51820",
    dhcp: Bool = true
) -> ToolsySettings {
    ToolsySettings(tunnelAddresses: addresses, tunnelInterfaces: interfaces, endpoints: endpoints, allowDHCPv4: dhcp)
}

@Suite struct SettingsParsingTests {
    @Test func splitsOnCommasAndWhitespace() {
        #expect(ToolsySettings.items("a,b c\td\ne , ,f,,") == ["a", "b", "c", "d", "e", "f"])
        #expect(ToolsySettings.items("") == [])
        #expect(ToolsySettings.items(" ,\n, ") == [])
    }

    @Test func buildsPolicyFromSettings() throws {
        let policy = try settings(
            addresses: "198.18.0.1, fd00::2", interfaces: "utun4 utun7",
            endpoints: "udp://192.0.2.10:51820,\ntcp://192.0.2.11:443?uid=501", dhcp: false
        ).policy()
        #expect(policy.tunnelAddresses == ["198.18.0.1", "fd00::2"])
        #expect(policy.tunnelInterfaces == ["utun4", "utun7"])
        #expect(policy.allowDHCPv4 == false)
        #expect(policy.endpoints.count == 2)
        #expect(policy.endpoints[0].address == "192.0.2.10")
        #expect(policy.endpoints[0].transport == .udp)
        #expect(policy.endpoints[0].port == 51820)
        #expect(policy.endpoints[0].socketUID == nil)
        #expect(policy.endpoints[1].address == "192.0.2.11")
        #expect(policy.endpoints[1].transport == .tcp)
        #expect(policy.endpoints[1].port == 443)
        #expect(policy.endpoints[1].socketUID == 501)
    }

    @Test func emptyInterfacesMeanAnyUtun() throws {
        #expect(try settings(interfaces: " , ").policy().tunnelInterfaces == nil)
    }

    @Test func acceptsLeadingZerosAndTheFullRange() throws {
        let endpoint = try ToolsySettings.endpoint("udp://192.0.2.10:065535?uid=0")
        #expect(endpoint.port == 65535)
        #expect(endpoint.socketUID == 0)
        #expect(try ToolsySettings.endpoint("tcp://192.0.2.10:1?uid=4294967295").socketUID == UInt32.max)
    }

    private static let scheme = "начните адрес с tcp:// или udp://."
    private static let host = "укажите IPv4-адрес и порт через двоеточие, например udp://192.0.2.10:51820."
    private static let port = "порт должен быть числом от 1 до 65535."
    private static let uid = "после «?» допускается только uid=N, где N — числовой UID."

    @Test(arguments: [
        ("192.0.2.10:51820", Self.scheme),
        ("UDP://192.0.2.10:51820", Self.scheme),
        ("icmp://192.0.2.10:1", Self.scheme),
        ("udp:/192.0.2.10:51820", Self.scheme),
        ("udp://192.0.2.10", Self.host),
        ("udp://:51820", Self.host),
        ("udp://[2001:db8::1]:51820", Self.host),
        ("udp://2001:db8::1:51820", Self.host),
        ("udp://192.0.2.10:", Self.port),
        ("udp://192.0.2.10:65536", Self.port),
        ("udp://192.0.2.10:+5", Self.port),
        ("udp://192.0.2.10:-1", Self.port),
        ("udp://192.0.2.10:5x", Self.port),
        ("udp://192.0.2.10:٥", Self.port),
        ("udp://192.0.2.10:51820?", Self.uid),
        ("udp://192.0.2.10:51820?uid=", Self.uid),
        ("udp://192.0.2.10:51820?uid=-1", Self.uid),
        ("udp://192.0.2.10:51820?uid=4294967296", Self.uid),
        ("udp://192.0.2.10:51820?gid=20", Self.uid),
        ("udp://192.0.2.10:51820?uid=501&x=1", Self.uid),
        ("udp://192.0.2.10:51820?uid=501?uid=502", Self.uid),
    ])
    func rejectsMalformedEndpoint(item: String, reason: String) {
        #expect(failure { _ = try ToolsySettings.endpoint(item) } == "Сервер «\(item)»: \(reason)")
    }

    // Values that parse but are not acceptable are left to the existing Policy validation.
    @Test(arguments: [
        (settings(addresses: ""), "Укажите от 1 до 4 адресов туннеля и от 1 до 8 адресов сервера с портами."),
        (settings(endpoints: ""), "Укажите от 1 до 4 адресов туннеля и от 1 до 8 адресов сервера с портами."),
        (settings(addresses: "198.18.0.1/32"), "Ожидается отдельный числовой IP без порта, маски и имени интерфейса."),
        (settings(addresses: "fe80::1"), "IPv6-адрес туннеля должен быть глобальным или ULA."),
        (settings(addresses: "198.18.0.1 198.18.0.1"), "Адрес туннеля указан несколько раз: 198.18.0.1"),
        (settings(interfaces: "en0"), "В tunnelInterfaces укажите от 1 до 64 уникальных имён интерфейсов utun, например utun244."),
        (settings(interfaces: "utun1, utun1"), "В tunnelInterfaces укажите от 1 до 64 уникальных имён интерфейсов utun, например utun244."),
        (settings(endpoints: "udp://192.0.2.10:0"), "Серверу нужен отдельный числовой IPv4-адрес и порт в диапазоне 1…65535."),
        (settings(endpoints: "udp://198.18.0.1:51820"), "Серверу нужен отдельный числовой IPv4-адрес и порт в диапазоне 1…65535."),
        (settings(endpoints: "udp://vpn.example:51820"), "Ожидается отдельный числовой IP без порта, маски и имени интерфейса."),
        (settings(endpoints: "udp://127.0.0.1:51820"), "Адрес должен быть одноадресным и находиться вне loopback."),
        (settings(endpoints: "udp://192.0.2.10:1 udp://192.0.2.10:1"), "Правило адреса сервера указано несколько раз."),
    ])
    func policyValidationStillApplies(settings: ToolsySettings, message: String) {
        #expect(failure { _ = try settings.policy().rules() } == message)
    }
}

@Suite struct RulesEquivalenceTests {
    /// Rules from the settings must equal the rules the original CLI builds from its JSON config.
    @Test(arguments: [
        (settings(), #"{"tunnelAddresses": ["198.18.0.1"], "endpoints": [{"address": "192.0.2.10", "transport": "udp", "port": 51820}], "allowDHCPv4": true}"#),
        (
            settings(addresses: "198.18.0.1 2001:db8:0:0::7", interfaces: "utun244,utun3",
                     endpoints: "udp://192.0.2.10:51820 tcp://192.0.2.11:443?uid=501", dhcp: false),
            #"{"tunnelAddresses": ["198.18.0.1", "2001:db8:0:0::7"], "tunnelInterfaces": ["utun244", "utun3"], "endpoints": [{"address": "192.0.2.10", "transport": "udp", "port": 51820}, {"address": "192.0.2.11", "transport": "tcp", "port": 443, "socketUID": 501}], "allowDHCPv4": false}"#
        ),
    ])
    func matchesOriginalConfig(settings: ToolsySettings, config: String) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vpn-protector-\(UUID().uuidString).json")
        try Data(config.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let expected = try Policy.read(file.path).rules()
        #expect(try settings.policy().rules() == expected)
    }

    @Test func ipv6TunnelAddressProducesInet6Rule() throws {
        let rules = try settings(addresses: "fd00::0002", interfaces: "utun5").policy().rules()
        #expect(rules.contains("pass out quick on { utun5 } inet6 from fd00::2 to any keep state (if-bound)\n"))
    }
}

@Suite struct CommandInputTests {
    private func input(_ state: String) -> Data {
        Data(#"{"event": "enable", "command": "enable", "state": {\#(state)}}"#.utf8)
    }

    private let valid = #""tunnelAddresses": "198.18.0.1", "tunnelInterfaces": "", "endpoints": "udp://192.0.2.10:51820", "allowDHCPv4": true"#

    @Test func readsSettingsAndIgnoresLiveState() throws {
        let decoded = try ToolsySettings.decode(input(valid + #", "enabled": false, "status": "x", "rows": [1]"#))
        #expect(decoded == settings())
    }

    @Test func rejectsMissingField() {
        #expect(failure { _ = try ToolsySettings.decode(input(#""tunnelAddresses": "", "tunnelInterfaces": "", "allowDHCPv4": true"#)) }
            == "Во входных данных Toolsy нет поля state.endpoints.")
        #expect(failure { _ = try ToolsySettings.decode(Data(#"{"event": "enable"}"#.utf8)) }
            == "Во входных данных Toolsy нет поля state.")
    }

    @Test func rejectsWrongTypes() {
        #expect(failure { _ = try ToolsySettings.decode(input(valid.replacingOccurrences(of: "true", with: "1"))) }
            == "Поле state.allowDHCPv4 во входных данных Toolsy имеет неверный тип.")
        #expect(failure { _ = try ToolsySettings.decode(input(valid.replacingOccurrences(of: #""198.18.0.1""#, with: #"["198.18.0.1"]"#))) }
            == "Поле state.tunnelAddresses во входных данных Toolsy имеет неверный тип.")
        #expect(failure { _ = try ToolsySettings.decode(input(valid.replacingOccurrences(of: #""""#, with: "null"))) }
            == "Поле state.tunnelInterfaces во входных данных Toolsy имеет неверный тип.")
        #expect(failure { _ = try ToolsySettings.decode(Data(#"{"state": []}"#.utf8)) }
            == "Поле state во входных данных Toolsy имеет неверный тип.")
    }

    @Test(arguments: ["", "not json", "[]", "\"text\"", #"{"state": {"#])
    func rejectsInvalidJSON(text: String) {
        #expect(failure { _ = try ToolsySettings.decode(Data(text.utf8)) }
            == "Входные данные Toolsy должны быть JSON-объектом с полем state.")
    }
}

@Suite struct StatePatchTests {
    @Test func patchForEachOutcome() throws {
        #expect(try StatePatch.protectionOn.json() == #"{"enabled":true,"level":"ok","status":"Защита включена"}"#)
        #expect(try StatePatch.protectionOff.json() == #"{"enabled":false,"level":"off","status":"Защита выключена"}"#)
        #expect(try StatePatch(.off).json() == StatePatch.protectionOff.json())
        #expect(try StatePatch(.active).json() == StatePatch.protectionOn.json())
        #expect(try StatePatch(.unconfirmed("PF пропускает /dev/x \"y\"")).json()
            == #"{"enabled":true,"error":"PF пропускает /dev/x \"y\"","level":"error","status":"Защита не подтверждена"}"#)
        #expect(try StatePatch(checkResult: "Конфигурация и синтаксис правил PF корректны.").json()
            == #"{"checkResult":"Конфигурация и синтаксис правил PF корректны."}"#)
        #expect(try StatePatch().json() == "{}")
    }

    @Test func errorsBecomeOneLine() {
        let error = GuardError("/sbin/pfctl -n -f - завершилась с кодом 1.\nstdin:3: syntax error\n  \npfctl: Syntax error in config file\n")
        #expect(ToolsyMode.errorLine(error)
            == "/sbin/pfctl -n -f - завершилась с кодом 1. stdin:3: syntax error pfctl: Syntax error in config file\n")
    }
}
