import AppKit
import os
import ToolsyShared

private let logger = Logger(subsystem: ToolsyPaths.bundleIdentifier, category: "updates")

/// A version of Toolsy as its releases are tagged: "1.2.0", "v1.10.0", "1.2.0-beta.1". Ordered as semantic
/// versions: number by number, and a pre-release before the release it leads to.
nonisolated struct ReleaseVersion: Comparable, CustomStringConvertible, Sendable {
    /// Major, minor, patch.
    let numbers: [Int]
    /// The dot-separated identifiers after a hyphen; empty for a release.
    let prerelease: [String]

    /// Nil for anything but three numbers, optionally after a "v", followed by an optional pre-release.
    init?(_ tag: String) {
        var text = Substring(tag)
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        // Build metadata says nothing about which version is newer.
        if let plus = text.firstIndex(of: "+") { text = text[..<plus] }
        let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false).map { part -> Int? in
            // Digits only, without leading zeros, which would make two spellings of one number.
            guard !part.isEmpty, part.allSatisfy(\.isASCIIDigit), part == "0" || part.first != "0" else { return nil }
            return Int(part)
        }
        let prerelease = parts.count == 2 ? parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init) : []
        guard numbers.count == 3, numbers.allSatisfy({ $0 != nil }), parts.count == 1 || !prerelease.isEmpty,
              prerelease.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCIIDigit || $0.isASCIILetter || $0 == "-" } })
        else { return nil }
        self.numbers = numbers.compactMap(\.self)
        self.prerelease = prerelease
    }

    var description: String {
        numbers.map(String.init).joined(separator: ".") + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, _): return false
        case (false, true): return true
        case (false, false): break
        }
        // Identifier by identifier: numbers numerically and before words, words in ASCII order; when one list
        // continues the other, the shorter comes first.
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (Int(left), Int(right)) {
            case let (left?, right?): return left < right
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

private nonisolated extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
    var isASCIILetter: Bool { ("a"..."z").contains(self) || ("A"..."Z").contains(self) }
}

/// The latest release of Toolsy on GitHub.
struct LatestRelease: Equatable {
    let version: ReleaseVersion
    /// The release's page, where it is downloaded by hand.
    let page: URL
    /// What Toolsy installs by itself; nil for a release without it, which is downloaded from its page.
    let package: UpdatePackage?
}

/// The files of a release that Toolsy installs by itself, as `scripts/release.sh` makes them: the app archive and the
/// release key's signature of it.
struct UpdatePackage: Equatable {
    let archive: URL
    let signature: URL
    /// The archive's size as GitHub reports it, to say how much the update downloads. The signed size is what is checked.
    let size: Int64

    static func archiveName(for version: ReleaseVersion) -> String { "Toolsy-\(version).zip" }
    static func signatureName(for version: ReleaseVersion) -> String { archiveName(for: version) + ".sig" }
}

/// Why a check for updates failed.
enum UpdateCheckError: Error, Equatable {
    /// No connection to GitHub.
    case offline
    /// GitHub limits how often an address may ask, and this one asked too often for now.
    case rateLimited
    /// An answer that is not Toolsy's latest release; the detail is for the log.
    case unexpected(String)

    /// For a check the user asked for.
    var message: String {
        switch self {
        case .offline: String(localized: "Couldn’t reach GitHub. Check the internet connection.")
        case .rateLimited: String(localized: "GitHub limits how often it can be asked. Try again later.")
        case .unexpected: String(localized: "GitHub’s answer wasn’t understood. Try again later.")
        }
    }
}

/// Asking GitHub for Toolsy's latest release, and what to make of the answer. Pure but for `session`.
enum UpdateCheck {
    static let endpoint = URL(string: "https://api.github.com/repos/sowhoia/toolsy/releases/latest")!

    /// Nothing in it identifies the user: every Toolsy of a version sends the same.
    static func request() -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Toolsy/\(ToolsyVersion.current)", forHTTPHeaderField: "User-Agent")
        // URLSession would send the user's preferred language.
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.httpShouldHandleCookies = false
        return request
    }

    /// No cookies, cache or credentials: nothing is kept from one request to the next. Downloads of an update use it too.
    nonisolated static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return configuration
    }

    static let session = URLSession(configuration: configuration())

    /// The release in GitHub's answer: `tag_name` must be a version and `html_url` a page on GitHub.
    static func release(from data: Data, status: Int) throws(UpdateCheckError) -> LatestRelease {
        switch status {
        case 200: break
        case 403, 429: throw .rateLimited
        default: throw .unexpected("HTTP status \(status)")
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { throw .unexpected("not a release") }
        guard let version = ReleaseVersion(answer.tag_name) else { throw .unexpected("tag \(answer.tag_name) is no version") }
        guard let page = URL(string: answer.html_url), page.scheme == "https", page.host() == "github.com" else {
            throw .unexpected("page \(answer.html_url) is not on GitHub")
        }
        let package = package(in: answer.assets ?? [], of: version)
        if package == nil {
            logger.notice("release \(version.description, privacy: .public) has no update package; it can only be downloaded from its page")
        }
        return LatestRelease(version: version, page: page, package: package)
    }

    private struct Answer: Decodable {
        var tag_name: String
        var html_url: String
        var assets: [Asset]?
    }

    /// A file attached to the release. Every field may be missing: a file Toolsy does not need must not spoil the answer.
    private struct Asset: Decodable {
        var name: String?
        var browser_download_url: String?
        var size: Int64?
    }

    /// The archive and its signature among the release's files, each a download of this repository's releases.
    private static func package(in assets: [Asset], of version: ReleaseVersion) -> UpdatePackage? {
        func download(named name: String) -> (url: URL, size: Int64)? {
            guard let asset = assets.first(where: { $0.name == name }), let link = asset.browser_download_url,
                  let url = URL(string: link), isReleaseDownload(url), let size = asset.size, size > 0 else { return nil }
            return (url, size)
        }
        guard let archive = download(named: UpdatePackage.archiveName(for: version)),
              let signature = download(named: UpdatePackage.signatureName(for: version)) else { return nil }
        return UpdatePackage(archive: archive.url, signature: signature.url, size: archive.size)
    }

    /// The page of the release of `version`, as GitHub names it by its tag.
    static func page(of version: ReleaseVersion) -> URL {
        URL(string: "https://github.com/sowhoia/toolsy/releases/tag/v\(version)")!
    }

    /// A file of one of this repository's releases, over HTTPS.
    static func isReleaseDownload(_ url: URL) -> Bool {
        url.scheme == "https" && url.host() == "github.com" && url.path().hasPrefix("/sowhoia/toolsy/releases/download/")
    }

    /// What an error of the request means: offline for every error of a missing or broken connection.
    static func error(for error: any Error) -> UpdateCheckError {
        guard let error = error as? URLError else { return .unexpected(error.localizedDescription) }
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .timedOut, .internationalRoamingOff, .dataNotAllowed, .callIsActive:
            return .offline
        default:
            return .unexpected(error.localizedDescription)
        }
    }

    /// Whether the user is to be told about `release` by a notification: it is newer than the running version and
    /// than the last version announced.
    static func announces(_ release: LatestRelease, running: ReleaseVersion, announced: String?) -> Bool {
        guard release.version > running else { return false }
        guard let announced = announced.flatMap(ReleaseVersion.init) else { return true }
        return release.version > announced
    }

    /// The notification of a new version, which opens the panel on the offer to update when clicked.
    static func notification(for release: LatestRelease) -> (title: String, body: String) {
        (String(localized: "Toolsy \(release.version.description) is available"),
         String(localized: "Click to update."))
    }
}

/// Something that runs now and then until it is invalidated.
protocol ScheduledActivity: AnyObject {
    func invalidate()
}

/// Looks for a new version of Toolsy on GitHub; `UpdateInstaller` installs one when the user asks. While the setting is
/// on, a check runs shortly after launch and then about once a day, and a newly found version is announced once by a
/// notification; with it off nothing is scheduled. Only a check the user asked for reports a failure; an automatic one
/// logs it. It also remembers the version that ran last, to say once that Toolsy was updated.
@Observable
final class UpdateChecker {
    enum Status: Equatable {
        case idle
        /// A check the user asked for is under way.
        case checking
        /// The latest check found nothing newer.
        case upToDate
        case available(LatestRelease)
        /// A check the user asked for failed; the message says why.
        case failed(String)
    }

    /// The running version. `ToolsyVersion.current` always is one (a test checks it).
    static let running = ReleaseVersion(ToolsyVersion.current)!

    private(set) var status: Status = .idle

    /// The version that ran before this one, when Toolsy was updated since: the panel says so until it is dismissed.
    private(set) var updatedFrom: ReleaseVersion?

    var checksAutomatically: Bool {
        get { settings.checksForUpdates }
        set {
            settings.checksForUpdates = newValue
            follow()
        }
    }

    @ObservationIgnored private let settings: AppSettings
    /// The version of this run.
    @ObservationIgnored let running: ReleaseVersion
    @ObservationIgnored private let mayCheckAutomatically: Bool
    @ObservationIgnored private let fetch: () async throws -> (Data, URLResponse)
    @ObservationIgnored private let announce: (LatestRelease) -> Void
    @ObservationIgnored private let schedule: @MainActor (@escaping @MainActor () async -> Void) -> any ScheduledActivity
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private(set) var activity: (any ScheduledActivity)?

    /// `mayCheckAutomatically` is false for a run that must not depend on the network (a debug run on scratch data).
    init(settings: AppSettings, running: ReleaseVersion = UpdateChecker.running, mayCheckAutomatically: Bool = true,
         fetch: @escaping () async throws -> (Data, URLResponse) = { try await UpdateCheck.session.data(for: UpdateCheck.request()) },
         announce: @escaping (LatestRelease) -> Void,
         schedule: @escaping @MainActor (@escaping @MainActor () async -> Void) -> any ScheduledActivity = DailyActivity.init) {
        self.settings = settings
        self.running = running
        self.mayCheckAutomatically = mayCheckAutomatically
        self.fetch = fetch
        self.announce = announce
        self.schedule = schedule
        if let last = settings.lastRunVersion.flatMap(ReleaseVersion.init), last < running {
            updatedFrom = last
        }
        settings.lastRunVersion = running.description
    }

    func start() {
        isRunning = true
        follow()
    }

    func stop() {
        isRunning = false
        follow()
    }

    private func follow() {
        let wanted = isRunning && mayCheckAutomatically && settings.checksForUpdates
        if wanted, activity == nil {
            activity = schedule { [weak self] in await self?.checkAutomatically() }
        } else if !wanted, let activity {
            activity.invalidate()
            self.activity = nil
        }
    }

    /// Check Now in Settings.
    func checkNow() async {
        guard status != .checking else { return }
        status = .checking
        switch await latestRelease() {
        case .success(let release) where release.version > running:
            status = .available(release)
            // Found here, it needs no notification.
            if UpdateCheck.announces(release, running: running, announced: settings.announcedVersion) {
                settings.announcedVersion = release.version.description
            }
        case .success:
            status = .upToDate
        case .failure(let error):
            status = .failed(error.message)
        }
    }

    func checkAutomatically() async {
        switch await latestRelease() {
        case .success(let release):
            // A check the user started meanwhile shows its own result.
            if status != .checking { status = release.version > running ? .available(release) : .upToDate }
            if UpdateCheck.announces(release, running: running, announced: settings.announcedVersion) {
                settings.announcedVersion = release.version.description
                announce(release)
            }
        case .failure(let error):
            logger.notice("the automatic check for updates failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Forgets that the latest check found nothing or failed, which says something only right after it. A new
    /// version stays shown.
    func dismissResult() {
        switch status {
        case .upToDate, .failed: status = .idle
        case .idle, .checking, .available: break
        }
    }

    func openPage(of release: LatestRelease) {
        NSWorkspace.shared.open(release.page)
    }

    /// The page of the running version, whose notes say what the update brought.
    func openRunningVersionPage() {
        NSWorkspace.shared.open(UpdateCheck.page(of: running))
    }

    func dismissUpdated() {
        updatedFrom = nil
    }

    /// Whether the dashboard offers `release`: the user can put the offer away there until a newer version comes.
    func isOfferedOnDashboard(_ release: LatestRelease) -> Bool {
        guard let dismissed = settings.dismissedUpdate.flatMap(ReleaseVersion.init) else { return true }
        return release.version > dismissed
    }

    func putAwayOffer(of release: LatestRelease) {
        settings.dismissedUpdate = release.version.description
    }

    private func latestRelease() async -> Result<LatestRelease, UpdateCheckError> {
        do {
            let (data, response) = try await fetch()
            return .success(try UpdateCheck.release(from: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0))
        } catch let error as UpdateCheckError {
            return .failure(error)
        } catch {
            return .failure(UpdateCheck.error(for: error))
        }
    }
}

/// Runs `work` shortly after it is created and then about once a day, at moments the system chooses so that it
/// coalesces with other work (`NSBackgroundActivityScheduler`).
final class DailyActivity: ScheduledActivity {
    private let scheduler = NSBackgroundActivityScheduler(identifier: "\(ToolsyPaths.bundleIdentifier).update-check")

    init(work: @escaping @MainActor () async -> Void) {
        scheduler.repeats = true
        scheduler.qualityOfService = .utility
        // The first run comes within two minutes; after each, the next is due a day later.
        scheduler.interval = 60
        scheduler.tolerance = 60
        scheduler.schedule { [weak self] completion in
            Task { @MainActor in
                await work()
                self?.scheduler.interval = 24 * 60 * 60
                self?.scheduler.tolerance = 60 * 60
                completion(.finished)
            }
        }
    }

    func invalidate() {
        scheduler.invalidate()
    }
}
