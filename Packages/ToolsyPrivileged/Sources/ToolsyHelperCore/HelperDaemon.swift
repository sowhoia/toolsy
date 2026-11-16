import Foundation
import os
import ToolsyHelperXPC

/// Everything that differs between the installed daemon and a test instance of it.
public struct HelperConfiguration: Sendable {
    public var machServiceName: String
    public var storeRoot: URL
    /// Deleted on uninstall together with the store.
    public var installedFiles: [URL]
    /// The process must run as this user, and the store must be owned by it.
    public var ownerUID: uid_t
    /// Arguments to `/bin/launchctl` that unload the job after an uninstall.
    public var launchdJobRemoval: [String]
    /// Seconds without connections and operations after which the process exits.
    public var idleInterval: TimeInterval

    public init(
        machServiceName: String, storeRoot: URL, installedFiles: [URL], ownerUID: uid_t,
        launchdJobRemoval: [String], idleInterval: TimeInterval
    ) {
        self.machServiceName = machServiceName
        self.storeRoot = storeRoot
        self.installedFiles = installedFiles
        self.ownerUID = ownerUID
        self.launchdJobRemoval = launchdJobRemoval
        self.idleInterval = idleInterval
    }

    /// The only configuration of the installed helper.
    public static let production = HelperConfiguration(
        machServiceName: HelperConstants.label,
        storeRoot: HelperConstants.store,
        installedFiles: [HelperConstants.launchdPlist, HelperConstants.installedHelper],
        ownerUID: 0,
        launchdJobRemoval: ["bootout", "system/\(HelperConstants.label)"],
        idleInterval: 30
    )
}

public enum HelperDaemon {
    /// Serves the Mach service until idle. Exits with a failure, without serving anything, when the
    /// process or the store is not what it must be.
    public static func run(_ configuration: HelperConfiguration) -> Never {
        let logger = Logger(subsystem: HelperConstants.label, category: "daemon")
        guard getuid() == configuration.ownerUID, geteuid() == configuration.ownerUID else {
            logger.fault("refusing to run as uid \(getuid())/\(geteuid()); expected \(configuration.ownerUID)")
            exit(EXIT_FAILURE)
        }
        let store: ModStore
        let requirement: String
        let clientUID: uid_t
        do {
            store = try ModStore(root: configuration.storeRoot, ownerUID: configuration.ownerUID)
            requirement = try ClientRequirement.load(from: store.clientRequirement, ownerUID: configuration.ownerUID)
            clientUID = try ClientUser.load(from: store.clientUser, ownerUID: configuration.ownerUID)
        } catch {
            logger.fault("refusing to serve: \(error.localizedDescription, privacy: .public)")
            exit(EXIT_FAILURE)
        }
        let server = HelperServer(
            service: HelperService(store: store, installedFiles: configuration.installedFiles),
            clientUID: clientUID,
            idleInterval: configuration.idleInterval,
            removeLaunchdJob: {
                removeJob(arguments: configuration.launchdJobRemoval, logger: logger)
                exit(EXIT_SUCCESS)
            },
            exitProcess: {
                logger.info("exiting")
                exit(EXIT_SUCCESS)
            }
        )
        let listener = NSXPCListener(machServiceName: configuration.machServiceName)
        server.serve(on: listener, clientRequirement: requirement)
        logger.info("serving \(configuration.machServiceName, privacy: .public)")
        // The listener holds its delegate weakly; both must outlive the dispatch loop.
        withExtendedLifetime((listener, server)) {
            dispatchMain()
        }
    }

    /// launchd usually terminates this process while launchctl runs; returning means it did not.
    private static func removeJob(arguments: [String], logger: Logger) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            logger.notice("launchctl \(arguments, privacy: .public) exited with \(process.terminationStatus)")
        } catch {
            logger.error("cannot run launchctl: \(error.localizedDescription, privacy: .public)")
        }
    }
}
