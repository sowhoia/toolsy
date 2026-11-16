import Foundation
import ToolsyShared

/// Runs a shell command as root through the system administrator prompt.
///
/// `do shell script … with administrator privileges` executed in-process by `NSAppleScript` shows the
/// prompt on behalf of Toolsy itself (running `osascript` would attribute it to osascript). The call
/// blocks until the user answers, so it runs on its own serial queue, never on the main thread:
/// AppleScript has been thread-safe since macOS 10.6 as long as one script is not used from two
/// threads at once, which the serial queue guarantees.
///
/// With AppKit's event loop running on the main thread, as in the app, the script executes on the
/// calling thread and leaves the main thread free (measured: a trivial command returns in about 40 ms
/// and the main thread never stalls). A process without that loop behaves differently: the first
/// script it starts off the main thread waits tens of seconds for an event nothing services, which
/// is why the tests load the scripting additions on the main thread first.
enum AdministratorPrompt {
    private static let queue = DispatchQueue(label: "app.toolsy.administrator-prompt")
    /// AppleScript's "User canceled." error, raised when the prompt is dismissed.
    static let userCanceled = -128

    static func run(shellCommand: String) async throws {
        try await execute(appleScript(running: shellCommand, withAdministratorPrivileges: true))
    }

    /// Tests run the same text without the elevation clause.
    static func appleScript(running shellCommand: String, withAdministratorPrivileges: Bool) -> String {
        let literal = shellCommand.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"")
        return "tell current application to do shell script \"\(literal)\"" + (withAdministratorPrivileges ? " with administrator privileges" : "")
    }

    static func execute(_ source: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(throwing: PrivilegedError.rejected("The installer script could not be prepared."))
                    return
                }
                var errorInfo: NSDictionary?
                script.executeAndReturnError(&errorInfo)
                guard let errorInfo else {
                    continuation.resume()
                    return
                }
                let number = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue
                if number == userCanceled {
                    continuation.resume(throwing: PrivilegedError.cancelled)
                } else {
                    let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "AppleScript error \(number.map(String.init) ?? "unknown")"
                    continuation.resume(throwing: PrivilegedError.rejected("The administrator script failed: \(message)"))
                }
            }
        }
    }
}
