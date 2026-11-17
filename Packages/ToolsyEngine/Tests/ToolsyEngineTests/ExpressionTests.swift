import Foundation
import Testing
@testable import ToolsyEngine
import ToolsyShared

private func evaluate(_ expression: String, _ state: ModState = [:]) throws -> Bool {
    try ModExpression(expression).evaluate(state)
}

private func syntaxError(_ expression: String) -> String? {
    do {
        _ = try ModExpression(expression)
        return nil
    } catch {
        return error.message
    }
}

@Suite struct ExpressionTests {
    @Test func bareOperandsUseTruthiness() throws {
        let state: ModState = ["no": false, "zero": 0, "empty": "", "nothing": nil, "list": [], "yes": true, "one": 1, "text": "x", "minus": -1]
        for key in ["missing", "no", "zero", "empty", "nothing", "list"] {
            #expect(try !evaluate(key, state), "\(key)")
            #expect(try evaluate("!\(key)", state), "!\(key)")
        }
        for key in ["yes", "one", "text", "minus"] {
            #expect(try evaluate(key, state), "\(key)")
        }
        #expect(try evaluate("true") && !evaluate("false") && !evaluate("null") && !evaluate("0") && evaluate("'a'") && !evaluate("''"))
    }

    @Test func evaluatesTheDocumentedExamples() throws {
        #expect(try evaluate("mode == 'manual' && level >= 3", ["mode": "manual", "level": 3]))
        #expect(try !evaluate("mode == 'manual' && level >= 3", ["mode": "manual", "level": 2]))
        #expect(try !evaluate("mode == 'manual' && level >= 3", ["mode": "auto", "level": 9]))
        let example = #"(status == "Active" || retries < 5) && !error"#
        #expect(try evaluate(example, ["status": "Active", "retries": 9]))
        #expect(try evaluate(example, ["status": "Idle", "retries": 4]))
        #expect(try !evaluate(example, ["status": "Idle", "retries": 5]))
        #expect(try !evaluate(example, ["status": "Active", "error": "broken"]))
    }

    @Test func respectsPrecedence() throws {
        // && binds tighter than ||.
        #expect(try evaluate("a || b && c", ["a": true, "b": false, "c": false]))
        #expect(try !evaluate("(a || b) && c", ["a": true, "b": false, "c": false]))
        // ! is looser than a comparison: !a == b means !(a == b).
        #expect(try !evaluate("!a == b", ["a": 1, "b": 1]))
        #expect(try evaluate("!a == b", ["a": 1, "b": 2]))
        #expect(try evaluate("!a && b", ["a": false, "b": true]))
        #expect(try evaluate("!!a", ["a": 1]))
        #expect(try evaluate("((a))", ["a": 1]))
        #expect(try evaluate("(a && b) == false", ["a": true, "b": false]))
    }

    @Test func comparesValues() throws {
        let state: ModState = ["n": 2, "s": "b", "flag": true]
        #expect(try evaluate("n == 2.0 && n != 3 && n < 3 && n <= 2 && n > 1 && n >= 2", state))
        #expect(try evaluate("n > -3 && -1 < n", state))
        #expect(try evaluate("s == 'b' && s != \"c\" && flag == true", state))
        #expect(try evaluate("missing == null && missing != 0 && n != null", state))
        // Ordering only between numbers.
        #expect(try !evaluate("s > 'a'", state))
        #expect(try !evaluate("s < 'z'", state))
        #expect(try !evaluate("missing < 5", state))
        #expect(try !evaluate("'2' == 2", state))
    }

    @Test func rejectsMalformedExpressions() {
        #expect(syntaxError("")?.contains("ends where a value is expected") == true)
        #expect(syntaxError("a &&")?.contains("ends where a value is expected") == true)
        #expect(syntaxError("&& a")?.contains("unexpected \"&&\"") == true)
        #expect(syntaxError("(a") == #""(" is not closed"#)
        #expect(syntaxError("a)") == #"unexpected ")""#)
        #expect(syntaxError("a == b == c")?.contains("only one comparison") == true)
        #expect(syntaxError("a = b") == #"unexpected "=""#)
        #expect(syntaxError("a | b") == #"unexpected "|""#)
        #expect(syntaxError("a & b") == #"unexpected "&""#)
        #expect(syntaxError("'open")?.contains("not closed") == true)
        #expect(syntaxError("a b") == #"unexpected "b""#)
        #expect(syntaxError("1.2.3")?.contains("unexpected") == true)
        #expect(syntaxError("a == ") != nil)
        #expect(syntaxError("ä") != nil)
        #expect(syntaxError("enabled") == nil)
        #expect(syntaxError(" ( a || b ) && !c ") == nil)
    }

    /// Nested a few thousand levels deep, a `when` overflowed the stack of whoever parsed it: Toolsy crashed on
    /// opening such a file, before its install confirmation.
    @Test func boundsNestingAndLength() {
        let limit = ModExpression.maxNesting
        let deepest = String(repeating: "(", count: limit) + "a" + String(repeating: ")", count: limit)
        #expect(syntaxError(deepest) == nil)
        #expect(syntaxError("(" + deepest + ")") == "the expression is nested more than 32 levels deep")
        #expect(syntaxError(String(repeating: "!", count: limit) + "a") == nil)
        #expect(syntaxError(String(repeating: "!", count: limit + 1) + "a") == "the expression is nested more than 32 levels deep")
        #expect(syntaxError("!(" + String(repeating: "!", count: limit - 1) + "a)") == "the expression is nested more than 32 levels deep")

        let longest = Array(repeating: "a", count: 128).joined(separator: " || ")
        #expect(syntaxError(longest) == nil, "255 tokens")
        #expect(syntaxError(longest + " || a") == "the expression is longer than 256 tokens")
        #expect(syntaxError(String(repeating: "(", count: 5000) + "a" + String(repeating: ")", count: 5000)) != nil)
    }
}

@Suite struct ExpressionPathTests {
    private let state: ModState = ["disk": ["free": 20, "name": "HD"], "rows": [["title": "a"], ["title": "b"]], "text": "x"]

    @Test func readsPaths() throws {
        #expect(try evaluate("disk.free > 10 && disk.name == 'HD'", state))
        #expect(try evaluate("rows.1.title == 'b' && rows.0", state))
        #expect(try evaluate("rows.2 == null && text.x == null && disk.free.x == null && missing.x == null", state))
        #expect(try !evaluate("rows.2.title", state))
    }

    @Test func rejectsMalformedPaths() {
        #expect(syntaxError("a.") == #""a." is not a valid state key or path"#)
        #expect(syntaxError("a..b") == #""a..b" is not a valid state key or path"#)
        #expect(syntaxError("a.b.") == #""a.b." is not a valid state key or path"#)
        #expect(syntaxError("rows.0.title") == nil)
    }
}

@Suite struct ArithmeticTests {
    @Test func calculatesWithTheUsualPrecedence() throws {
        #expect(try evaluate("1 + 2 * 3 == 7"))
        #expect(try evaluate("(1 + 2) * 3 == 9"))
        #expect(try evaluate("10 - 4 - 3 == 3"), "left-associative")
        #expect(try evaluate("8 / 4 / 2 == 1"), "left-associative")
        #expect(try evaluate("7 % 4 == 3 && -7 % 4 == -3 && 7.5 % 2 == 1.5"))
        #expect(try evaluate("2 * 3 % 4 == 2"), "* and % share a level, left to right")
        #expect(try evaluate("used / total * 100 > 80", ["used": 90, "total": 100]))
        #expect(try !evaluate("used / total * 100 > 80", ["used": 50, "total": 100]))
        #expect(try evaluate("a + 1 > b - 1 && a * 2 == 4", ["a": 2, "b": 3]))
    }

    @Test func distinguishesMinusFromNegativeNumbers() throws {
        let state: ModState = ["a": 5]
        #expect(try evaluate("a-1 == 4", state))
        #expect(try evaluate("a -1 == 4", state))
        #expect(try evaluate("a - -1 == 6", state))
        #expect(try evaluate("(a)-1 == 4", state))
        #expect(try evaluate("2*-1 == -2"))
        #expect(try evaluate("-1 < a", state))
        #expect(syntaxError("-a") == #"unexpected "-" where a value is expected"#, "only numbers can be negative")
        #expect(try evaluate("'x'-1 == null"))
    }

    @Test func yieldsNullForNonNumbersAndDivisionByZero() throws {
        let state: ModState = ["n": 4, "s": "8", "flag": true, "list": [1]]
        for expression in ["s + 1", "n + s", "flag * 2", "list - 1", "missing + 1", "n / 0", "n % 0", "null + 1"] {
            #expect(try evaluate("\(expression) == null", state), "\(expression)")
            #expect(try !evaluate(expression, state), "\(expression) is falsy")
            #expect(try !evaluate("\(expression) > -1000", state), "\(expression) does not order")
        }
        #expect(try !evaluate("n - 4", state), "zero is falsy")
        #expect(try evaluate("n - 3", state))
        #expect(try evaluate("n / 0 + 1 == null", state), "null propagates")
    }

    @Test func notStillAppliesToTheWholeComparison() throws {
        #expect(try evaluate("!a + 1 == 3", ["a": 1]), "!(a + 1 == 3)")
        #expect(try !evaluate("!a + 1 == 2", ["a": 1]))
        #expect(try evaluate("!(a - 1)", ["a": 1]))
    }

    @Test func rejectsMalformedArithmetic() {
        #expect(syntaxError("a +")?.contains("ends where a value is expected") == true)
        #expect(syntaxError("* a") == #"unexpected "*" where a value is expected"#)
        #expect(syntaxError("a + * b") == #"unexpected "*" where a value is expected"#)
        #expect(syntaxError("a ** b") == #"unexpected "*" where a value is expected"#)
        #expect(syntaxError("a + b == c - d") == nil)
        #expect(syntaxError("a + b == c - d == e")?.contains("only one comparison") == true)
    }
}

@Suite struct ContainsTests {
    private let state: ModState = [
        "name": "MacBook Air", "tags": ["vpn", 2, true], "rows": [["id": "vpn"]], "count": 12, "empty": "",
    ]

    @Test func findsSubstrings() throws {
        #expect(try evaluate("name contains 'Air'", state))
        #expect(try !evaluate("name contains 'air'", state), "case-sensitive")
        #expect(try evaluate("name contains ''", state))
        #expect(try !evaluate("empty contains 'a'", state))
        #expect(try !evaluate("name contains 1", state))
    }

    @Test func findsScalarsInArrays() throws {
        #expect(try evaluate("tags contains 'vpn' && tags contains 2 && tags contains true", state))
        #expect(try !evaluate("tags contains 'VPN' || tags contains '2' || tags contains false", state))
        #expect(try !evaluate("rows contains 'vpn'", state), "only equal scalars count")
        #expect(try !evaluate("tags contains tags", state))
        #expect(try !evaluate("tags contains null", ["tags": [nil]]), "null is not a scalar")
    }

    @Test func aNegativeNumberCanFollowIt() throws {
        // `contains` ends no value, so the minus after it is a sign and not a subtraction.
        #expect(try evaluate("offsets contains -1", ["offsets": [-1, 2]]))
        #expect(try !evaluate("offsets contains -3", ["offsets": [-1, 2]]))
        #expect(try evaluate("offsets contains 2 -1", ["offsets": [1]]), "after a value a minus still subtracts")
    }

    @Test func isFalseForAnythingElseOnTheLeft() throws {
        #expect(try !evaluate("count contains 1", state))
        #expect(try !evaluate("missing contains 'a'", state))
        #expect(try !evaluate("rows.0 contains 'vpn'", state))
        #expect(try evaluate("!(missing contains 'a')", state))
    }

    @Test func sitsAtTheLevelOfComparisons() throws {
        #expect(try evaluate("name contains 'Air' && count > 10", state))
        #expect(try evaluate("!name contains 'x'", state), "!(name contains 'x')")
        #expect(try evaluate("(name contains 'Air') == true", state))
        #expect(syntaxError("name contains 'a' == true")?.contains("only one comparison") == true)
        #expect(syntaxError("contains") == #"unexpected "contains" where a value is expected"#)
        #expect(syntaxError("name contains") == "the expression ends where a value is expected")
        #expect(syntaxError("contains == 1") == #"unexpected "contains" where a value is expected"#)
    }
}
