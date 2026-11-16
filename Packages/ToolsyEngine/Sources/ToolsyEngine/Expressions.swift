import Foundation
import ToolsyShared

/// A `when` / `disabled` expression, as specified in MOD_FORMAT.md ("Expressions").
///
/// Grammar, loosest first: `or := and ('||' and)*`, `and := not ('&&' not)*`,
/// `not := '!' not | comparison`, `comparison := operand (op operand)?`,
/// `operand := key | number | string | true | false | null | '(' or ')'`.
public struct ModExpression: Sendable, Equatable {
    enum Comparison: String, Sendable {
        case equal = "==", notEqual = "!=", less = "<", lessOrEqual = "<=", greater = ">", greaterOrEqual = ">="
    }

    indirect enum Node: Sendable, Equatable {
        case key(String)
        case literal(JSONValue)
        case not(Node)
        case and(Node, Node)
        case or(Node, Node)
        case compare(Node, Comparison, Node)
    }

    let root: Node

    public init(_ source: String) throws(SyntaxError) {
        var parser = Parser(tokens: try Self.tokens(of: source))
        root = try parser.parseOr()
        if let extra = parser.peek {
            throw SyntaxError("unexpected \(extra.description)")
        }
    }

    public func evaluate(_ state: ModState) -> Bool {
        Self.isTrue(root, in: state)
    }

    private static func isTrue(_ node: Node, in state: ModState) -> Bool {
        switch node {
        case .key, .literal: value(of: node, in: state).isTruthy
        case .not(let operand): !isTrue(operand, in: state)
        case .and(let left, let right): isTrue(left, in: state) && isTrue(right, in: state)
        case .or(let left, let right): isTrue(left, in: state) || isTrue(right, in: state)
        case .compare(let left, let comparison, let right):
            compare(value(of: left, in: state), comparison, value(of: right, in: state))
        }
    }

    private static func value(of node: Node, in state: ModState) -> JSONValue {
        switch node {
        case .key(let key): state[key] ?? .null
        case .literal(let value): value
        default: .bool(isTrue(node, in: state))
        }
    }

    private static func compare(_ left: JSONValue, _ comparison: Comparison, _ right: JSONValue) -> Bool {
        switch comparison {
        case .equal: return left == right
        case .notEqual: return left != right
        default:
            // Ordering means something only between numbers.
            guard let left = left.numberValue, let right = right.numberValue else { return false }
            return switch comparison {
            case .less: left < right
            case .lessOrEqual: left <= right
            case .greater: left > right
            default: left >= right
            }
        }
    }
}

extension ModExpression {
    enum Token: Equatable {
        case word(String)
        case number(Double)
        case string(String)
        case symbol(String)

        var description: String {
            switch self {
            case .word(let word): "\"\(word)\""
            case .number(let number): "\"\(JSONValue.number(number).text)\""
            case .string(let text): "'\(text)'"
            case .symbol(let symbol): "\"\(symbol)\""
            }
        }
    }

    static func tokens(of source: String) throws(SyntaxError) -> [Token] {
        var tokens: [Token] = []
        let characters = Array(source)
        var index = 0
        func isWordStart(_ character: Character) -> Bool { character == "_" || (character.isASCII && character.isLetter) }
        func isWordPart(_ character: Character) -> Bool { isWordStart(character) || (character.isASCII && character.isNumber) }
        func isDigit(_ index: Int) -> Bool { index < characters.count && characters[index].isASCII && characters[index].isNumber }

        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
            } else if isWordStart(character) {
                let start = index
                while index < characters.count, isWordPart(characters[index]) { index += 1 }
                tokens.append(.word(String(characters[start..<index])))
            } else if isDigit(index) || (character == "-" && isDigit(index + 1)) {
                let start = index
                index += 1
                while isDigit(index) { index += 1 }
                if index < characters.count, characters[index] == ".", isDigit(index + 1) {
                    index += 1
                    while isDigit(index) { index += 1 }
                }
                let text = String(characters[start..<index])
                guard let number = Double(text) else { throw SyntaxError("\"\(text)\" is not a number") }
                tokens.append(.number(number))
            } else if character == "'" || character == "\"" {
                guard let end = characters[(index + 1)...].firstIndex(of: character) else {
                    throw SyntaxError("a string is not closed with \(character)")
                }
                tokens.append(.string(String(characters[(index + 1)..<end])))
                index = end + 1
            } else {
                let pair = index + 1 < characters.count ? String(characters[index...(index + 1)]) : ""
                if ["||", "&&", "==", "!=", "<=", ">="].contains(pair) {
                    tokens.append(.symbol(pair))
                    index += 2
                } else if "!<>()".contains(character) {
                    tokens.append(.symbol(String(character)))
                    index += 1
                } else {
                    throw SyntaxError("unexpected \"\(character)\"")
                }
            }
        }
        return tokens
    }

    struct Parser {
        let tokens: [Token]
        var position = 0

        init(tokens: [Token]) {
            self.tokens = tokens
        }

        var peek: Token? {
            position < tokens.count ? tokens[position] : nil
        }

        private mutating func take(_ symbol: String) -> Bool {
            guard peek == .symbol(symbol) else { return false }
            position += 1
            return true
        }

        mutating func parseOr() throws(SyntaxError) -> Node {
            var node = try parseAnd()
            while take("||") { node = .or(node, try parseAnd()) }
            return node
        }

        private mutating func parseAnd() throws(SyntaxError) -> Node {
            var node = try parseNot()
            while take("&&") { node = .and(node, try parseNot()) }
            return node
        }

        private mutating func parseNot() throws(SyntaxError) -> Node {
            take("!") ? .not(try parseNot()) : try parseComparison()
        }

        private mutating func parseComparison() throws(SyntaxError) -> Node {
            let left = try parseOperand()
            guard let comparison = comparisonAhead else { return left }
            position += 1
            let right = try parseOperand()
            if comparisonAhead != nil {
                throw SyntaxError("only one comparison is allowed without parentheses")
            }
            return .compare(left, comparison, right)
        }

        private var comparisonAhead: Comparison? {
            guard case .symbol(let symbol) = peek else { return nil }
            return Comparison(rawValue: symbol)
        }

        private mutating func parseOperand() throws(SyntaxError) -> Node {
            guard let token = peek else {
                throw SyntaxError("the expression ends where a value is expected")
            }
            position += 1
            switch token {
            case .number(let number): return .literal(.number(number))
            case .string(let text): return .literal(.string(text))
            case .word("true"): return .literal(true)
            case .word("false"): return .literal(false)
            case .word("null"): return .literal(nil)
            case .word(let key):
                guard ModManifest.isValidKey(key) else { throw SyntaxError("\"\(key)\" is not a valid state key") }
                return .key(key)
            case .symbol("("):
                let inner = try parseOr()
                guard take(")") else { throw SyntaxError("\"(\" is not closed") }
                return inner
            case .symbol:
                throw SyntaxError("unexpected \(token.description) where a value is expected")
            }
        }
    }
}
