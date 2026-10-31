import AppKit
import XCTest
@testable import MoleApp

final class AppUninstallerTests: XCTestCase {
    struct Fixture {
        let root: URL
        let environment: UninstallEnvironment
        let app: ScannedApp
    }

    private func write(_ url: URL, data: Data = Data("fixture".utf8)) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func makeApp(_ url: URL, id: String = "org.example.canvas", name: String = "Canvas") throws -> ScannedApp {
        let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "APPL"]
        try write(url.appendingPathComponent("Contents/Info.plist"),
                  data: PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0))
        return ScannedApp(id: url.path, url: url, name: name, version: "1", bundleID: id, modified: "")
    }

    private func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("qili-uninstall-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let applications = root.appendingPathComponent("Applications")
        let app = try makeApp(applications.appendingPathComponent("Canvas.app"))
        return Fixture(root: root, environment: UninstallEnvironment(home: home, applicationRoots: [applications],
            systemLibrary: root.appendingPathComponent("SystemLibrary"), currentApp: root.appendingPathComponent("Qili.app")), app: app)
    }

    private func userPath(_ f: Fixture, _ path: String) -> URL {
        f.environment.home.appendingPathComponent("Library/" + path)
    }

    private func agent(_ url: URL, program: String, label: String = "org.example.canvas.helper") throws {
        try write(url, data: PropertyListSerialization.data(fromPropertyList:
            ["Label": label, "ProgramArguments": [program]], format: .xml, options: 0))
    }

    func testScanUsesExactIDsAndKeepsDataOptIn() throws {
        let f = try fixture()
        try write(userPath(f, "Caches/org.example.canvas/file"))
        try write(userPath(f, "Preferences/org.example.canvas.plist"))
        try write(userPath(f, "Application Support/org.example.canvas/document"))
        try write(userPath(f, "Containers/org.example.canvas/document"))
        try write(userPath(f, "Application Support/Canvas/document"))
        try write(userPath(f, "Caches/org.example.canvas-other/file"))
        try write(userPath(f, "Group Containers/org.example.canvas/document"))
        let plan = AppUninstaller.scan(app: f.app, environment: f.environment)
        XCTAssertNil(plan.blockedReason)
        XCTAssertEqual(plan.items.count, 6)
        XCTAssertEqual(plan.defaultSelection.count, 3)
        XCTAssertTrue(plan.items.filter { $0.requiresDataConsent }.allSatisfy { !$0.defaultSelected })
        XCTAssertFalse(plan.items.contains { $0.id.contains("canvas-other") || $0.id.contains("Group Containers") })
    }

    func testSharedBundleIDAndNameRemainReadOnly() throws {
        let f = try fixture()
        _ = try makeApp(f.environment.applicationRoots[0].appendingPathComponent("Canvas Copy.app"))
        try write(userPath(f, "Caches/org.example.canvas/file"))
        try write(userPath(f, "Application Support/Canvas/document"))
        let plan = AppUninstaller.scan(app: f.app, environment: f.environment)
        XCTAssertEqual(plan.defaultSelection, [f.app.id])
        XCTAssertTrue(plan.items.filter { $0.kind != .application }.allSatisfy(\.readOnly))
    }

    func testOnlyAgentsWithExecutableInsideAppMatchAndSystemAgentsAreReadOnly() throws {
        let f = try fixture()
        let good = userPath(f, "LaunchAgents/org.example.canvas.helper.plist")
        try agent(good, program: f.app.url.appendingPathComponent("Contents/MacOS/helper").path)
        try agent(userPath(f, "LaunchAgents/org.example.canvas.unrelated.plist"), program: "/usr/bin/true")
        try agent(userPath(f, "LaunchAgents/org.example.canvas.sibling.plist"), program: f.app.url.path + "-other/helper")
        try agent(f.environment.systemLibrary.appendingPathComponent("LaunchDaemons/helper.plist"),
                  program: f.app.url.appendingPathComponent("Contents/MacOS/system-helper").path)
        let plan = AppUninstaller.scan(app: f.app, environment: f.environment)
        XCTAssertEqual(plan.items.filter { $0.kind == .agent }.map(\.id), [good.path])
        XCTAssertTrue(try XCTUnwrap(plan.items.first { $0.kind == .systemAgent }).readOnly)
    }

    func testRejectsSystemSelfOutsideAndMalformedIdentity() throws {
        let f = try fixture()
        let outside = try makeApp(f.root.appendingPathComponent("Outside.app"))
        XCTAssertNotNil(AppUninstaller.scan(app: outside, environment: f.environment).blockedReason)
        let apple = try makeApp(f.environment.applicationRoots[0].appendingPathComponent("System.app"), id: "com.apple.fixture")
        XCTAssertNotNil(AppUninstaller.scan(app: apple, environment: f.environment).blockedReason)
        let own = try makeApp(f.environment.applicationRoots[0].appendingPathComponent("Qili.app"), id: "com.csic21.moleapp")
        XCTAssertNotNil(AppUninstaller.scan(app: own, environment: f.environment).blockedReason)
        let bad = try makeApp(f.environment.applicationRoots[0].appendingPathComponent("Bad.app"), id: "../../Documents")
        XCTAssertNotNil(AppUninstaller.scan(app: bad, environment: f.environment).blockedReason)
        for id in ["", "..", "org..test", "org/test", "org.test/../../Documents"] { XCTAssertFalse(AppUninstaller.isBundleID(id)) }
    }

    func testScanRejectsSymlinkedFilesAndParents() throws {
        let f = try fixture()
        let outside = f.root.appendingPathComponent("outside")
        try write(outside.appendingPathComponent("important"))
        let path = userPath(f, "Caches/org.example.canvas")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: outside)
        XCTAssertFalse(AppUninstaller.scan(app: f.app, environment: f.environment).items.contains { $0.id == path.path })
        let logs = userPath(f, "Logs")
        try FileManager.default.createSymbolicLink(at: logs, withDestinationURL: outside)
        try write(outside.appendingPathComponent("org.example.canvas/file"))
        XCTAssertFalse(AppUninstaller.scan(app: f.app, environment: f.environment).items.contains { $0.kind == .logs })
    }

    func testUninstallMovesOnlyReviewedSelectionAndRechecksRemainingPaths() async throws {
        let f = try fixture()
        let cache = userPath(f, "Caches/org.example.canvas")
        let data = userPath(f, "Application Support/org.example.canvas/document")
        try write(cache.appendingPathComponent("cache"))
        try write(data)
        let plan = AppUninstaller.scan(app: f.app, environment: f.environment)
        let simulatedTrash = f.root.appendingPathComponent("simulated-trash")
        try FileManager.default.createDirectory(at: simulatedTrash, withIntermediateDirectories: true)
        var moved: [String] = []
        let result = await AppUninstaller.perform(plan: plan, selected: plan.defaultSelection, environment: f.environment,
            isRunning: { false }, trash: { url in
                moved.append(url.path)
                try FileManager.default.moveItem(at: url, to: simulatedTrash.appendingPathComponent(url.lastPathComponent))
            }, stopAgent: { _, _ in XCTFail("No agent expected") })
        XCTAssertEqual(moved.first, f.app.id)
        XCTAssertEqual(Set(moved), plan.defaultSelection)
        XCTAssertEqual(result.moved, 2)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.remaining, [data.deletingLastPathComponent().path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.path))
        XCTAssertTrue(result.outcomes.contains { $0.status == .retained })
    }

    func testPreflightRejectsReplacedEntryUnknownSelectionAndRunningApp() async throws {
        let f = try fixture()
        let cache = userPath(f, "Caches/org.example.canvas")
        try write(cache.appendingPathComponent("old"))
        let plan = AppUninstaller.scan(app: f.app, environment: f.environment)
        try FileManager.default.moveItem(at: cache, to: f.root.appendingPathComponent("old-cache"))
        try write(cache.appendingPathComponent("new"))
        let replaced = await AppUninstaller.perform(plan: plan, selected: plan.defaultSelection, environment: f.environment,
            isRunning: { false }, trash: { _ in XCTFail("Replaced path must not be touched") })
        XCTAssertEqual(replaced.moved, 0)
        XCTAssertGreaterThan(replaced.failed, 0)
        let fresh = AppUninstaller.scan(app: f.app, environment: f.environment)
        let unknown = await AppUninstaller.perform(plan: fresh, selected: [f.app.id, f.root.path], environment: f.environment,
            isRunning: { false }, trash: { _ in XCTFail("Unknown selection must not be touched") })
        XCTAssertEqual(unknown.moved, 0)
        let running = await AppUninstaller.perform(plan: fresh, selected: fresh.defaultSelection, environment: f.environment,
            isRunning: { true }, trash: { _ in XCTFail("Running application must not be touched") })
        XCTAssertEqual(running.moved, 0)
        XCTAssertGreaterThan(running.failed, 0)
    }

    func testNoDataMovesIfAppMoveFailsAndConsentIsEnforced() async throws {
        let f = try fixture()
        try write(userPath(f, "Application Support/org.example.canvas/document"))
        let plan = AppUninstaller.scan(app: f.app, environment: f.environment)
        let selected = Set(plan.items.map(\.id))
        let noConsent = await AppUninstaller.perform(plan: plan, selected: selected, environment: f.environment,
            isRunning: { false }, trash: { _ in XCTFail("Data requires explicit consent") })
        XCTAssertEqual(noConsent.moved, 0)
        var attempts: [String] = []
        let failed = await AppUninstaller.perform(plan: plan, selected: selected, dataConsent: true, environment: f.environment,
            isRunning: { false }, trash: { url in
                attempts.append(url.path)
                throw AppUninstaller.UninstallError("Permission denied")
            })
        XCTAssertEqual(attempts, [f.app.id])
        XCTAssertEqual(failed.moved, 0)
        XCTAssertEqual(failed.failed, 2)
    }

    func testAgentStopFailurePreservesAllFiles() async throws {
        let f = try fixture()
        try agent(userPath(f, "LaunchAgents/org.example.canvas.helper.plist"),
                  program: f.app.url.appendingPathComponent("Contents/MacOS/helper").path)
        let plan = AppUninstaller.scan(app: f.app, environment: f.environment)
        var stopped = 0
        let result = await AppUninstaller.perform(plan: plan, selected: plan.defaultSelection, environment: f.environment,
            isRunning: { false }, trash: { _ in XCTFail("Stop failure must preserve files") }, stopAgent: { _, _ in
                stopped += 1
                throw AppUninstaller.UninstallError("Refused")
            })
        XCTAssertEqual(stopped, 1)
        XCTAssertEqual(result.moved, 0)
        XCTAssertGreaterThan(result.failed, 0)
    }

    func testNewDuplicateAfterReviewPreventsRelatedFileRemoval() async throws {
        let f = try fixture()
        try write(userPath(f, "Caches/org.example.canvas/file"))
        let plan = AppUninstaller.scan(app: f.app, environment: f.environment)
        _ = try makeApp(f.environment.applicationRoots[0].appendingPathComponent("NewCopy.app"))
        let result = await AppUninstaller.perform(plan: plan, selected: plan.defaultSelection, environment: f.environment,
            isRunning: { false }, trash: { _ in XCTFail("New shared ownership invalidates the plan") })
        XCTAssertEqual(result.moved, 0)
        XCTAssertGreaterThan(result.failed, 0)
    }

    func testKeepAliveAgentIsStoppedBeforeCheckingRemainingProcesses() async throws {
        let f = try fixture()
        try agent(userPath(f, "LaunchAgents/org.example.canvas.helper.plist"),
                  program: f.app.url.appendingPathComponent("Contents/MacOS/helper").path)
        let plan = AppUninstaller.scan(app: f.app, environment: f.environment)
        let trash = f.root.appendingPathComponent("simulated-trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        var running = true
        var stopped = false
        var moved: [String] = []
        let result = await AppUninstaller.perform(plan: plan, selected: plan.defaultSelection, environment: f.environment,
            isRunning: { running }, trash: { url in
                XCTAssertTrue(stopped)
                moved.append(url.path)
                try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
            }, stopAgent: { _, _ in running = false; stopped = true })
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.moved, 2)
        XCTAssertEqual(moved.first, f.app.id)
        XCTAssertTrue(result.remaining.isEmpty)
    }

    func testPartialFailureReportsActualMovesAndRemainingFiles() async throws {
        let f = try fixture()
        let cache = userPath(f, "Caches/org.example.canvas")
        try write(cache.appendingPathComponent("cache"))
        let plan = AppUninstaller.scan(app: f.app, environment: f.environment)
        let result = await AppUninstaller.perform(plan: plan, selected: plan.defaultSelection, environment: f.environment,
            isRunning: { false }, trash: { url in
                if url.path == f.app.id {
                    try FileManager.default.moveItem(at: url, to: f.root.appendingPathComponent("simulated-trash.app"))
                } else { throw AppUninstaller.UninstallError("Permission denied") }
            })
        XCTAssertEqual(result.moved, 1)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.remaining, [cache.path])
        XCTAssertEqual(result.title, "部分项目未能移到废纸篓")
    }

    func testParentSymlinkSwapAfterReviewPreventsEveryMove() async throws {
        let f = try fixture()
        let cache = userPath(f, "Caches/org.example.canvas")
        try write(cache.appendingPathComponent("cache"))
        let plan = AppUninstaller.scan(app: f.app, environment: f.environment)
        let parent = cache.deletingLastPathComponent()
        let oldParent = f.root.appendingPathComponent("old-caches")
        try FileManager.default.moveItem(at: parent, to: oldParent)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: oldParent)
        let result = await AppUninstaller.perform(plan: plan, selected: plan.defaultSelection, environment: f.environment,
            isRunning: { false }, trash: { _ in XCTFail("Parent symlink replacement must block all movement") })
        XCTAssertEqual(result.moved, 0)
        XCTAssertGreaterThan(result.failed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.app.id))
    }

    @MainActor
    func testSnapshotStoreCannotScanQuitOrUninstall() async throws {
        let app = ScannedApp(id: "/QiliPreview/Canvas.app", url: URL(fileURLWithPath: "/QiliPreview/Canvas.app"),
            name: "Canvas", version: "1", bundleID: "org.example.canvas", modified: "")
        let store = AppsStore(snapshot: .init(apps: [app]))
        store.prepareUninstall(app)
        await store.uninstall(selected: [app.id], dataConsent: true)
        store.cancelUninstallScan()
        XCTAssertNil(store.uninstallPlan)
        XCTAssertNil(store.uninstallResult)
        XCTAssertFalse(store.uninstallScanning)
        XCTAssertFalse(store.uninstalling)
    }
}
