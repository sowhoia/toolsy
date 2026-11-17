import Foundation
import Testing
import ToolsyShared
@testable import Toolsy

private func version(_ tag: String) -> ReleaseVersion {
    guard let version = ReleaseVersion(tag) else {
        Issue.record("\(tag) is no version")
        return ReleaseVersion("0.0.0")!
    }
    return version
}

/// GitHub's answer for the latest release, cut down from a real one: the fields Toolsy reads among others it skips.
private func answer(tag: String = "v1.2.0", page: String = "https://github.com/sowhoia/toolsy/releases/tag/v1.2.0") -> Data {
    Data("""
    {
      "url": "https://api.github.com/repos/sowhoia/toolsy/releases/447671848",
      "html_url": "\(page)",
      "id": 447671848,
      "author": {"login": "sowhoia", "type": "User"},
      "tag_name": "\(tag)",
      "target_commitish": "main",
      "name": "Toolsy 1.2.0",
      "draft": false,
      "prerelease": false,
      "published_at": "2026-11-16T22:01:00Z",
      "assets": [{"name": "Toolsy-1.2.0.zip", "browser_download_url": "https://github.com/sowhoia/toolsy/releases/download/v1.2.0/Toolsy-1.2.0.zip"}]
    }
    """.utf8)
}

struct ReleaseVersionTests {
    @Test func numbersCompareAsNumbers() {
        #expect(version("1.10.0") > version("1.9.0"))
        #expect(version("2.0.0") > version("1.99.99"))
        #expect(version("1.1.1") > version("1.1.0"))
        #expect(version("v1.2.0") == version("1.2.0"))
        #expect(version("V1.2.0") == version("1.2.0"))
        #expect(version("1.2.0+build.7") == version("1.2.0"), "build metadata is not compared")
        #expect(version("v1.2.0").description == "1.2.0")
    }

    @Test func aPreReleaseComesBeforeItsRelease() {
        #expect(version("1.2.0-beta.1") < version("1.2.0"))
        #expect(!(version("v1.2.0-rc.1") > version("1.2.0")))
        // It is still newer than the release before it.
        #expect(version("1.2.0-beta.1") > version("1.1.0"))
        #expect(version("1.2.0-alpha") < version("1.2.0-alpha.1"))
        #expect(version("1.2.0-alpha.1") < version("1.2.0-beta"))
        #expect(version("1.2.0-beta.2") < version("1.2.0-beta.11"))
        #expect(version("1.2.0-beta.11") < version("1.2.0-rc.1"))
        #expect(version("1.2.0-1") < version("1.2.0-alpha"), "numbers before words")
        #expect(version("1.2.0-rc.1").description == "1.2.0-rc.1")
    }

    @Test func malformedTagsAreNoVersions() {
        for tag in ["", "v", "latest", "1", "1.2", "1.2.3.4", "1.x.0", "1..0", "1.02.0", "-1.2.0", " 1.2.0", "1.2.0 ",
                    "1.2.0-", "1.2.0-beta..1", "1.2.0-beta_1", "vv1.2.0", "１.2.0", "99999999999999999999.0.0"] {
            #expect(ReleaseVersion(tag) == nil, "\(tag)")
        }
    }

    @Test func theRunningVersionIsOne() {
        #expect(ReleaseVersion(ToolsyVersion.current) != nil)
        #expect(UpdateChecker.running.description == ToolsyVersion.current)
    }
}

struct LatestReleaseTests {
    @Test func theAnswerGivesTheVersionAndItsPage() throws {
        let release = try UpdateCheck.release(from: answer(), status: 200)
        #expect(release.version == version("1.2.0"))
        #expect(release.page == URL(string: "https://github.com/sowhoia/toolsy/releases/tag/v1.2.0"))
    }

    @Test func anythingElseIsAFailureOfItsKind() {
        func failure(_ data: Data, status: Int = 200) -> UpdateCheckError? {
            do {
                _ = try UpdateCheck.release(from: data, status: status)
                return nil
            } catch {
                return error
            }
        }
        #expect(failure(answer(), status: 403) == .rateLimited)
        #expect(failure(answer(), status: 429) == .rateLimited)
        #expect(failure(Data(#"{"message": "Not Found"}"#.utf8), status: 404) == .unexpected("HTTP status 404"))
        #expect(failure(answer(), status: 500) == .unexpected("HTTP status 500"))
        #expect(failure(Data("<html>".utf8)) == .unexpected("not a release"))
        #expect(failure(Data(#"{"html_url": "https://github.com/sowhoia/toolsy"}"#.utf8)) == .unexpected("not a release"))
        #expect(failure(answer(tag: "nightly")) == .unexpected("tag nightly is no version"))
        // The Download button opens the page: only GitHub's, over HTTPS.
        #expect(failure(answer(page: "http://github.com/sowhoia/toolsy/releases/tag/v1.2.0")) != nil)
        #expect(failure(answer(page: "https://github.com.example.net/toolsy")) != nil)
        #expect(failure(answer(page: "file:///Applications")) != nil)
    }

    @Test func connectionErrorsMeanOffline() {
        #expect(UpdateCheck.error(for: URLError(.notConnectedToInternet)) == .offline)
        #expect(UpdateCheck.error(for: URLError(.timedOut)) == .offline)
        #expect(UpdateCheck.error(for: URLError(.cannotFindHost)) == .offline)
        if case .unexpected = UpdateCheck.error(for: URLError(.badServerResponse)) {} else {
            Issue.record("a bad answer is not being offline")
        }
        #expect(UpdateCheckError.offline.message != UpdateCheckError.rateLimited.message)
    }

    @Test func eachNewVersionIsAnnouncedOnce() throws {
        let release = try UpdateCheck.release(from: answer(), status: 200)
        #expect(UpdateCheck.announces(release, running: version("1.1.0"), announced: nil))
        #expect(!UpdateCheck.announces(release, running: version("1.1.0"), announced: "1.2.0"))
        #expect(UpdateCheck.announces(release, running: version("1.1.0"), announced: "1.1.5"))
        #expect(!UpdateCheck.announces(release, running: version("1.2.0"), announced: nil), "not newer than the running one")
        #expect(!UpdateCheck.announces(release, running: version("1.3.0"), announced: nil))
        #expect(UpdateCheck.notification(for: release).title.contains("1.2.0"))
    }

    @Test func theRequestSaysNothingAboutTheUser() {
        let request = UpdateCheck.request()
        #expect(request.url == URL(string: "https://api.github.com/repos/sowhoia/toolsy/releases/latest"))
        #expect(request.httpMethod == "GET")
        #expect(request.allHTTPHeaderFields == [
            "Accept": "application/vnd.github+json",
            "User-Agent": "Toolsy/\(ToolsyVersion.current)",
            "Accept-Language": "en",
        ])
        #expect(!request.httpShouldHandleCookies)
        let configuration = UpdateCheck.session.configuration
        #expect(configuration.httpCookieStorage == nil && configuration.urlCache == nil && configuration.urlCredentialStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
    }
}

// MARK: - The checker

/// An activity the test fires by hand.
private final class FakeActivity: ScheduledActivity {
    let work: @MainActor () async -> Void
    private(set) var isValid = true

    init(work: @escaping @MainActor () async -> Void) {
        self.work = work
    }

    func invalidate() {
        isValid = false
    }
}

/// What the checker fetched, announced and scheduled; its closures hold this.
@MainActor
private final class UpdatesRecorder {
    var answers: [Result<(Data, Int), any Error>] = []
    var fetches = 0
    var announced: [String] = []
    var activities: [FakeActivity] = []

    func fetch() throws -> (Data, URLResponse) {
        fetches += 1
        let (data, status) = try answers.removeFirst().get()
        return (data, HTTPURLResponse(url: UpdateCheck.endpoint, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
private final class UpdatesFixture {
    let file = FileManager.default.temporaryDirectory.appending(path: "ToolsyUpdates-\(UUID().uuidString)/Settings.json")
    let recorder = UpdatesRecorder()
    private(set) var settings: AppSettings
    private(set) var checker: UpdateChecker

    init(running: String = "1.1.0", mayCheckAutomatically: Bool = true) {
        settings = AppSettings(file: file)
        checker = UpdatesFixture.checker(settings: settings, recorder: recorder, running: running, mayCheckAutomatically: mayCheckAutomatically)
    }

    /// Toolsy launched again on the same settings file.
    func relaunch() {
        checker.stop()
        settings = AppSettings(file: file)
        checker = UpdatesFixture.checker(settings: settings, recorder: recorder, running: "1.1.0", mayCheckAutomatically: true)
    }

    private static func checker(settings: AppSettings, recorder: UpdatesRecorder, running: String, mayCheckAutomatically: Bool) -> UpdateChecker {
        UpdateChecker(
            settings: settings, running: ReleaseVersion(running)!, mayCheckAutomatically: mayCheckAutomatically,
            fetch: { [recorder] in try recorder.fetch() },
            announce: { [recorder] release in recorder.announced.append(release.version.description) },
            schedule: { [recorder] work in
                let activity = FakeActivity(work: work)
                recorder.activities.append(activity)
                return activity
            }
        )
    }

    var scheduled: [FakeActivity] { recorder.activities.filter(\.isValid) }

    func cleanUp() {
        checker.stop()
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())  // best effort: a temporary folder
    }
}

@MainActor
struct UpdateCheckerTests {
    @Test func automaticChecksAreScheduledOnlyWhileTheSettingIsOn() {
        let fixture = UpdatesFixture()
        #expect(fixture.checker.checksAutomatically, "on by default")
        #expect(fixture.scheduled.isEmpty, "nothing before the app starts it")
        fixture.checker.start()
        #expect(fixture.scheduled.count == 1)
        fixture.checker.checksAutomatically = false
        #expect(fixture.scheduled.isEmpty)
        #expect(!AppSettings(file: fixture.file).checksForUpdates, "the choice is saved")
        fixture.checker.checksAutomatically = true
        #expect(fixture.scheduled.count == 1)
        fixture.checker.stop()
        #expect(fixture.scheduled.isEmpty)
        #expect(fixture.recorder.fetches == 0, "scheduling asks GitHub nothing")
        fixture.cleanUp()
    }

    @Test func aRunWithoutTheNetworkSchedulesNothing() async {
        let fixture = UpdatesFixture(mayCheckAutomatically: false)
        fixture.checker.start()
        #expect(fixture.scheduled.isEmpty)
        // Asking is still possible.
        fixture.recorder.answers = [.success((answer(), 200))]
        await fixture.checker.checkNow()
        #expect(fixture.recorder.fetches == 1)
        fixture.cleanUp()
    }

    @Test func checkNowShowsWhatItFound() async {
        let fixture = UpdatesFixture()
        fixture.recorder.answers = [.success((answer(tag: "v1.1.0"), 200)), .success((answer(), 200))]
        await fixture.checker.checkNow()
        #expect(fixture.checker.status == .upToDate)
        await fixture.checker.checkNow()
        guard case .available(let release) = fixture.checker.status else {
            Issue.record("\(fixture.checker.status)")
            return
        }
        #expect(release.version.description == "1.2.0")
        #expect(fixture.recorder.announced.isEmpty, "the user sees it already")
        // A new version stays shown after leaving Settings.
        fixture.checker.dismissResult()
        #expect(fixture.checker.status == .available(release))
        fixture.cleanUp()
    }

    @Test func checkNowSaysWhyItFailed() async {
        let fixture = UpdatesFixture()
        fixture.recorder.answers = [.failure(URLError(.notConnectedToInternet)), .success((Data(), 403)), .success((Data("{}".utf8), 200))]
        await fixture.checker.checkNow()
        #expect(fixture.checker.status == .failed(UpdateCheckError.offline.message))
        await fixture.checker.checkNow()
        #expect(fixture.checker.status == .failed(UpdateCheckError.rateLimited.message))
        await fixture.checker.checkNow()
        #expect(fixture.checker.status == .failed(UpdateCheckError.unexpected("").message))
        // Leaving Settings forgets it.
        fixture.checker.dismissResult()
        #expect(fixture.checker.status == .idle)
        fixture.cleanUp()
    }

    @Test func anAutomaticCheckAnnouncesANewVersionOnceAndFailsSilently() async throws {
        let fixture = UpdatesFixture()
        fixture.checker.start()
        let activity = try #require(fixture.scheduled.first)
        fixture.recorder.answers = [.failure(URLError(.timedOut)), .success((answer(), 200)), .success((answer(), 200))]
        await activity.work()
        #expect(fixture.checker.status == .idle, "a failure the user did not ask about is only logged")
        await activity.work()
        await activity.work()
        #expect(fixture.recorder.announced == ["1.2.0"])
        #expect(fixture.checker.status == .available(try UpdateCheck.release(from: answer(), status: 200)))

        // Toolsy launched again: the same version is not announced again, a newer one is.
        fixture.relaunch()
        fixture.checker.start()
        let next = try #require(fixture.scheduled.last)
        fixture.recorder.answers = [.success((answer(), 200)), .success((answer(tag: "v1.3.0"), 200))]
        await next.work()
        await next.work()
        #expect(fixture.recorder.announced == ["1.2.0", "1.3.0"])
        fixture.cleanUp()
    }

    @Test func aVersionFoundByCheckNowIsNotAnnouncedLater() async throws {
        let fixture = UpdatesFixture()
        fixture.checker.start()
        fixture.recorder.answers = [.success((answer(), 200)), .success((answer(), 200))]
        await fixture.checker.checkNow()
        try await #require(fixture.scheduled.first).work()
        #expect(fixture.recorder.announced.isEmpty)
        fixture.cleanUp()
    }
}
