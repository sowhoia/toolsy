import Foundation
import ToolsyEngine
import ToolsyShared

/// The tool was called wrongly: printed with the usage of `command` (the overview when nil), exit status 2.
struct UsageError: Error {
    let message: String
    let command: String?
}

/// The arguments after a command's name: positionals, and options anywhere among them as `--name value`,
/// `--name=value` or `--flag`. Unknown or repeated options are errors, never ignored.
struct Arguments {
    private(set) var positionals: [String] = []
    private var values: [String: String] = [:]
    private var flags: Set<String> = []
    let command: String

    /// `options` take a value, `switches` do not. Everything after `--` is positional.
    init(_ arguments: some Sequence<String>, command: String, options: Set<String> = [], switches: Set<String> = []) throws(UsageError) {
        self.command = command
        var rest = Array(arguments)[...]
        while let argument = rest.popFirst() {
            guard argument.hasPrefix("-"), argument.count > 1 else {
                positionals.append(argument)
                continue
            }
            if argument == "--" {
                positionals += rest
                break
            }
            let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let name = parts[0]
            if switches.contains(name) {
                guard parts.count == 1 else { throw UsageError(message: "\(name) takes no value", command: command) }
                guard flags.insert(name).inserted else { throw UsageError(message: "\(name) is given twice", command: command) }
            } else if options.contains(name) {
                guard values[name] == nil else { throw UsageError(message: "\(name) is given twice", command: command) }
                guard let value = parts.count == 2 ? parts[1] : rest.popFirst() else {
                    throw UsageError(message: "\(name) needs a value", command: command)
                }
                values[name] = value
            } else {
                throw UsageError(message: "unknown option \(name) for \(command)", command: command)
            }
        }
    }

    func value(_ option: String) -> String? {
        values[option]
    }

    func has(_ flag: String) -> Bool {
        flags.contains(flag)
    }

    /// The positionals, which must number within `range`; `names` describe them for the message.
    func positionals(_ range: ClosedRange<Int>, _ names: String) throws(UsageError) -> [String] {
        guard positionals.count >= range.lowerBound else {
            throw UsageError(message: "\(command) needs \(names)", command: command)
        }
        guard positionals.count <= range.upperBound else {
            let extra = positionals[range.upperBound...].map { "\"\($0)\"" }.joined(separator: " ")
            throw UsageError(message: "unexpected argument \(extra) for \(command)", command: command)
        }
        return positionals
    }

    /// The value of `option` read as JSON, or nil when it is not given.
    func json(_ option: String) throws(UsageError) -> JSONValue? {
        guard let text = value(option) else { return nil }
        switch CommandOutput(Data(text.utf8)) {
        case .patch(let object): return .object(object)
        case .notAnObject(let value): return value
        case .empty: throw UsageError(message: "\(option) needs a value", command: command)
        case .notJSON(let reason):
            throw UsageError(message: "\(option): not JSON (\(reason)); write text in quotes, as in \(option) '\"text\"'", command: command)
        }
    }
}
