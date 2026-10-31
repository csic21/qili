#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import MoleApp

/// The normal test run checks fixture safety. PNG capture is explicitly opt-in.
/// Nothing here creates ContentView, MoleApp, live polling, or a live scan.
final class DesignSnapshotTests: XCTestCase {
    func testRunnerVersionDoesNotReplaceQiliVersion() {
        XCTAssertEqual(AppVersion.current, AppVersion.development,
                       "The XCTest host's bundle version must not appear in Qili snapshots.")
    }

    @MainActor
    func testNewStoreWaitsForAnExplicitScan() {
        let store = CleanStore()
        XCTAssertEqual(store.phase, .ready)
        XCTAssertFalse(store.hasScanned)
        XCTAssertFalse(store.scanning)
        XCTAssertTrue(store.categories.isEmpty)
        XCTAssertTrue(store.allowsLiveOperations)
    }

    @MainActor
    func testSnapshotActionsCannotStartLiveWork() async {
        for scenario in DesignScenario.allCases {
            let store = scenario.makeStore()
            let phase = store.phase
            let paths = store.categories.flatMap(\.children).map(\.id)
            let roots = store.categories.map(\.root)
            let selected = store.selected
            let scanning = store.scanning
            let stopped = store.stopped
            let hasScanned = store.hasScanned
            let cleaned = store.result?.cleaned
            let failed = store.result?.failed

            XCTAssertFalse(store.allowsLiveOperations, scenario.rawValue)
            XCTAssertTrue(roots.allSatisfy { $0.path.hasPrefix("/QiliPreview/") })
            XCTAssertTrue(paths.allSatisfy { $0.hasPrefix("/QiliPreview/") })
            store.scan()
            store.scan(showProgress: false)
            store.stop()
            await store.cleanup()

            XCTAssertEqual(store.phase, phase, scenario.rawValue)
            XCTAssertEqual(store.categories.map(\.root), roots, scenario.rawValue)
            XCTAssertEqual(store.categories.flatMap(\.children).map(\.id), paths, scenario.rawValue)
            XCTAssertEqual(store.selected, selected, scenario.rawValue)
            XCTAssertEqual(store.scanning, scanning, scenario.rawValue)
            XCTAssertEqual(store.stopped, stopped, scenario.rawValue)
            XCTAssertEqual(store.hasScanned, hasScanned, scenario.rawValue)
            XCTAssertEqual(store.result?.cleaned, cleaned, scenario.rawValue)
            XCTAssertEqual(store.result?.failed, failed, scenario.rawValue)
        }
    }

    @MainActor
    func testEmptyAndInaccessibleFixturesAreDistinct() {
        let empty = DesignScenario.empty.makeStore()
        let inaccessible = DesignScenario.inaccessible.makeStore()
        XCTAssertTrue(empty.categories.allSatisfy { $0.measured && !$0.partial && $0.children.isEmpty })
        XCTAssertTrue(inaccessible.categories.allSatisfy { $0.measured && $0.partial && $0.children.isEmpty })
        XCTAssertEqual(empty.categories.reduce(0) { $0 + $1.sizeBytes }, 0)
        XCTAssertEqual(inaccessible.categories.reduce(0) { $0 + $1.sizeBytes }, 0)
    }

    @MainActor
    func testCleanupFixturesCoverSuccessPartialAndFailure() throws {
        let success = try XCTUnwrap(DesignScenario.completed.makeStore().result)
        let partial = try XCTUnwrap(DesignScenario.partial.makeStore().result)
        let failure = try XCTUnwrap(DesignScenario.failed.makeStore().result)
        let deleted = try XCTUnwrap(DesignScenario.deleted.makeStore().result)
        XCTAssertGreaterThan(success.cleaned, 0)
        XCTAssertEqual(success.failed, 0)
        XCTAssertTrue(success.failures.isEmpty)
        XCTAssertGreaterThan(partial.cleaned, 0)
        XCTAssertGreaterThan(partial.failed, 0)
        XCTAssertEqual(partial.failures.count, partial.failed)
        XCTAssertEqual(failure.cleaned, 0)
        XCTAssertEqual(failure.cleanedBytes, 0)
        XCTAssertGreaterThan(failure.failed, 0)
        XCTAssertEqual(failure.failures.count, failure.failed)
        XCTAssertGreaterThan(deleted.cleaned, 0)
        XCTAssertEqual(deleted.mode, .delete)
    }

    func testCleanupOutcomeUsesCountsInsteadOfClaimingFreedSpace() {
        let cases: [(CleanupResult?, CleanOutcomePresentation.Kind, String, String)] = [
            (CleanupResult(cleaned: 4, failed: 0, cleanedBytes: 4096), .completed,
             "已移到废纸篓", "checkmark.circle"),
            (CleanupResult(cleaned: 2, failed: 1, cleanedBytes: 2048), .partial,
             "部分项目未能移动", "exclamationmark.circle"),
            (CleanupResult(cleaned: 0, failed: 3, cleanedBytes: 0), .failed,
             "未能移动所选项目", "xmark.circle"),
            (CleanupResult(cleaned: 0, failed: 0, cleanedBytes: 0), .unchanged,
             "未移动任何项目", "info.circle"),
            (nil, .unchanged, "未移动任何项目", "info.circle"),
            // Zero-byte files can be moved successfully. Size must not imply failure.
            (CleanupResult(cleaned: 1, failed: 0, cleanedBytes: 0), .completed,
             "已移到废纸篓", "checkmark.circle"),
            (CleanupResult(cleaned: 1, failed: 1, cleanedBytes: 0), .partial,
             "部分项目未能移动", "exclamationmark.circle"),
            // Direct deletion keeps the same honest counts with its own wording.
            (CleanupResult(mode: .delete, cleaned: 4, failed: 0, cleanedBytes: 4096), .completed,
             "已删除", "checkmark.circle"),
            (CleanupResult(mode: .delete, cleaned: 2, failed: 1, cleanedBytes: 2048), .partial,
             "部分项目未能删除", "exclamationmark.circle"),
            (CleanupResult(mode: .delete, cleaned: 0, failed: 3, cleanedBytes: 0), .failed,
             "未能删除所选项目", "xmark.circle"),
            (CleanupResult(mode: .delete, cleaned: 0, failed: 0, cleanedBytes: 0), .unchanged,
             "未删除任何项目", "info.circle"),
        ]
        for (result, kind, title, symbol) in cases {
            let presentation = CleanOutcomePresentation(result: result)
            XCTAssertEqual(presentation.kind, kind)
            XCTAssertEqual(presentation.title, title)
            XCTAssertEqual(presentation.symbol, symbol)
            XCTAssertFalse(presentation.title.contains("已释放"))
        }
    }

    @MainActor
    func testNewStoreStartsWithTrashModeAndNoCleanupProgress() {
        let store = CleanStore()
        XCTAssertEqual(store.cleanupMode, .trash)
        XCTAssertEqual(store.cleanupProgress.completed, 0)
        XCTAssertEqual(store.cleanupProgress.total, 0)
        XCTAssertNil(store.result)
    }

    @MainActor
    func testAnalyzeSnapshotsKeepSyntheticNavigationInert() throws {
        for scenario in AnalyzeDesignScenario.allCases {
            let store = scenario.makeStore()
            let path = store.path
            let ids = store.items.map(\.id)
            let bytes = store.totalBytes
            let error = store.error
            let stopped = store.stopped
            XCTAssertFalse(store.allowsLiveOperations)
            XCTAssertTrue(path.allSatisfy { $0.path.hasPrefix("/QiliPreview") })
            if let folder = store.items.first(where: \.isDirectory) { store.enter(folder) }
            store.goUp()
            store.jump(to: 0)
            store.open(URL(fileURLWithPath: "/QiliPreview/DoNotRead"))
            store.rescan()
            store.stop()
            XCTAssertEqual(store.path, path)
            XCTAssertEqual(store.items.map(\.id), ids)
            XCTAssertEqual(store.totalBytes, bytes)
            XCTAssertEqual(store.error, error)
            XCTAssertEqual(store.stopped, stopped)
            XCTAssertFalse(store.sizing)
        }
    }

    @MainActor
    func testStatusSnapshotsNeverStartPolling() {
        for scenario in StatusDesignScenario.allCases {
            let store = scenario.makeStore()
            let cpu = store.cpu
            let reading = store.hasCPUReading
            let history = store.cpuHistory
            let processes = store.processes.map(\.id)
            let downRate = store.downRate
            XCTAssertFalse(store.allowsLiveOperations)
            store.start()
            store.stop()
            store.start()
            XCTAssertEqual(store.cpu, cpu)
            XCTAssertEqual(store.hasCPUReading, reading)
            XCTAssertEqual(store.cpuHistory, history)
            XCTAssertEqual(store.processes.map(\.id), processes)
            XCTAssertEqual(store.downRate, downRate)
            XCTAssertEqual(store.hostName, "Qili Preview Mac")
            XCTAssertEqual(store.uptimeText, "2 天 4 小时")
            XCTAssertEqual(store.bootDateText, "10 月 9 日")
        }
    }

    @MainActor
    func testAppSnapshotsBlockDiscoveryUpdateAndLoginActions() async throws {
        let fixture = AppDesignFixtures()
        let appIDs = fixture.apps.apps.map(\.id)
        let generation = fixture.apps.generation
        let loginIDs = fixture.login.entries.map(\.id)
        let loaded = fixture.login.entries.map(\.loaded)
        let updateIDs = fixture.updates.updates.map(\.id)
        let checked = fixture.updates.lastChecked
        XCTAssertFalse(fixture.apps.allowsLiveOperations)
        XCTAssertFalse(fixture.login.allowsLiveOperations)
        XCTAssertFalse(fixture.updates.allowsLiveOperations)
        XCTAssertTrue(fixture.apps.apps.allSatisfy { $0.url.path.hasPrefix("/QiliPreview/") })
        fixture.apps.refresh()
        fixture.apps.stopMeasuring()
        for app in fixture.apps.apps { fixture.apps.loadIcon(for: app.id) }
        fixture.login.scan()
        await fixture.login.refreshStates()
        // A read-only system entry also prevents launchctl mutation if a guard regresses.
        let systemEntry = try XCTUnwrap(fixture.login.entries.first { $0.scope == .system })
        await fixture.login.setEnabled(systemEntry, enabled: true)
        await fixture.updates.check(apps: fixture.apps.apps, force: true)
        // Only a nonexistent synthetic app URL is passed, never a brew install action.
        await fixture.updates.perform(try XCTUnwrap(fixture.updates.updates.first))
        XCTAssertEqual(fixture.apps.apps.map(\.id), appIDs)
        XCTAssertEqual(fixture.apps.generation, generation)
        XCTAssertFalse(fixture.apps.scanning)
        XCTAssertFalse(fixture.apps.measuring)
        XCTAssertFalse(fixture.apps.stopped)
        XCTAssertEqual(fixture.login.entries.map(\.id), loginIDs)
        XCTAssertEqual(fixture.login.entries.map(\.loaded), loaded)
        XCTAssertTrue(fixture.login.errors.isEmpty)
        XCTAssertFalse(fixture.login.scanning)
        XCTAssertEqual(fixture.updates.updates.map(\.id), updateIDs)
        XCTAssertEqual(fixture.updates.lastChecked, checked)
        XCTAssertTrue(fixture.updates.messages.isEmpty)
        XCTAssertFalse(fixture.updates.checking)
        XCTAssertNil(fixture.updates.busyID)
    }

    @MainActor
    func testMaintenanceSnapshotsNeverRunCommands() async {
        for scenario in OptimizeDesignScenario.allCases {
            let store = scenario.makeStore()
            let statuses = store.states.map(\.status)
            let results = store.states.map(\.result)
            let selected = store.selected
            XCTAssertFalse(store.allowsLiveOperations)
            // Synthetic IDs provide a second barrier: they have no command implementation.
            XCTAssertTrue(store.states.allSatisfy { $0.id.hasPrefix("preview-") })
            store.requestStop()
            await store.runSelected()
            await store.runSelected(Set(store.states.map(\.id)))
            XCTAssertEqual(store.states.map(\.status), statuses)
            XCTAssertEqual(store.states.map(\.result), results)
            XCTAssertEqual(store.selected, selected)
            XCTAssertFalse(store.running)
            XCTAssertFalse(store.stopRequested)
        }
    }

    @MainActor
    func testCaptureNativeDesignSnapshots() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["QILI_CAPTURE_SNAPSHOTS"] == "1" else {
            throw XCTSkip("Opt in with scripts/capture_design_snapshots.sh to write native PNGs.")
        }
        let outputPath = try XCTUnwrap(environment["QILI_SNAPSHOT_DIRECTORY"],
                                       "An explicit QILI_SNAPSHOT_DIRECTORY is required.")
        XCTAssertTrue(outputPath.hasPrefix("/"), "The output directory must be absolute.")
        guard outputPath.hasPrefix("/") else { return }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        // This starts AppKit inside XCTest, never the @main application entry point.
        let app = NSApplication.shared
        guard !NSScreen.screens.isEmpty else {
            XCTFail("Native capture needs a graphical macOS login session with a screen.")
            return
        }
        let oldTimezone = NSTimeZone.default
        NSTimeZone.default = TimeZone(secondsFromGMT: 0)!
        defer { NSTimeZone.default = oldTimezone }
        let oldAppearance = app.appearance
        app.appearance = NSAppearance(named: .darkAqua)
        defer { app.appearance = oldAppearance }

        let sizes = [NSSize(width: 1060, height: 680), NSSize(width: 1220, height: 820)]
        let scenes = makeScenes()
        let processScenes = scenes.filter { $0.page == .status && $0.scenario == "metrics" }
        let plans: [(scene: SnapshotScene, size: NSSize, scrollToBottom: Bool)] =
            sizes.flatMap { size in scenes.map { ($0, size, false) } }
            + sizes.flatMap { size in processScenes.map { ($0, size, true) } }
        var captures: [[String: Any]] = []
        for plan in plans {
            let fixture = plan.scene
            let size = plan.size
            let scene = WorkspaceShell(tab: .constant(fixture.page), scrollKey: fixture.scenario) {
                fixture.content
            } footer: {
                fixture.footer
            }
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .environment(\.colorScheme, .dark)
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }

            let variant = plan.scrollToBottom ? "-process-table" : ""
            let name = "\(fixture.page.rawValue)-\(fixture.scenario)-\(Int(size.width))x\(Int(size.height))\(variant).png"
            let destination = output.appendingPathComponent(name)
            let scrollOrigin = try capture(scene, size: size, scrollToBottom: plan.scrollToBottom, to: destination)
            captures.append([
                "file": name,
                "page": fixture.page.rawValue,
                "sourceView": fixture.sourceView,
                "scenario": fixture.scenario,
                "width": Int(size.width),
                "height": Int(size.height),
                "scale": 1,
                "contrast": "standard",
                "appearance": "darkAqua",
                "viewport": plan.scrollToBottom ? "bottom-process-table" : "top",
                "scrollOriginY": Double(scrollOrigin ?? 0),
            ])
        }

        let manifest: [String: Any] = [
            "runID": environment["QILI_SNAPSHOT_RUN_ID"] ?? UUID().uuidString,
            "renderer": "NSHostingView + NSWindow native frame + NSView.cacheDisplay",
            "locale": "zh_CN",
            "timezone": "UTC",
            "captureCount": captures.count,
            "increasedContrastVerified": false,
            "data": "Synthetic /QiliPreview fixtures; live operations disabled",
            "system": ProcessInfo.processInfo.operatingSystemVersionString,
            "note": "Native fonts and AppKit rendering vary with the macOS release. These are review captures, not cross-OS pixel baselines.",
            "captures": captures,
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("manifest.json"), options: .atomic)
        XCTAssertEqual(captures.count, 46)
        XCTAssertEqual(Set(captures.compactMap { $0["page"] as? String }), Set(WorkspaceTab.allCases.map(\.rawValue)))
    }

    @MainActor
    func testCaptureUninstallSnapshots() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["QILI_CAPTURE_UNINSTALL"] == "1" else {
            throw XCTSkip("Opt in with QILI_CAPTURE_UNINSTALL=1 and QILI_SNAPSHOT_DIRECTORY.")
        }
        let output = URL(fileURLWithPath: try XCTUnwrap(environment["QILI_SNAPSHOT_DIRECTORY"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("A graphical login is required") }
        let app = ScannedApp(id: "/QiliPreview/Applications/Canvas.app",
            url: URL(fileURLWithPath: "/QiliPreview/Applications/Canvas.app"),
            name: "Canvas 绘图工作台", version: "1", bundleID: "org.example.canvas", modified: "")
        let identity = UninstallIdentity(device: 0, inode: 0, birthSeconds: 0, birthNanos: 0)
        let items = [
            UninstallItem(url: app.url, kind: .application, title: "应用本体", note: "卸载时必须包含应用本体",
                defaultSelected: true, requiresDataConsent: false, readOnly: false, identity: identity,
                sizeBytes: 245_000_000, partial: false),
            UninstallItem(url: URL(fileURLWithPath: "/QiliPreview/Library/Caches/org.example.canvas"),
                kind: .cache, title: "缓存", note: "按应用标识精确匹配", defaultSelected: true,
                requiresDataConsent: false, readOnly: false, identity: identity, sizeBytes: 32_000_000, partial: false),
            UninstallItem(url: URL(fileURLWithPath: "/QiliPreview/Library/Application Support/org.example.canvas"),
                kind: .support, title: "应用数据", note: "可能包含文稿和账号数据；默认保留", defaultSelected: false,
                requiresDataConsent: true, readOnly: false, identity: identity, sizeBytes: 482_000_000, partial: false),
            UninstallItem(url: URL(fileURLWithPath: "/QiliPreview/Library/LaunchDaemons/org.example.canvas.helper.plist"),
                kind: .systemAgent, title: "系统后台项", note: "只读；请使用官方卸载器处理", defaultSelected: false,
                requiresDataConsent: false, readOnly: true, identity: identity, sizeBytes: 4096, partial: false),
        ]
        let plan = UninstallPlan(app: app, items: items,
            notes: ["仅扫描预设位置；共享群组容器、钥匙串、云端数据和其他自定义位置不自动清理。",
                    "带驱动或系统扩展的软件请优先使用官方卸载器。"], blockedReason: nil)
        let partial = UninstallResult(appName: app.name, outcomes: items.enumerated().map { index, item in
            UninstallOutcome(id: item.id, title: item.title,
                status: index == 0 ? .moved : (index == 1 ? .failed : .retained),
                detail: index == 0 ? "已移到废纸篓" : (index == 1 ? "没有访问权限，请在访达中处理" : "未选择或只读，已保留"))
        }, remaining: Array(items.dropFirst()).map(\.id))
        // The sheet has a fixed 760×660 content area; native titlebar height varies by OS.
        let sheetFrameSize = NSWindow.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 760, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable]).size
        for result in [nil, partial] as [UninstallResult?] {
            let store = AppsStore(snapshot: .init(apps: [app], uninstallPlan: plan, uninstallResult: result))
            XCTAssertFalse(store.allowsLiveOperations)
            let view = AppUninstallView(store: store, app: app)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .environment(\.colorScheme, .dark)
            _ = try capture(view, size: sheetFrameSize, scrollToBottom: false,
                to: output.appendingPathComponent(result == nil ? "uninstall-review.png" : "uninstall-partial.png"))
        }
    }

    @MainActor
    private func makeScenes() -> [SnapshotScene] {
        var scenes = DesignScenario.allCases.map { scenario in
            let store = scenario.makeStore()
            XCTAssertFalse(store.allowsLiveOperations)
            return SnapshotScene(page: .clean, scenario: scenario.rawValue,
                content: AnyView(CleanPage(store: store)),
                footer: store.phase == .list ? AnyView(CleanSelectionBar(store: store)) : AnyView(EmptyView()))
        }
        for scenario in AnalyzeDesignScenario.allCases {
            let store = scenario.makeStore()
            XCTAssertFalse(store.allowsLiveOperations)
            scenes.append(SnapshotScene(page: .analyze, scenario: scenario.rawValue,
                content: AnyView(AnalyzePage(snapshotStore: store, listMode: scenario != .cards, showHidden: true))))
        }
        for scenario in StatusDesignScenario.allCases {
            let store = scenario.makeStore()
            XCTAssertFalse(store.allowsLiveOperations)
            scenes.append(SnapshotScene(page: .status, scenario: scenario.rawValue,
                content: AnyView(StatusPage(store: store))))
        }
        let sections: [(String, AppsPage.PreviewSection)] = [
            ("inventory", .inventory), ("updates", .updates), ("login", .login),
        ]
        for (name, section) in sections {
            let fixture = AppDesignFixtures()
            scenes.append(SnapshotScene(page: .apps, scenario: name,
                content: AnyView(AppsPage(store: fixture.apps, loginStore: fixture.login,
                                          updateStore: fixture.updates, previewSection: section))))
        }
        for scenario in OptimizeDesignScenario.allCases {
            let store = scenario.makeStore()
            XCTAssertFalse(store.allowsLiveOperations)
            scenes.append(SnapshotScene(page: .optimize, scenario: scenario.rawValue,
                content: AnyView(OptimizePage(store: store))))
        }
        return scenes
    }

    @MainActor
    private func capture<V: View>(_ root: V, size: NSSize, scrollToBottom: Bool, to destination: URL) throws -> CGFloat? {
        let window = SnapshotWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "栖理"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Theme.canvas)
        window.isMovableByWindowBackground = true
        window.animationBehavior = .none
        window.contentView = NSHostingView(rootView: root)
        // Set the complete frame, so exported PNG dimensions include native chrome.
        window.setFrame(NSRect(origin: NSPoint(x: 100, y: 100), size: size), display: true)
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        // Let SwiftUI/AppKit finish their scheduled layout, without starting app stores.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.12))
        let frame = try XCTUnwrap(window.contentView?.superview)
        frame.layoutSubtreeIfNeeded()
        let scrollOrigin: CGFloat?
        if scrollToBottom { scrollOrigin = try scrollMainContentToBottom(in: frame) }
        else { scrollOrigin = nil }
        pauseIndeterminateIndicators(in: frame)
        frame.displayIfNeeded()
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try XCTUnwrap(window.standardWindowButton(kind))
            XCTAssertFalse(button.isHidden, "Native window controls must remain visible.")
        }
        XCTAssertEqual(Int(frame.bounds.width), Int(size.width))
        XCTAssertEqual(Int(frame.bounds.height), Int(size.height))

        // Explicit 1x output is independent of the connected display's Retina scale.
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.size = size
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: destination, options: .atomic)
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(decoded.pixelsWide, Int(size.width))
        XCTAssertEqual(decoded.pixelsHigh, Int(size.height))
        XCTAssertGreaterThan(png.count, 10_000, "Unexpectedly empty native capture: \(destination.lastPathComponent)")
        return scrollOrigin
    }

    @MainActor
    private func scrollMainContentToBottom(in frame: NSView) throws -> CGFloat {
        func scrollViews(in view: NSView) -> [NSScrollView] {
            let own = (view as? NSScrollView).map { [$0] } ?? []
            return own + view.subviews.flatMap { scrollViews(in: $0) }
        }
        // The workspace's vertical scroller is the widest overflowing scroll view.
        let candidates = scrollViews(in: frame).filter { scroll in
            guard let document = scroll.documentView else { return false }
            return document.bounds.height > scroll.contentView.bounds.height + 1
        }
        let scroll = try XCTUnwrap(candidates.max { $0.contentView.bounds.width < $1.contentView.bounds.width },
                                   "Expected the real workspace vertical scroll view.")
        let document = try XCTUnwrap(scroll.documentView)
        let clip = scroll.contentView
        let initialY = clip.bounds.origin.y

        // Lazy native content can refine its height after entering the viewport.
        // Recompute the endpoint after layout rather than hard-coding an offset.
        for _ in 0..<4 {
            document.layoutSubtreeIfNeeded()
            let bottomY = document.isFlipped
                ? max(document.bounds.minY, document.bounds.maxY - clip.bounds.height)
                : document.bounds.minY
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: bottomY))
            scroll.reflectScrolledClipView(clip)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.04))
            frame.layoutSubtreeIfNeeded()
        }
        let expectedY = document.isFlipped
            ? max(document.bounds.minY, document.bounds.maxY - clip.bounds.height)
            : document.bounds.minY
        XCTAssertGreaterThan(abs(clip.bounds.origin.y - initialY), 1,
                             "The process-table capture must move below the initial fold.")
        XCTAssertEqual(clip.bounds.origin.y, expectedY, accuracy: 2,
                       "The last content section, containing the process table, must be in the viewport.")
        frame.displayIfNeeded()
        return clip.bounds.origin.y
    }

    @MainActor
    private func pauseIndeterminateIndicators(in view: NSView) {
        if let indicator = view as? NSProgressIndicator, indicator.isIndeterminate {
            // Keep the real native control visible, only stop its animation clock.
            indicator.isDisplayedWhenStopped = true
            indicator.usesThreadedAnimation = false
            indicator.stopAnimation(nil)
        }
        view.subviews.forEach { pauseIndeterminateIndicators(in: $0) }
    }
}

/// CI's virtual screen may be smaller than the requested bitmap. Preserve the
/// requested native frame instead of allowing AppKit to clamp it to the display.
private final class SnapshotWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

private enum DesignScenario: String, CaseIterable {
    case initial, scanning, results, selection, empty, inaccessible, trashing, completed, partial, failed, deleted

    @MainActor
    func makeStore() -> CleanStore {
        var categories = Self.categories()
        let selected = Set(categories[0].children.map(\.id))
        switch self {
        case .initial:
            return CleanStore(snapshot: .init(phase: .ready, hasScanned: false))
        case .scanning:
            for index in 2..<categories.count {
                categories[index].measured = false
                categories[index].children = []
                categories[index].sizeBytes = 0
            }
            return CleanStore(snapshot: .init(phase: .scanning, categories: categories,
                scanning: true, measuredCount: 2, currentCategory: "Xcode 构建缓存"))
        case .results:
            return CleanStore(snapshot: .init(phase: .result, categories: categories,
                                              measuredCount: categories.count))
        case .selection:
            return CleanStore(snapshot: .init(phase: .list, categories: categories,
                measuredCount: categories.count, selected: selected, expanded: ["user-caches"]))
        case .empty, .inaccessible:
            for index in categories.indices {
                categories[index].children = []
                categories[index].sizeBytes = 0
                categories[index].partial = self == .inaccessible
            }
            return CleanStore(snapshot: .init(phase: .result, categories: categories,
                                              measuredCount: categories.count))
        case .trashing:
            return CleanStore(snapshot: .init(phase: .trashing, categories: categories,
                measuredCount: categories.count, selected: selected,
                cleanupProgress: .init(completed: 2, total: 3, currentName: "com.example.browser",
                                       cleanedBytes: 838_860_800)))
        case .completed:
            return CleanStore(snapshot: .init(phase: .done, categories: [], result:
                CleanupResult(cleaned: 8, failed: 0, cleanedBytes: 4_194_304_000)))
        case .partial:
            return CleanStore(snapshot: .init(phase: .done, categories: [], result:
                CleanupResult(cleaned: 6, failed: 2, cleanedBytes: 3_145_728_000, failures: [
                    "com.example.canvas：路径已变化或不可访问",
                    "Build.log：没有权限移动此项目",
                ])))
        case .failed:
            return CleanStore(snapshot: .init(phase: .done, categories: [], result:
                CleanupResult(cleaned: 0, failed: 2, cleanedBytes: 0, failures: [
                    "com.example.canvas：路径已变化或不可访问",
                    "Build.log：没有权限移动此项目",
                ])))
        case .deleted:
            return CleanStore(snapshot: .init(phase: .done, categories: [],
                result: CleanupResult(mode: .delete, cleaned: 8, failed: 0, cleanedBytes: 4_194_304_000),
                cleanupMode: .delete))
        }
    }

    private static func categories() -> [CleanCategory] {
        [
            category("user-caches", "用户缓存", "应用缓存，删除后会自动重建", [
                ("com.example.canvas", 1_677_721_600),
                ("com.example.browser", 838_860_800),
                ("com.example.notes", 314_572_800),
            ]),
            category("user-logs", "用户日志", "诊断与运行日志", [
                ("Build.log", 104_857_600),
                ("Session.log", 52_428_800),
            ]),
            category("xcode-derived", "Xcode 构建缓存", "DerivedData，重新构建即可恢复", [
                ("SampleWorkspace", 1_258_291_200),
            ]),
            category("xcode-device", "Xcode 设备支持", "设备符号，重新连接设备会恢复", [
                ("Example Device Symbols", 629_145_600),
            ]),
            category("npm", "npm 缓存", "_cacache，重新下载即可", [
                ("_cacache", 419_430_400),
            ]),
        ]
    }

    private static func category(_ id: String, _ title: String, _ note: String,
                                 _ entries: [(String, Int64)]) -> CleanCategory {
        let root = URL(fileURLWithPath: "/QiliPreview/\(id)", isDirectory: true)
        let items = entries.map { entry in
            CleanItem(id: root.appendingPathComponent(entry.0).path, name: entry.0, sizeBytes: entry.1)
        }
        return CleanCategory(id: id, title: title, note: note, root: root, mode: .children,
            measured: true, sizeBytes: items.reduce(0) { $0 + $1.sizeBytes }, children: items)
    }
}

private struct SnapshotScene {
    let page: WorkspaceTab
    let scenario: String
    let content: AnyView
    let footer: AnyView

    init(page: WorkspaceTab, scenario: String, content: AnyView, footer: AnyView = AnyView(EmptyView())) {
        self.page = page
        self.scenario = scenario
        self.content = content
        self.footer = footer
    }

    var sourceView: String {
        switch page {
        case .clean: "CleanPage"
        case .apps: "AppsPage"
        case .optimize: "OptimizePage"
        case .analyze: "AnalyzePage"
        case .status: "StatusPage"
        }
    }
}

private enum AnalyzeDesignScenario: String, CaseIterable {
    case cards, list, empty, failed

    @MainActor
    func makeStore() -> AnalyzeStore {
        let home = URL(fileURLWithPath: "/QiliPreview", isDirectory: true)
        let folder = home.appendingPathComponent("Workspace", isDirectory: true)
        let definitions: [(String, Bool, Int64)] = [
            ("Projects", true, 18_254_643_200),
            ("Design Library", true, 8_589_934_592),
            ("Downloads", true, 4_294_967_296),
            ("Screen Recording.mov", false, 1_677_721_600),
            (".build", true, 838_860_800),
            ("Project notes.pdf", false, 8_388_608),
        ]
        let items = definitions.map { name, directory, bytes in
            let url = folder.appendingPathComponent(name, isDirectory: directory)
            return AnalyzeItem(id: url.path, url: url, name: name, isDirectory: directory,
                               sizeBytes: bytes)
        }
        switch self {
        case .cards, .list:
            return AnalyzeStore(snapshot: .init(home: home, path: [home, folder], items: items,
                                                 sizedCount: items.count))
        case .empty:
            return AnalyzeStore(snapshot: .init(home: home, path: [home, folder]))
        case .failed:
            return AnalyzeStore(snapshot: .init(home: home, path: [home, folder],
                                                 error: "无法访问此文件夹。请选择其他位置后重试。"))
        }
    }
}

private enum StatusDesignScenario: String, CaseIterable {
    case metrics, unavailable

    @MainActor
    func makeStore() -> StatusStore {
        var snapshot = StatusStore.PreviewSnapshot()
        if self == .metrics {
            snapshot.cpu = 24.8
            snapshot.hasCPUReading = true
            snapshot.memPercent = 56.4
            snapshot.memUsedText = "20.3 GB"
            snapshot.swapText = "512 MB"
            snapshot.diskPercent = 61.2
            snapshot.diskUsedText = "612 GB"
            snapshot.diskFreeText = "388 GB"
            snapshot.downRate = 2_306_867
            snapshot.upRate = 314_573
            snapshot.load = [2.41, 1.82, 1.36]
            snapshot.battery = .init(percent: 84, charging: false, onAC: false)
            snapshot.gpu = 18.6
            snapshot.temperature = 43.0
            snapshot.fanRPM = 1280
            snapshot.processes = [
                RealProcess(id: 101, name: "Canvas", memBytes: 1_717_986_918, cpu: 8.2),
                RealProcess(id: 102, name: "Example Browser", memBytes: 1_288_490_189, cpu: 5.1),
                RealProcess(id: 103, name: "Code Studio", memBytes: 943_718_400, cpu: 3.4),
                RealProcess(id: 104, name: "Notes", memBytes: 251_658_240, cpu: 0.8),
                RealProcess(id: 105, name: "Qili Preview", memBytes: 100_663_296, cpu: 0.4),
            ]
            snapshot.cpuHistory = (0..<42).map { 18 + Double(($0 * 7) % 19) }
            snapshot.netHistory = (0..<42).map { 800_000 + Double(($0 * 17) % 23) * 80_000 }
            snapshot.gpuHistory = (0..<42).map { 8 + Double(($0 * 3) % 17) }
        }
        return StatusStore(snapshot: snapshot)
    }
}

@MainActor
private struct AppDesignFixtures {
    let apps: AppsStore
    let login: LoginItemsStore
    let updates: UpdateStore

    init() {
        let root = URL(fileURLWithPath: "/QiliPreview/Applications", isDirectory: true)
        let definitions: [(String, String, String, Int64, String)] = [
            ("Canvas", "3.4.1", "com.example.canvas", 838_860_800, "paintbrush.pointed"),
            ("Code Studio", "2.8.0", "com.example.code", 1_677_721_600, "curlybraces.square"),
            ("Example Browser", "128.0", "com.example.browser", 734_003_200, "globe"),
            ("Notes", "1.6.2", "com.example.notes", 104_857_600, "note.text"),
        ]
        let items = definitions.map { name, version, bundleID, bytes, symbol in
            let url = root.appendingPathComponent(name + ".app", isDirectory: true)
            return ScannedApp(id: url.path, url: url, name: name, version: version,
                bundleID: bundleID, modified: "2026-10-10", sizeBytes: bytes,
                icon: NSImage(systemSymbolName: symbol, accessibilityDescription: name))
        }
        apps = AppsStore(snapshot: .init(apps: items, sizedCount: items.count))
        login = LoginItemsStore(snapshot: .init(entries: [
            LoginEntry(id: "/QiliPreview/LaunchAgents/com.example.canvas.helper.plist",
                label: "com.example.canvas.helper", program: "/QiliPreview/Applications/Canvas.app/Contents/MacOS/Helper",
                scope: .user, loaded: true, disabled: false, configuredDisabled: false, processID: 4200, stateKnown: true),
            LoginEntry(id: "/QiliPreview/LaunchAgents/com.example.notes.sync.plist",
                label: "com.example.notes.sync", program: "/QiliPreview/Applications/Notes.app/Contents/MacOS/Sync",
                scope: .user, loaded: false, disabled: true, configuredDisabled: true, processID: nil, stateKnown: true),
            LoginEntry(id: "/QiliPreview/SystemAgents/com.example.system.agent.plist",
                label: "com.example.system.agent", program: "/QiliPreview/System/ExampleAgent",
                scope: .system, loaded: true, disabled: false, configuredDisabled: false, processID: 4202, stateKnown: true),
        ]))
        updates = UpdateStore(snapshot: .init(updates: [
            UpdateInfo(id: "preview-canvas", name: "Canvas", source: "Sparkle", from: "3.4.1", to: "3.5.0",
                       action: .sparkle(app: items[0].url)),
            UpdateInfo(id: "preview-code", name: "Code Studio", source: "Sparkle", from: "2.8.0", to: "2.9.1",
                       action: .sparkle(app: items[1].url)),
        ], lastChecked: Date(timeIntervalSince1970: 1_791_669_000)))
    }
}

private enum OptimizeDesignScenario: String, CaseIterable {
    case ready, results

    @MainActor
    func makeStore() -> OptimizeStore {
        // Preserve the production task content while using IDs that cannot resolve to commands.
        var states = OptimizeStore.defaultTasks().map { task in
            OptimizeTaskState(id: "preview-" + task.id, title: task.title, note: task.note,
                              requiresAuth: task.requiresAuth, readOnly: task.readOnly)
        }
        if self == .results {
            states[0].status = .done
            states[0].result = "缩略图缓存已重建"
            states[0].output = "Preview fixture: thumbnail cache reset completed."
            states[0].duration = 0.3
            states[1].status = .skipped
            states[1].result = "已取消授权，未做任何改动"
            states[1].output = "Preview fixture: authorization cancelled."
            states[1].duration = 1.2
            states[2].status = .done
            states[2].result = "索引正常启用，无需处理"
            states[2].output = "Preview fixture: indexing enabled."
            states[2].duration = 0.2
            states[3].status = .failed
            states[3].result = "校验未通过，建议在「磁盘工具」中查看"
            states[3].output = "Preview fixture: verification unavailable."
            states[3].duration = 4.1
        }
        return OptimizeStore(snapshot: .init(states: states, selected: ["preview-spotlight"]))
    }
}
#endif
