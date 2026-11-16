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
}
