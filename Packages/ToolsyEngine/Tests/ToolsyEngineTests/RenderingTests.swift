import Foundation
import Testing
@testable import ToolsyEngine
import ToolsyShared

/// What views pay for: patches that change nothing must not invalidate them, and templates and
/// expressions are parsed once, not on every render.
@MainActor @Suite struct RenderingTests {
    private let emitter = manifest(#"""
        "commands": {"emit": {"shell": "echo \"$TOOLSY_VALUE\""}, "quiet": {"shell": "true"}},
        "ui": [{"type": "chart", "series": [{"bind": "ms"}]}]
        """#)

    @Test func anIdenticalPatchLeavesStateAloneButAdvancesTheHistory() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(emitter)
            let patch: JSONValue = #"{"ms": 5, "status": "steady", "gone": null}"#
            await mod.run("emit", value: patch)
            #expect(mod.state["ms"] == 5 && mod.history(of: "ms") == [5])

            #expect(await !changes({ _ = mod.state }) { await mod.run("emit", value: patch) })
            #expect(mod.history(of: "ms") == [5, 5], "an unchanged number is still a sample: a flat line is data")
            #expect(await !changes({ _ = mod.state }) {
                await mod.run("quiet")
                mod.dismissError()
            })

            #expect(await changes({ _ = mod.state }) { await mod.run("emit", value: #"{"ms": 6}"#) })
            #expect(mod.state["ms"] == 6 && mod.status == "steady")
        }
    }

    @Test func rendersAndEvaluatesAgainstTheCurrentState() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(manifest(#"""
                "ui": [{"type": "text", "text": "{{n|fixed:1}} items", "when": "n > 1"}]
                """#))
            #expect(mod.render("{{n|fixed:1}} items") == " items" && !mod.evaluate("n > 1"))
            mod.setValue(2, for: "n")
            #expect(mod.render("{{n|fixed:1}} items") == "2.0 items" && mod.evaluate("n > 1"))
            mod.setValue(1, for: "n")
            #expect(mod.render("{{n|fixed:1}} items") == "1.0 items" && !mod.evaluate("n > 1"))
            for _ in 1...2 {
                #expect(mod.render("{{broken") == "{{broken", "text that does not parse stays as it is")
                #expect(!mod.evaluate("n >"), "an expression that does not parse is false")
            }
        }
    }

    /// `TOOLSY_BENCHMARK=1 swift test --filter renderingAPageOfFortyControls` prints how long 1 000
    /// renders of a page with 40 templated, conditional controls take, parsing every time as before
    /// and with the compiled sources.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOOLSY_BENCHMARK"] != nil))
    func renderingAPageOfFortyControls() async throws {
        try await withHarness { harness in
            let controls = (0..<40).map { #"{"type": "value", "label": "Metric \#($0)", "value": "{{m\#($0)|fixed:1|default:—}} of {{total|bytes}}", "when": "m\#($0) > 0 && !error"}"# }
            let mod = try await harness.install(manifest(#""ui": [\#(controls.joined(separator: ", "))]"#))
            for index in 0..<40 {
                mod.setValue(.number(Double(index) * 1.5), for: "m\(index)")
            }
            mod.setValue(123_456_789, for: "total")
            let templates = (0..<40).flatMap { ["Metric \($0)", "{{m\($0)|fixed:1|default:—}} of {{total|bytes}}"] }
            let expressions = (0..<40).map { "m\($0) > 0 && !error" }

            func page(_ render: (String) -> String, _ evaluate: (String) -> Bool) -> Int {
                var length = 0
                for (index, expression) in expressions.enumerated() where evaluate(expression) {
                    length += render(templates[2 * index]).count + render(templates[2 * index + 1]).count
                }
                return length
            }
            let state = mod.state
            let reparsing = { page({ try! ModTemplate($0).render(state) }, { try! ModExpression($0).evaluate(state) }) }
            let compiled = { page(mod.render, mod.evaluate) }
            #expect(reparsing() == compiled())

            let clock = ContinuousClock()
            let before = clock.measure { for _ in 0..<1_000 { _ = reparsing() } }
            let after = clock.measure { for _ in 0..<1_000 { _ = compiled() } }
            print("1 000 renders of 40 controls: parsing each time \(before), compiled once \(after)")
        }
    }
}
