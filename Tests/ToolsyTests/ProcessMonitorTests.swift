import AppKit
import Foundation
import Testing
import ToolsyShared
@testable import Toolsy

// MARK: - Grouping rules

private func process(_ pid: pid_t, _ path: String, start: UInt64 = 1, responsible: ProcessKey? = nil,
                     footprint: UInt64 = 100, cpuTime: UInt64 = 0) -> ProcessReading {
    ProcessReading(
        key: ProcessKey(pid: pid, start: start),
        identity: ProcessIdentity(executable: path, bundle: ProcessGrouping.outermostBundle(of: path), responsible: responsible),
        footprint: footprint, cpuTime: cpuTime
    )
}

struct ProcessGroupingTests {
    @Test func theOutermostBundleIsTheApp() {
        #expect(ProcessGrouping.outermostBundle(of: "/Applications/Browser.app/Contents/MacOS/Browser") == "/Applications/Browser.app")
        #expect(ProcessGrouping.outermostBundle(of: "/Applications/Browser.app/Contents/Frameworks/Browser Helper.app/Contents/MacOS/Browser Helper")
                == "/Applications/Browser.app")
        #expect(ProcessGrouping.outermostBundle(of: "/usr/bin/clang") == nil)
        // The executable itself is not a bundle, and a name without a path has none.
        #expect(ProcessGrouping.outermostBundle(of: "/tmp/tool.app") == nil)
        #expect(ProcessGrouping.outermostBundle(of: "launchd") == nil)
        #expect(ProcessGrouping.isXPCService("/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"))
        #expect(!ProcessGrouping.isXPCService("/usr/libexec/xpcproxy"))
    }

    @Test func processesGroupIntoApps() {
        let browser = process(10, "/Applications/Browser.app/Contents/MacOS/Browser", footprint: 500)
        let helper = process(11, "/Applications/Browser.app/Contents/Frameworks/Browser Helper.app/Contents/MacOS/Browser Helper", footprint: 300)
        let webContent = process(12, "/System/Library/Frameworks/WebKit.framework/XPCServices/WebContent.xpc/Contents/MacOS/WebContent",
                                 responsible: browser.key, footprint: 200)
        // Responsible for an app that no longer exists: the pid was reused by another process.
        let orphan = process(13, "/System/Library/XPCServices/Thumbnails.xpc/Contents/MacOS/Thumbnails",
                             responsible: ProcessKey(pid: 20, start: 1), footprint: 50)
        let reused = process(20, "/usr/bin/vim", start: 2, footprint: 5)
        // Started from a terminal, but not part of it.
        let terminal = process(30, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", footprint: 80)
        let compiler = process(31, "/usr/bin/clang", footprint: 700)

        let groups = ProcessGrouping.groups([browser, helper, webContent, orphan, reused, terminal, compiler], previous: [:], elapsed: 1)
        let byKind = Dictionary(uniqueKeysWithValues: groups.map { ($0.kind, $0) })
        #expect(groups.count == 5)
        #expect(byKind[.bundle("/Applications/Browser.app")]?.memory == 1000)
        #expect(byKind[.bundle("/Applications/Browser.app")]?.pids.sorted() == [10, 11, 12])
        #expect(byKind[.bundle("/System/Applications/Utilities/Terminal.app")]?.pids == [30])
        #expect(byKind[.process(compiler.key, executable: "/usr/bin/clang")]?.memory == 700)
        #expect(byKind[.process(orphan.key, executable: orphan.identity.executable)]?.pids == [13])
        #expect(byKind[.process(reused.key, executable: "/usr/bin/vim")]?.pids == [20])
    }

    @Test func cpuIsCountedSinceThePreviousSample() {
        let busy = process(1, "/usr/bin/yes", cpuTime: 1_500)
        let started = process(2, "/usr/bin/true", cpuTime: 250)
        let idle = process(3, "/usr/bin/sleep", cpuTime: 40)
        let groups = ProcessGrouping.groups([busy, started, idle], previous: [busy.key: 500, idle.key: 40], elapsed: 1_000)
        let cpu = Dictionary(uniqueKeysWithValues: groups.map { ($0.pids[0], $0.cpu) })
        // One core for the whole interval is 100.
        #expect(cpu == [1: 100, 2: 25, 3: 0])
    }
}

// MARK: - Real processes

/// A child process for the duration of a test; killed (by pid, it is ours) when the test ends.
private final class Child {
    let process = Process()

    init(_ executable: String, _ arguments: [String]) throws {
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    var pid: pid_t { process.processIdentifier }

    deinit {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}

private func group(containing pid: pid_t, in groups: [ProcessGroupReading]?) -> ProcessGroupReading? {
    groups?.first { $0.pids.contains(pid) }
}

private func waitUntil(_ what: String, within timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out waiting for \(what)")
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(50))
    }
}

struct ProcessSamplerTests {
    @Test func aBusyLoopUsesOneCore() async throws {
        let busy = try Child("/usr/bin/yes", [])
        let sampler = ProcessSampler()
        #expect(await sampler.sample(startingOver: true) == nil)
        try await Task.sleep(for: .seconds(1))
        let found = try #require(group(containing: busy.pid, in: await sampler.sample()))
        // Activity Monitor's unit: a single-threaded busy loop is about 100 %.
        #expect((75...110).contains(found.cpu), "\(found.cpu)")
        #expect(found.kind == .process(ProcessKey(pid: busy.pid, start: try #require(Self.start(of: busy.pid))), executable: "/usr/bin/yes"))
    }

    @Test func memoryIsWhatTopShows() async throws {
        // Touches at least 300 MB of its own memory, then waits.
        let holder = try Child("/usr/bin/perl", ["-e", "$x = 'a' x 300_000_000; sleep 30"])
        let sampler = ProcessSampler()
        _ = await sampler.sample(startingOver: true)
        // Until perl is done building the string (it copies it once) and sleeps.
        var last: UInt64 = 0
        try await waitUntil("the allocation") {
            let now = Self.footprint(of: holder.pid) ?? 0
            defer { last = now }
            return now > 300_000_000 && now == last
        }
        let found = try #require(group(containing: holder.pid, in: await sampler.sample()))
        #expect(found.memory > 300_000_000)
        // top's MEM column is the physical footprint too, as Activity Monitor's Memory column.
        let top = try #require(try await Self.topMemory(of: holder.pid))
        #expect(abs(Double(found.memory) - Double(top)) < Double(top) * 0.02, "\(found.memory) vs \(top)")
    }

    @Test func onlyTheUsersProcessesAreListed() async throws {
        let sampler = ProcessSampler()
        _ = await sampler.sample(startingOver: true)
        let groups = try #require(await sampler.sample())
        #expect(group(containing: getpid(), in: groups) != nil)
        // launchd runs as root.
        #expect(group(containing: 1, in: groups) == nil)
    }

    /// `top -l 1 -pid <pid> -stats mem` in bytes; top prints binary units such as `574M`.
    private static func topMemory(of pid: pid_t) async throws -> UInt64? {
        let result = try await ProcessRunner.run(ProcessRunner.Request(
            executable: URL(filePath: "/usr/bin/top"), arguments: ["-l", "1", "-pid", "\(pid)", "-stats", "mem"], timeout: 10
        ))
        let lastLine = String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").last ?? ""
        guard let match = lastLine.firstMatch(of: /([0-9]+)([BKMG])/), let number = UInt64(match.1) else { return nil }
        let shift: UInt64 = ["B": 0, "K": 10, "M": 20, "G": 30][String(match.2)] ?? 0
        return number << shift
    }

    private static func start(of pid: pid_t) -> UInt64? {
        usage(of: pid)?.ri_proc_start_abstime
    }

    private static func footprint(of pid: pid_t) -> UInt64? {
        usage(of: pid)?.ri_phys_footprint
    }

    private static func usage(of pid: pid_t) -> rusage_info_v6? {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        return result == 0 ? info : nil
    }
}

@MainActor
struct ProcessMonitorTests {
    @Test func samplesWhileSomethingWantsIt() async throws {
        let panel = PanelState()
        let monitor = ProcessMonitor(panel: panel, interval: 0.2)
        monitor.start()
        monitor.start()
        try await Task.sleep(for: .milliseconds(300))
        // Nothing while the panel is closed.
        #expect(!monitor.isSampling && monitor.groups.isEmpty)
        panel.setVisible(true)
        try await waitUntil("the first groups") { !monitor.groups.isEmpty }
        #expect(monitor.groups.allSatisfy { $0.processCount > 0 })
        #expect(Set(monitor.groups.map(\.id)).count == monitor.groups.count)
        #expect(monitor.largest(3).count == 3)
        #expect(monitor.largest(3).map(\.memory) == monitor.largest(3).map(\.memory).sorted(by: >))
        #expect(monitor.busiest(2).count == 2)

        monitor.stop()
        #expect(monitor.isSampling)
        // Closing the panel stops it although views still want it; opening it again resumes.
        panel.setVisible(false)
        #expect(!monitor.isSampling)
        let last = monitor.groups
        try await Task.sleep(for: .milliseconds(600))
        // The last groups are kept, and no further sample replaces them.
        #expect(monitor.groups.map(\.id) == last.map(\.id))
        #expect(monitor.groups.map(\.memory) == last.map(\.memory))
        panel.setVisible(true)
        #expect(monitor.isSampling)
        monitor.stop()
        #expect(!monitor.isSampling)
    }

    /// Quits only an app this test started: `osascript` turned into a regular app without a window.
    @Test func quitsARegularAppByAsking() async throws {
        let app = try Child("/usr/bin/osascript", ["-l", "JavaScript", "-e",
            "ObjC.import('AppKit'); $.NSApplication.sharedApplication.setActivationPolicy($.NSApplicationActivationPolicyRegular); $.NSApp.run"])
        let panel = PanelState()
        panel.setVisible(true)
        let monitor = ProcessMonitor(panel: panel, interval: 0.2)
        monitor.start()
        defer { monitor.stop() }
        try await waitUntil("the app's group") {
            monitor.groups.contains { $0.applicationPID == app.pid && $0.canQuit }
        }
        let group = try #require(monitor.groups.first { $0.applicationPID == app.pid })
        #expect(group.name == "osascript")
        #expect(group.icon != nil)
        // A group sampled from an earlier holder of this pid is another app: nothing is asked of this one.
        let stale = ProcessGroup(id: "\(app.pid)-1", name: group.name, icon: nil, memory: 0, cpu: 0, processCount: 1,
                                 canQuit: true, applicationPID: app.pid)
        #expect(!monitor.quit(stale))
        let renamed = ProcessGroup(id: "/Applications/Other.app", name: "Other", icon: nil, memory: 0, cpu: 0, processCount: 1,
                                   canQuit: true, applicationPID: app.pid)
        #expect(!monitor.quit(renamed))
        #expect(app.process.isRunning)

        #expect(monitor.quit(group))
        try await waitUntil("the app to quit") { !app.process.isRunning }
        #expect(app.process.terminationReason == .exit)
    }

    @Test func aBundleIsNamedForItsOwnAppNotForOneNestedInIt() {
        typealias App = (bundle: String?, regular: Bool)
        let xcode: App = ("/Applications/Xcode.app", true)
        let simulator: App = ("/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app", true)
        let agent: App = ("/Applications/Xcode.app", false)
        func owner(_ candidates: [App]) -> App? {
            ProcessMonitor.owner(ofBundle: "/Applications/Xcode.app", among: candidates, bundlePath: \.bundle, isRegular: \.regular)
        }
        // The newest process comes first in a sample, and Simulator was started after Xcode.
        #expect(owner([simulator, xcode])?.bundle == xcode.bundle)
        #expect(owner([simulator]) == nil, "only the nested app runs: the group has a name from its bundle and no Quit")
        #expect(owner([agent, xcode])?.regular == true, "the app with a Dock icon, not its background twin")
        #expect(owner([agent])?.regular == false)
        #expect(owner([]) == nil)
    }

    @Test func appsAreNamedWithoutTheirExtension() throws {
        // Finder shows the extension when it is set to show them all, as it is on some Macs.
        let folder = FileManager.default.temporaryDirectory.appending(path: "toolsy-names-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appending(path: "Sample Tool.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        #expect(ProcessMonitor.bundleName(atPath: app.path(percentEncoded: false)) == "Sample Tool")
        #expect(!ProcessMonitor.bundleName(atPath: "/System/Applications/Calculator.app").lowercased().hasSuffix(".app"))
    }

    @Test func nothingElseCanBeQuit() async throws {
        let panel = PanelState()
        panel.setVisible(true)
        let monitor = ProcessMonitor(panel: panel, interval: 0.2)
        monitor.start()
        defer { monitor.stop() }
        try await waitUntil("the first groups") { !monitor.groups.isEmpty }
        for group in monitor.groups where !group.canQuit {
            #expect(!monitor.quit(group))
        }
        let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        #expect(finder.map(ProcessMonitor.canQuit) != true)
        #expect(!ProcessMonitor.canQuit(.current))
    }
}
