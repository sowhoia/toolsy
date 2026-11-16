import Darwin
import Foundation

struct GuardError: LocalizedError {
    let errorDescription: String?

    init(_ description: String) {
        errorDescription = description
    }
}

struct Policy: Decodable {
    enum Transport: String, Decodable { case tcp, udp }

    struct Endpoint: Decodable {
        let address: String
        let transport: Transport
        let port: UInt16
        let socketUID: UInt32?
    }

    let tunnelAddresses: [String]
    let tunnelInterfaces: [String]?
    let endpoints: [Endpoint]
    let allowDHCPv4: Bool

    static let anchor = "org.vpnprotector.guard"
    static let appleAttachment = #"anchor "com.apple/*""#

    static let stockStatements = [
        #"scrub-anchor "com.apple/*""#,
        #"nat-anchor "com.apple/*""#,
        #"rdr-anchor "com.apple/*""#,
        #"dummynet-anchor "com.apple/*""#,
        appleAttachment,
        #"load anchor "com.apple" from "/etc/pf.anchors/com.apple""#,
    ]

    static func read(_ path: String) throws -> Policy {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let object = try JSONSerialization.jsonObject(with: data)
        let requiredFields: Set = ["tunnelAddresses", "endpoints", "allowDHCPv4"]
        guard let dictionary = object as? [String: Any],
              requiredFields.isSubset(of: dictionary.keys),
              Set(dictionary.keys).isSubset(of: requiredFields.union(["tunnelInterfaces"])),
              let endpoints = dictionary["endpoints"] as? [[String: Any]],
              endpoints.allSatisfy({ Set($0.keys).isSubset(of: ["address", "transport", "port", "socketUID"]) }) else {
            throw GuardError("Ожидаются поля tunnelAddresses, endpoints и allowDHCPv4. Проверьте config.example.json.")
        }
        return try JSONDecoder().decode(Policy.self, from: data)
    }

    func rules() throws -> String {
        guard (1...4).contains(tunnelAddresses.count), (1...8).contains(endpoints.count) else {
            throw GuardError("Укажите от 1 до 4 адресов туннеля и от 1 до 8 адресов сервера с портами.")
        }
        let interfaceNames = tunnelInterfaces ?? (0..<64).map { "utun\($0)" }
        guard (1...64).contains(interfaceNames.count), Set(interfaceNames).count == interfaceNames.count,
              interfaceNames.allSatisfy({ name in
                  guard name.hasPrefix("utun"), let number = UInt32(name.dropFirst(4)) else { return false }
                  return name == "utun\(number)"
              }) else {
            throw GuardError("В tunnelInterfaces укажите от 1 до 64 уникальных имён интерфейсов utun, например utun244.")
        }
        let interfaces = interfaceNames.joined(separator: ", ")
        var rules = ["pass quick on lo0 all no state"]
        var tunnelIPs = Set<String>()
        for address in tunnelAddresses {
            let ip = try IPAddress(address)
            guard tunnelIPs.insert(ip.literal).inserted else {
                throw GuardError("Адрес туннеля указан несколько раз: \(ip.literal)")
            }
            // An interface number can change during reconnect. Match the local tunnel IP as well.
            rules.append("pass out quick on { \(interfaces) } \(ip.family) from \(ip.literal) to any keep state (if-bound)")
        }
        var endpointRules = Set<String>()
        for endpoint in endpoints {
            let ip = try IPAddress(endpoint.address)
            guard ip.family == "inet", endpoint.port > 0, !tunnelIPs.contains(ip.literal) else {
                throw GuardError("Серверу нужен отдельный числовой IPv4-адрес и порт в диапазоне 1…65535.")
            }
            let user = endpoint.socketUID.map { " user \($0)" } ?? ""
            // The VPN transport may already be established when activation clears old states.
            let flags = endpoint.transport == .tcp ? " flags any" : ""
            let rule = "pass out quick inet proto \(endpoint.transport.rawValue) from any to \(ip.literal) port \(endpoint.port)\(user)\(flags) keep state (if-bound)"
            guard endpointRules.insert(rule).inserted else {
                throw GuardError("Правило адреса сервера указано несколько раз.")
            }
            rules.append(rule)
        }
        if allowDHCPv4 {
            rules.append("pass out quick inet proto udp from any port 68 to 255.255.255.255 port 67 no state")
            rules.append("pass in quick inet proto udp from any port 67 to any port 68 no state")
        }
        rules.append("block drop quick all")
        return rules.joined(separator: "\n") + "\n"
    }

    static func mainRules(stock: String, policy: String) throws -> String {
        let statements = stock.components(separatedBy: "\n").compactMap { line -> String? in
            let statement = line.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces)
            return statement.isEmpty ? nil : statement
        }
        guard statements == stockStatements else {
            throw GuardError("В /etc/pf.conf найдена нестандартная конфигурация. Для неё нужно вручную согласовать правила PF.")
        }
        let block = policy.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n")
        let attachment = """
        # VPN Protector
        anchor "\(anchor)" quick {
        \(block)
        }
        \(appleAttachment)
        """
        // Replace only the active statement, never a comment or similarly named rule.
        var lines = stock.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: {
            $0.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces) == appleAttachment
        }) else {
            throw GuardError("Не найдена точка подключения правил PF.")
        }
        lines[index] = attachment
        return "set ruleset-optimization none\n" + lines.joined(separator: "\n")
    }
}

private struct IPAddress {
    let family: String
    let literal: String

    init(_ input: String) throws {
        guard input.utf8.count <= 45, input.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) || $0 == 46 || $0 == 58
        }) else {
            throw GuardError("Ожидается отдельный числовой IP без порта, маски и имени интерфейса.")
        }

        var v4 = in_addr()
        var v6 = in6_addr()
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if inet_pton(AF_INET, input, &v4) == 1 {
            let first = UInt32(bigEndian: v4.s_addr) >> 24
            guard (1..<224).contains(first), first != 127 else {
                throw GuardError("Адрес должен быть одноадресным и находиться вне loopback.")
            }
            family = "inet"
            inet_ntop(AF_INET, &v4, &buffer, socklen_t(buffer.count))
        } else if inet_pton(AF_INET6, input, &v6) == 1 {
            let first = v6.__u6_addr.__u6_addr8.0
            guard (0x20...0x3f).contains(first) || (0xfc...0xfd).contains(first) else {
                throw GuardError("IPv6-адрес туннеля должен быть глобальным или ULA.")
            }
            family = "inet6"
            inet_ntop(AF_INET6, &v6, &buffer, socklen_t(buffer.count))
        } else {
            throw GuardError("Некорректный числовой IP-адрес.")
        }
        literal = String(cString: buffer)
    }
}
