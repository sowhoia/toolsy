import Foundation
import Observation
import os
import ToolsyShared

private let logger = Logger(subsystem: ToolsyPaths.bundleIdentifier, category: "settings")

/// Toolsy's own choices beyond the dashboard and developer mode: the alerts about the Mac and the update check.
/// Saved in `Settings.json` in the data root after every change, so a debug run on scratch data neither sees nor
/// changes the user's. One instance lives for the life of the app.
///
/// Loading never fails: without a file, or with one that cannot be read or comes from a newer Toolsy, the defaults
/// apply and the file is left alone until something changes.
@Observable
final class AppSettings {
    static let version = 1

    /// The alerts that are on; none until the user switches one on.
    var alerts: Set<MacAlert> {
        didSet { if alerts != oldValue { save() } }
    }

    /// Whether Toolsy looks for a new version by itself; on until the user switches it off.
    var checksForUpdates: Bool {
        didSet { if checksForUpdates != oldValue { save() } }
    }

    /// The newest version the user has been told about, so that each one is announced once.
    var announcedVersion: String? {
        didSet { if announcedVersion != oldValue { save() } }
    }

    @ObservationIgnored let file: URL

    init(file: URL) {
        self.file = file
        let saved = Self.load(file)
        alerts = saved?.alerts ?? []
        checksForUpdates = saved?.checksForUpdates ?? true
        announcedVersion = saved?.announcedVersion
    }

    // MARK: File

    /// `Settings.json`. Every field but the version may be missing, and alerts this version does not know are
    /// skipped, so a file of an older or newer Toolsy of the same format version still loads.
    private struct SavedSettings: Codable {
        var version: Int
        var alerts: Set<MacAlert>
        var checksForUpdates: Bool
        var announcedVersion: String?

        private enum CodingKeys: String, CodingKey {
            case version, alerts, checksForUpdates, announcedVersion
        }

        init(version: Int, alerts: Set<MacAlert>, checksForUpdates: Bool, announcedVersion: String?) {
            self.version = version
            self.alerts = alerts
            self.checksForUpdates = checksForUpdates
            self.announcedVersion = announcedVersion
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            alerts = Set(try container.decodeIfPresent([String].self, forKey: .alerts)?.compactMap(MacAlert.init(rawValue:)) ?? [])
            checksForUpdates = try container.decodeIfPresent(Bool.self, forKey: .checksForUpdates) ?? true
            announcedVersion = try container.decodeIfPresent(String.self, forKey: .announcedVersion)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(alerts.map(\.rawValue).sorted(), forKey: .alerts)
            try container.encode(checksForUpdates, forKey: .checksForUpdates)
            try container.encodeIfPresent(announcedVersion, forKey: .announcedVersion)
        }
    }

    private struct SavedVersion: Decodable {
        var version: Int
    }

    private func save() {
        let saved = SavedSettings(version: Self.version, alerts: alerts, checksForUpdates: checksForUpdates,
                                  announcedVersion: announcedVersion)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(saved).write(to: file, options: .atomic)
        } catch {
            // The choice holds for this run; only the next launch would not know it.
            logger.error("settings could not be saved to \(self.file.path(percentEncoded: false), privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The saved settings, or nil when the defaults apply.
    private static func load(_ file: URL) -> SavedSettings? {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil  // never changed
        } catch {
            logger.error("settings \(file.path(percentEncoded: false), privacy: .public) cannot be read: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let decoder = JSONDecoder()
        do {
            let version = try decoder.decode(SavedVersion.self, from: data).version
            guard version <= Self.version else {
                logger.notice("settings are of a newer version (\(version)); using the defaults")
                return nil
            }
            return try decoder.decode(SavedSettings.self, from: data)
        } catch {
            logger.error("settings \(file.path(percentEncoded: false), privacy: .public) are damaged: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
