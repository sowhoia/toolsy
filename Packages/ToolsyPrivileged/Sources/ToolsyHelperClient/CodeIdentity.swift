import Foundation
import Security
import ToolsyShared

enum CodeIdentity {
    /// The code directory hash of the running process as 40 lowercase hex digits: what the helper's
    /// `cdhash H"…"` requirement must name for this build of the app.
    static func currentCDHash() throws -> String {
        var code: SecCode?
        try check(SecCodeCopySelf([], &code), "SecCodeCopySelf")
        guard let code else { throw failure("SecCodeCopySelf returned no code") }
        // Signing information is trustworthy only for code whose signature has been validated.
        try check(SecCodeCheckValidity(code, [], nil), "SecCodeCheckValidity")
        var staticCode: SecStaticCode?
        try check(SecCodeCopyStaticCode(code, [], &staticCode), "SecCodeCopyStaticCode")
        guard let staticCode else { throw failure("SecCodeCopyStaticCode returned no code") }
        var information: CFDictionary?
        try check(SecCodeCopySigningInformation(staticCode, [], &information), "SecCodeCopySigningInformation")
        // kSecCodeInfoUnique is one of the generic entries returned without extra flags.
        guard let information = information as? [String: Any], let unique = information[kSecCodeInfoUnique as String] as? Data else {
            throw failure("this build of Toolsy is not code signed")
        }
        guard unique.count == 20 else {
            throw failure("unexpected code directory hash length \(unique.count)")
        }
        return unique.map { String(format: "%02x", $0) }.joined()
    }

    private static func check(_ status: OSStatus, _ function: String) throws {
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            throw failure("\(function) failed: \(message)")
        }
    }

    private static func failure(_ message: String) -> PrivilegedError {
        .rejected("Cannot determine the code signature of Toolsy: \(message)")
    }
}
