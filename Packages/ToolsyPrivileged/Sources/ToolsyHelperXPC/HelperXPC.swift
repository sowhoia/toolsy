import Foundation

/// Names and locations the app, the installer and the helper agree on.
public enum HelperConstants {
    /// launchd label and Mach service name.
    public static let label = "app.toolsy.helper"
    public static let installedHelper = URL(filePath: "/Library/PrivilegedHelperTools/app.toolsy.helper")
    public static let launchdPlist = URL(filePath: "/Library/LaunchDaemons/app.toolsy.helper.plist")
    public static let store = URL(filePath: "/Library/Application Support/Toolsy")
    public static let clientRequirementFileName = "client-requirement"
    public static let clientUserFileName = "client-user"
    /// The helper inside the app bundle, relative to `Contents`.
    public static let bundledHelperPath = "Helpers/ToolsyHelper"
    /// Bump whenever `HelperXPCProtocol` changes, so the app notices an incompatible helper.
    public static let protocolVersion = 2
}

/// The helper's XPC interface. Every reply is delivered exactly once; failures arrive as an `NSError`
/// in `HelperFailure.domain`.
@objc public protocol HelperXPCProtocol {
    func hello(reply: @escaping @Sendable (_ protocolVersion: Int) -> Void)

    /// Mod id → digest of the stored snapshot.
    func approvedMods(reply: @escaping @Sendable (_ digests: [String: String], _ error: NSError?) -> Void)

    /// `files` maps relative paths to contents; `executables` lists the paths that carry the executable bit.
    func approve(
        modID: String, files: [String: Data], executables: [String],
        reply: @escaping @Sendable (_ error: NSError?) -> Void
    )

    /// Deletes the snapshot and, unless `keepingData`, the data folder of the mod's privileged commands.
    func revoke(modID: String, keepingData: Bool, reply: @escaping @Sendable (_ error: NSError?) -> Void)

    /// `input` is a JSON-encoded `CommandInput`.
    func run(
        modID: String, command: String, input: Data,
        reply: @escaping @Sendable (_ exitCode: Int32, _ stdout: Data, _ stderr: Data, _ timedOut: Bool, _ error: NSError?) -> Void
    )

    /// Runs the system's fixed memory-reclaim steps (see `SystemMaintaining`); takes nothing from the
    /// client. Each flag says whether that step succeeded.
    func reclaimMemory(reply: @escaping @Sendable (_ diskCacheFlushed: Bool, _ pressureWarningSent: Bool, _ error: NSError?) -> Void)

    /// Deletes the store, the launchd plist and the helper binary, replies, then unloads the job.
    func uninstall(reply: @escaping @Sendable (_ error: NSError?) -> Void)
}

public enum HelperInterface {
    /// The same interface on both ends, with the classes allowed inside collections spelled out so a
    /// peer cannot smuggle other classes into the decoder.
    public static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: HelperXPCProtocol.self)
        let approve = #selector(HelperXPCProtocol.approve(modID:files:executables:reply:))
        interface.setClasses(classes(NSDictionary.self, NSString.self, NSData.self), for: approve, argumentIndex: 1, ofReply: false)
        interface.setClasses(classes(NSArray.self, NSString.self), for: approve, argumentIndex: 2, ofReply: false)
        let approvedMods = #selector(HelperXPCProtocol.approvedMods(reply:))
        interface.setClasses(classes(NSDictionary.self, NSString.self), for: approvedMods, argumentIndex: 0, ofReply: true)
        return interface
    }

    /// Class objects are not Hashable in Swift; the API takes them as an Objective-C set.
    private static func classes(_ classes: AnyClass...) -> Set<AnyHashable> {
        // An NSSet of NSObject class objects always bridges to Set<AnyHashable>.
        NSSet(array: classes) as! Set<AnyHashable>
    }
}

/// Why the helper refused a request.
public enum HelperFailure: Int, Sendable {
    public static let domain = "app.toolsy.helper"

    /// Invalid arguments, a payload that breaks the rules, a failed file operation.
    case rejected = 1
    /// The mod has no approved snapshot.
    case notApproved = 2
    /// A command or a memory reclaim is running, and the request cannot be carried out until it has finished.
    case busy = 3

    public func error(_ message: String) -> NSError {
        NSError(domain: Self.domain, code: rawValue, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
