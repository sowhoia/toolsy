import Foundation
import ToolsyShared

/// `key` or `key.step.…`, as templates and expressions name a value: the first segment is a state key,
/// each further one indexes an object by key or an array by a non-negative integer.
struct StatePath: Sendable, Equatable {
    let key: String
    let steps: [String]

    /// Nil unless `text` is a valid key followed by steps of 1–64 letters, digits or `_`.
    init?(_ text: String) {
        let segments = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard ModManifest.isValidKey(segments[0]),
              segments.dropFirst().allSatisfy({ $0.wholeMatch(of: /[A-Za-z0-9_]{1,64}/) != nil })
        else { return nil }
        key = segments[0]
        steps = Array(segments.dropFirst())
    }

    /// Nil when a step finds nothing: a missing key or index, or a value that is not a container.
    func value(in state: ModState) -> JSONValue? {
        var value = state[key]
        for step in steps {
            switch value {
            case .object(let object)?:
                value = object[step]
            case .array(let array)?:
                guard let index = Int(step), array.indices.contains(index) else { return nil }
                value = array[index]
            default:
                return nil
            }
        }
        return value
    }
}
