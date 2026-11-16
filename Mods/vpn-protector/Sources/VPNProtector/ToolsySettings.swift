import Foundation

/// The mod's settings, edited as plain text in Toolsy. Lists are separated by commas and/or
/// whitespace. Parsing only splits the text into a `Policy`; `Policy.rules()` validates the values.
struct ToolsySettings: Decodable, Equatable {
    /// Local IP addresses of the tunnel.
    let tunnelAddresses: String
    /// `utunN` names; empty means any of `utun0`…`utun63`.
    let tunnelInterfaces: String
    /// `tcp://IPv4:port` or `udp://IPv4:port`, each optionally followed by `?uid=N`.
    let endpoints: String
    let allowDHCPv4: Bool

    private static let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))

    /// Reads the settings from the `state` of a Toolsy command input.
    static func decode(_ input: Data) throws -> ToolsySettings {
        struct CommandInput: Decodable {
            let state: ToolsySettings
        }
        func field(_ path: [any CodingKey]) -> String {
            path.map(\.stringValue).joined(separator: ".")
        }
        do {
            return try JSONDecoder().decode(CommandInput.self, from: input).state
        } catch DecodingError.keyNotFound(let key, let context) {
            throw GuardError("Во входных данных Toolsy нет поля \(field(context.codingPath + [key])).")
        } catch DecodingError.typeMismatch(_, let context) where !context.codingPath.isEmpty,
                DecodingError.valueNotFound(_, let context) where !context.codingPath.isEmpty {
            throw GuardError("Поле \(field(context.codingPath)) во входных данных Toolsy имеет неверный тип.")
        } catch {
            throw GuardError("Входные данные Toolsy должны быть JSON-объектом с полем state.")
        }
    }

    func policy() throws -> Policy {
        let interfaces = Self.items(tunnelInterfaces)
        return Policy(
            tunnelAddresses: Self.items(tunnelAddresses),
            tunnelInterfaces: interfaces.isEmpty ? nil : interfaces,
            endpoints: try Self.items(endpoints).map(Self.endpoint),
            allowDHCPv4: allowDHCPv4
        )
    }

    static func items(_ text: String) -> [String] {
        text.components(separatedBy: separators).filter { !$0.isEmpty }
    }

    static func endpoint(_ item: String) throws -> Policy.Endpoint {
        guard let scheme = item.range(of: "://"),
              let transport = Policy.Transport(rawValue: String(item[..<scheme.lowerBound])) else {
            throw GuardError("Сервер «\(item)»: начните адрес с tcp:// или udp://.")
        }
        var hostAndPort = item[scheme.upperBound...]
        var socketUID: UInt32?
        if let query = hostAndPort.firstIndex(of: "?") {
            let parameter = hostAndPort[hostAndPort.index(after: query)...]
            guard parameter.hasPrefix("uid="), let uid = decimal(parameter.dropFirst(4), as: UInt32.self) else {
                throw GuardError("Сервер «\(item)»: после «?» допускается только uid=N, где N — числовой UID.")
            }
            socketUID = uid
            hostAndPort = hostAndPort[..<query]
        }
        guard let colon = hostAndPort.lastIndex(of: ":"), colon != hostAndPort.startIndex,
              !hostAndPort[..<colon].contains(":") else {
            throw GuardError("Сервер «\(item)»: укажите IPv4-адрес и порт через двоеточие, например udp://192.0.2.10:51820.")
        }
        guard let port = decimal(hostAndPort[hostAndPort.index(after: colon)...], as: UInt16.self) else {
            throw GuardError("Сервер «\(item)»: порт должен быть числом от 1 до 65535.")
        }
        return Policy.Endpoint(
            address: String(hostAndPort[..<colon]), transport: transport, port: port, socketUID: socketUID
        )
    }

    /// Plain decimal digits only: the integer initialisers would also accept a sign.
    private static func decimal<T: FixedWidthInteger>(_ text: Substring, as _: T.Type) -> T? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return T(text)
    }
}
