import AppKit
import SwiftUI

/// 一台机器上真实扫描到的应用。
struct ScannedApp: Identifiable {
    let id: String
    let url: URL
    let name: String
    let version: String
    let bundleID: String
    let modified: String
    var sizeBytes: Int64?
    var icon: NSImage?
    var partial = false
}

/// 展开时按 Bundle ID / 名称找出的关联残留(存在才算)。
struct LeftoverItem: Identifiable {
    let id: String
    let kind: String
    let path: String
    let sizeBytes: Int64
    var partial = false
}

@MainActor
final class AppsStore: ObservableObject {
    @Published private(set) var apps: [ScannedApp] = []
    @Published private(set) var scanning = false
    @Published private(set) var sizedCount = 0
    @Published private(set) var measuring = false
    @Published private(set) var generation = 0
    @Published private(set) var hasScanned = false
    @Published private(set) var stopped = false

    /// DEBUG snapshots keep every filesystem entry point inert, even from view tasks.
    private(set) var allowsLiveOperations = true
    private var sizeTask: Task<Void, Never>?
    @Published private(set) var uninstallPlan: UninstallPlan?
    @Published private(set) var uninstallScanning = false
    @Published private(set) var uninstalling = false
    @Published private(set) var uninstallProgress = 0
    @Published private(set) var uninstallTotal = 0
    @Published private(set) var uninstallResult: UninstallResult?
    @Published private(set) var uninstallError: String?
    private var uninstallScanTask: Task<Void, Never>?
    private var uninstallScanID = UUID()

    func prepareUninstall(_ app: ScannedApp) {
        guard allowsLiveOperations, !uninstalling else { return }
        cancelUninstallScan()
        let scanID = UUID()
        uninstallScanID = scanID
        uninstallPlan = nil
        uninstallResult = nil
        uninstallError = nil
        uninstallScanning = true
        uninstallScanTask = Task {
            let task = Task.detached(priority: .userInitiated) { AppUninstaller.scan(app: app) }
            let plan = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled, self.uninstallScanID == scanID else { return }
            self.uninstallPlan = plan
            self.uninstallScanning = false
        }
    }

    func cancelUninstallScan() {
        guard allowsLiveOperations, !uninstalling else { return }
        uninstallScanTask?.cancel()
        uninstallScanID = UUID()
        uninstallScanning = false
    }

    /// Includes embedded helpers and a different running copy with the same bundle ID.
    static func runningInstances(of app: ScannedApp) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { running in
            running.bundleIdentifier == app.bundleID || running.bundleURL.map {
                $0.path == app.url.path || $0.path.hasPrefix(app.url.path + "/")
            } == true || running.executableURL.map { $0.path.hasPrefix(app.url.path + "/") } == true
        }
    }

    func uninstall(selected: Set<String>, dataConsent: Bool) async {
        guard allowsLiveOperations, !uninstalling, !uninstallScanning,
              let plan = uninstallPlan, plan.blockedReason == nil else { return }
        guard selected.contains(plan.app.url.path),
              !plan.items.contains(where: { selected.contains($0.id) && $0.requiresDataConsent && !dataConsent }) else {
            uninstallError = "请包含应用本体，并确认所选应用数据可以移走。"
            return
        }
        uninstalling = true
        uninstallError = nil
        uninstallProgress = 0
        uninstallTotal = selected.count
        defer { uninstalling = false }
        // Graceful termination only. A save dialog or refusal stops the uninstall.
        for running in Self.runningInstances(of: plan.app) where
            running.bundleURL?.path == plan.app.url.path
                || running.bundleURL?.path.hasPrefix(plan.app.url.path + "/") == true
                || running.executableURL?.path.hasPrefix(plan.app.url.path + "/") == true {
            _ = running.terminate()
        }
        let hasSelectedAgent = plan.items.contains { $0.kind == .agent && selected.contains($0.id) }
        func waitingInstances() -> [NSRunningApplication] {
            let instances = Self.runningInstances(of: plan.app)
            // KeepAlive helpers are stopped by launchctl after the main app exits.
            return hasSelectedAgent ? instances.filter {
                $0.bundleIdentifier == plan.app.bundleID || $0.bundleURL?.path == plan.app.url.path
            } : instances
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while !waitingInstances().isEmpty && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard waitingInstances().isEmpty else {
            uninstallError = "应用或内置辅助进程仍在运行。请完成保存并退出，然后重试。未移动任何文件。"
            return
        }
        uninstallResult = await Task.detached(priority: .userInitiated) {
            await AppUninstaller.perform(plan: plan, selected: selected, dataConsent: dataConsent,
                isRunning: { await MainActor.run { !Self.runningInstances(of: plan.app).isEmpty } },
                onProgress: { completed, total in
                    self.uninstallProgress = completed
                    self.uninstallTotal = total
                })
        }.value
        // Invalidate the inventory and associated-file cache, while keeping the outcome.
        refresh()
    }

    init() {}

#if DEBUG
    struct Snapshot {
        var apps: [ScannedApp] = []
        var scanning = false
        var sizedCount = 0
        var measuring = false
        var generation = 0
        var hasScanned = true
        var stopped = false
        var uninstallPlan: UninstallPlan?
        var uninstallResult: UninstallResult?
        var uninstalling = false
    }

    convenience init(snapshot: Snapshot) {
        self.init()
        precondition(snapshot.apps.allSatisfy {
            $0.url.standardizedFileURL.path.hasPrefix("/QiliPreview/")
                && URL(fileURLWithPath: $0.id).standardizedFileURL.path.hasPrefix("/QiliPreview/")
        }, "Snapshot fixtures must use synthetic /QiliPreview paths")
        precondition(snapshot.uninstallPlan?.items.allSatisfy { $0.id.hasPrefix("/QiliPreview/") } ?? true)
        precondition(snapshot.uninstallPlan?.app.id.hasPrefix("/QiliPreview/") ?? true)
        precondition(snapshot.uninstallResult?.outcomes.allSatisfy { $0.id.hasPrefix("/QiliPreview/") } ?? true)
        precondition(snapshot.uninstallResult?.remaining.allSatisfy { $0.hasPrefix("/QiliPreview/") } ?? true)
        allowsLiveOperations = false
        uninstallPlan = snapshot.uninstallPlan
        uninstallResult = snapshot.uninstallResult
        uninstalling = snapshot.uninstalling
        apps = snapshot.apps
        scanning = snapshot.scanning
        sizedCount = snapshot.sizedCount
        measuring = snapshot.measuring
        generation = snapshot.generation
        hasScanned = snapshot.hasScanned
        stopped = snapshot.stopped
    }
#endif

    func refresh() {
        guard allowsLiveOperations else { return }
        sizeTask?.cancel()
        generation += 1
        stopped = false
        let revision = generation
        scanning = true
        measuring = true
        sizedCount = 0
        sizeTask = Task { [weak self] in
            let discovery = Task.detached(priority: .userInitiated) { Self.discoverApps() }
            let basic = await withTaskCancellationHandler { await discovery.value } onCancel: { discovery.cancel() }
            guard let self, !Task.isCancelled, self.generation == revision else { return }
            self.apps = basic
            self.hasScanned = true
            self.scanning = false
            await self.measureSizes(basic, revision: revision)
            guard !Task.isCancelled, self.generation == revision else { return }
            self.measuring = false
        }
    }

    func stopMeasuring() {
        guard allowsLiveOperations else { return }
        sizeTask?.cancel()
        stopped = true
        scanning = false
        measuring = false
    }

    func loadIcon(for id: String) {
        guard allowsLiveOperations else { return }
        guard let index = apps.firstIndex(where: { $0.id == id }), apps[index].icon == nil else { return }
        apps[index].icon = NSWorkspace.shared.icon(forFile: apps[index].url.path)
    }

    /// 只做轻量枚举:名称、版本、Bundle ID、修改时间。图标在 MainActor 上补。
    nonisolated private static func discoverApps() -> [ScannedApp] {
        var roots: [URL] = [URL(fileURLWithPath: "/Applications")]
        let userApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        if FileManager.default.fileExists(atPath: userApps.path) {
            roots.append(userApps)
        }

        var result: [ScannedApp] = []
        var seen = Set<String>()
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]

        for root in roots {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )) ?? []
            for entry in entries where entry.pathExtension == "app" {
                if Task.isCancelled { return result }
                guard !seen.contains(entry.path) else { continue }
                seen.insert(entry.path)

                let bundle = Bundle(url: entry)
                let info = bundle?.infoDictionary
                let displayName = (info?["CFBundleDisplayName"] as? String)
                    ?? (info?["CFBundleName"] as? String)
                    ?? entry.deletingPathExtension().lastPathComponent
                let version = (info?["CFBundleShortVersionString"] as? String) ?? "—"
                let bundleID = bundle?.bundleIdentifier ?? ""
                let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                result.append(ScannedApp(
                    id: entry.path,
                    url: entry,
                    name: displayName,
                    version: version,
                    bundleID: bundleID,
                    modified: Self.relativeDate(modified),
                    sizeBytes: nil,
                    icon: nil
                ))
            }
        }
        return result.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// 单一父任务管理发现与测量；按路径回填，旧扫描不会污染新列表。
    private func measureSizes(_ snapshot: [ScannedApp], revision: Int) async {
        await withTaskGroup(of: (String, FileSizer.Measurement).self) { group in
            var next = 0
            func enqueue() {
                let item = snapshot[next]
                group.addTask { (item.id, FileSizer.measure(item.url)) }
                next += 1
            }
            while next < min(4, snapshot.count) { enqueue() }
            for await (id, size) in group {
                guard !Task.isCancelled, generation == revision else { group.cancelAll(); return }
                if let index = apps.firstIndex(where: { $0.id == id }) {
                    apps[index].sizeBytes = size.bytes
                    apps[index].partial = size.partial
                    sizedCount += 1
                }
                if next < snapshot.count { enqueue() }
            }
        }
    }

    nonisolated static func directorySize(_ url: URL) -> Int64 { FileSizer.measure(url).bytes }

    /// 按 Bundle ID / 名称找出真实存在的关联文件。
    nonisolated static func leftovers(for app: ScannedApp) -> [LeftoverItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates: [(String, URL)] = [
            ("App", app.url),
        ]
        if !app.bundleID.isEmpty {
            candidates += [
                ("偏好设置", home.appendingPathComponent("Library/Preferences/\(app.bundleID).plist")),
                ("应用支持", home.appendingPathComponent("Library/Application Support/\(app.bundleID)")),
                ("缓存", home.appendingPathComponent("Library/Caches/\(app.bundleID)")),
                ("窗口状态", home.appendingPathComponent("Library/Saved Application State/\(app.bundleID).savedState")),
            ]
        }
        candidates.append(("应用支持", home.appendingPathComponent("Library/Application Support/\(app.name)")))

        var items: [LeftoverItem] = []
        var seen = Set<String>()
        for (kind, url) in candidates where !seen.contains(url.path) {
            if Task.isCancelled { break }
            seen.insert(url.path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let size: FileSizer.Measurement
            if url == app.url, let bytes = app.sizeBytes {
                size = FileSizer.Measurement(bytes: bytes, partial: app.partial)
            } else { size = FileSizer.measure(url) }
            items.append(LeftoverItem(id: url.path, kind: kind, path: Self.tildePath(url), sizeBytes: size.bytes, partial: size.partial))
        }
        return items
    }

    nonisolated static func tildePath(_ url: URL) -> String {
        url.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path,
            with: "~"
        )
    }

    nonisolated static func relativeDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    nonisolated static func formatBytes(_ bytes: Int64?) -> String {
        guard let bytes else { return "测量中…" }
        if bytes == 0 { return "0 B" }
        if bytes < 1024 { return "\(bytes) B" }
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return "\(max(1, bytes / 1024)) KB"
    }
}
