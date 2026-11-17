import Foundation
import Testing
@testable import ToolsyShared

@Suite struct JSONNestingTests {
    private func nested(_ depth: Int) -> Data {
        Data((String(repeating: "[", count: depth) + String(repeating: "]", count: depth)).utf8)
    }

    @Test func countsBracketsOutsideStringsOnly() {
        #expect(JSONValue.nesting(of: Data(#"{"a": [1, {"b": "]]]}{{"}]}"#.utf8)) == 3)
        #expect(JSONValue.nesting(of: Data(#"["\"[[[", "\\", "{"]"#.utf8)) == 1)
        #expect(JSONValue.nesting(of: Data("42".utf8)) == 0)
        #expect(JSONValue.nesting(of: nested(1000)) == JSONValue.maxNesting + 1, "stops counting past the limit")
    }

    @Test func decodesUpToTheLimitAndRefusesDeeper() throws {
        _ = try JSONValue.decode(JSONValue.self, from: nested(JSONValue.maxNesting))
        #expect {
            try JSONValue.decode(JSONValue.self, from: nested(JSONValue.maxNesting + 1))
        } throws: { error in
            guard case DecodingError.dataCorrupted(let context) = error else { return false }
            return context.debugDescription == "the JSON is nested more than 64 levels deep"
        }
    }

    /// Five hundred levels, under the decoder's own limit, overflowed the 512 KB stack of a task that decoded them.
    @Test func aDeeplyNestedManifestIsAnError() {
        let data = Data((#"{"schema": 1, "id": "deep", "name": "Deep", "version": "1", "settings": {"x": "#
            + String(repeating: "[", count: 500) + String(repeating: "]", count: 500) + "}}").utf8)
        #expect(throws: ManifestError("the JSON is nested more than 64 levels deep")) {
            try ModManifest.load(from: data)
        }
    }
}
