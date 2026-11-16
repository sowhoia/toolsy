import Foundation
import ToolsyShared

/// A `when` / `disabled` expression, as specified in MOD_FORMAT.md ("Expressions").
///
/// Grammar, loosest first: `or := and ('||' and)*`, `and := not ('&&' not)*`,
/// `not := '!' not | comparison`, `comparison := sum (op sum)?`, `sum := product (('+' | '-') product)*`,
/// `product := operand (('*' | '/' | '%') operand)*`,
/// `operand := path | number | string | true | false | null | '(' or ')'`.
public struct ModExpression: Sendable, Equatable {
    enum Comparison: String, Sendable {
        case equal = "==", notEqual = "!=", less = "<", lessOrEqual = "<=", greater = ">", greaterOrEqual = ">="
        case contains
    }

    enum Arithmetic: String, Sendable {
        case add = "+", subtract = "-", multiply = "*", divide = "/", remainder = "%"
    }

    indirect enum Node: Sendable, Equatable {
        case path(StatePath)
        case literal(JSONValue)
        case not(Node)
        case and(Node, Node)
        case or(Node, Node)
        case compare(Node, Comparison, Node)
        case arithmetic(Node, Arithmetic, Node)
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
        case .path, .literal, .arithmetic: value(of: node, in: state).isTruthy
        case .not(let operand): !isTrue(operand, in: state)
        case .and(let left, let right): isTrue(left, in: state) && isTrue(right, in: state)
        case .or(let left, let right): isTrue(left, in: state) || isTrue(right, in: state)
        case .compare(let left, let comparison, let right):
            compare(value(of: left, in: state), comparison, value(of: right, in: state))
        }
    }

    private static func value(of node: Node, in state: ModState) -> JSONValue {
        switch node {
        case .path(let path): path.value(in: state) ?? .null
        case .literal(let value): value
        case .arithmetic(let left, let operation, let right):
            calculate(value(of: left, in: state), operation, value(of: right, in: state))
        default: .bool(isTrue(node, in: state))
        }
    }

    /// Arithmetic means something only between numbers; anything else, and a division by zero, is null.
    private static func calculate(_ left: JSONValue, _ operation: Arithmetic, _ right: JSONValue) -> JSONValue {
        guard let left = left.numberValue, let right = right.numberValue else { return .null }
        let result = switch operation {
        case .add: left + right
        case .subtract: left - right
        case .multiply: left * right
        case .divide: left / right
        case .remainder: left.truncatingRemainder(dividingBy: right)
        }
        return result.isFinite ? .number(result) : .null
    }

    private static func compare(_ left: JSONValue, _ comparison: Comparison, _ right: JSONValue) -> Bool {
        switch comparison {
        case .equal: return left == right
        case .notEqual: return left != right
        case .contains:
            switch (left, right) {
            case (.string(let text), .string(let part)): return part.isEmpty || text.contains(part)
            case (.array(let elements), _) where right.isScalar: return elements.contains(right)
            default: return false
            }
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

        /// Whether a `-` after this token subtracts rather than starting a negative number.
        var endsOperand: Bool {
            switch self {
            case .word, .number, .string: true
            case .symbol(let symbol): symbol == ")"
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
                // A path continues through dots: `disk.free`, `rows.0.title`.
                while index < characters.count, isWordPart(characters[index]) || characters[index] == "." { index += 1 }
                tokens.append(.word(String(characters[start..<index])))
            } else if isDigit(index) || (character == "-" && isDigit(index + 1) && !(tokens.last?.endsOperand ?? false)) {
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
                } else if "!<>()+-*/%".contains(character) {
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
            let left = try parseSum()
            guard let comparison = comparisonAhead else { return left }
            position += 1
            let right = try parseSum()
            if comparisonAhead != nil {
                throw SyntaxError("only one comparison is allowed without parentheses")
            }
            return .compare(left, comparison, right)
        }

        private var comparisonAhead: Comparison? {
            switch peek {
            case .symbol(let symbol)?: Comparison(rawValue: symbol)
            case .word("contains")?: .contains
            default: nil
            }
        }

        private mutating func parseSum() throws(SyntaxError) -> Node {
            var node = try parseProduct()
            while let operation = arithmeticAhead(.add, .subtract) {
                position += 1
                node = .arithmetic(node, operation, try parseProduct())
            }
            return node
        }

        private mutating func parseProduct() throws(SyntaxError) -> Node {
            var node = try parseOperand()
            while let operation = arithmeticAhead(.multiply, .divide, .remainder) {
                position += 1
                node = .arithmetic(node, operation, try parseOperand())
            }
            return node
        }

        private func arithmeticAhead(_ operations: Arithmetic...) -> Arithmetic? {
            guard case .symbol(let symbol)? = peek, let operation = Arithmetic(rawValue: symbol) else { return nil }
            return operations.contains(operation) ? operation : nil
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
            case .word("contains"):
                throw SyntaxError("unexpected \"contains\" where a value is expected")
            case .word(let word):
                guard let path = StatePath(word) else { throw SyntaxError("\"\(word)\" is not a valid state key or path") }
                return .path(path)
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
