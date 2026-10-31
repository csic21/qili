import AppKit
import Darwin
import Foundation

/// Uninstall only exact, reviewed paths. No recursive name search or permanent delete.
struct UninstallEnvironment {
    let home: URL
    let applicationRoots: [URL]
    let systemLibrary: URL
    let currentApp: URL

    static var live: Self {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Self(home: home, applicationRoots: [URL(fileURLWithPath: "/Applications"),
                    home.appendingPathComponent("Applications")],
                    systemLibrary: URL(fileURLWithPath: "/Library"), currentApp: Bundle.main.bundleURL)
    }
}

struct UninstallIdentity: Equatable {
    let device: Int32
    let inode: UInt64
    let birthSeconds: Int
    let birthNanos: Int

    static func read(_ url: URL) -> Self? {
        // Reject symlinks anywhere in the path, including swapped parent directories.
        guard url.standardizedFileURL.path == url.path,
              url.resolvingSymlinksInPath().path == url.path else { return nil }
        var value = stat()
        guard lstat(url.path, &value) == 0,
              value.st_mode & S_IFMT != S_IFLNK else { return nil }
        return Self(device: value.st_dev, inode: value.st_ino,
                    birthSeconds: value.st_birthtimespec.tv_sec, birthNanos: value.st_birthtimespec.tv_nsec)
    }
}

struct UninstallItem: Identifiable {
    enum Kind { case application, cache, preferences, state, support, logs, container, agent, systemAgent }
    let url: URL
    let kind: Kind
    let title: String
    let note: String
    let defaultSelected: Bool
    let requiresDataConsent: Bool
    let readOnly: Bool
    let identity: UninstallIdentity
    let sizeBytes: Int64
    let partial: Bool
    var id: String { url.path }
}

struct UninstallPlan {
    let app: ScannedApp
    let items: [UninstallItem]
    let notes: [String]
    let blockedReason: String?
    var defaultSelection: Set<String> { Set(items.filter { $0.defaultSelected && !$0.readOnly }.map(\.id)) }
}

struct UninstallOutcome: Identifiable {
    enum Status { case moved, failed, retained }
    let id: String
    let title: String
    let status: Status
    let detail: String
}

struct UninstallResult {
    let appName: String
    let outcomes: [UninstallOutcome]
    let remaining: [String]
    var moved: Int { outcomes.filter { $0.status == .moved }.count }
    var failed: Int { outcomes.filter { $0.status == .failed }.count }
    var title: String {
        if failed > 0 { return moved > 0 ? "部分项目未能移到废纸篓" : "卸载未完成" }
        return moved > 0 ? "所选项目已移到废纸篓" : "未移动任何项目"
    }
}

enum AppUninstaller {
    private static let fm = FileManager.default

    static func isBundleID(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        } }
    }

    private static func isName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.utf8.contains(0)
    }

    static func blockedReason(for app: ScannedApp, environment: UninstallEnvironment) -> String? {
        let url = app.url.standardizedFileURL
        guard environment.applicationRoots.contains(where: { $0.standardizedFileURL.path == url.deletingLastPathComponent().path }),
              url.pathExtension == "app", app.id == url.path,
              UninstallIdentity.read(url) != nil,
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return "应用路径已变化、不可访问或不在允许的应用目录中。请重新扫描。"
        }
        guard url.path != environment.currentApp.standardizedFileURL.path,
              app.bundleID != "com.csic21.moleapp", !app.bundleID.hasPrefix("com.apple.") else {
            return "不支持卸载栖理自身或 Apple 系统应用。"
        }
        guard let bundle = Bundle(url: url), bundle.bundleIdentifier == app.bundleID,
              isBundleID(app.bundleID) else { return "无法确认应用身份，暂不支持卸载。" }
        return nil
    }

    static func scan(app: ScannedApp, environment: UninstallEnvironment = .live, measureSizes: Bool = true) -> UninstallPlan {
        if let reason = blockedReason(for: app, environment: environment) {
            return UninstallPlan(app: app, items: [], notes: [], blockedReason: reason)
        }
        var peers: [URL] = []
        var catalogIncomplete = false
        for root in environment.applicationRoots where fm.fileExists(atPath: root.path) {
            do { peers += try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) }
            catch { catalogIncomplete = true }
        }
        peers = peers.filter { $0.pathExtension == "app" && $0.standardizedFileURL.path != app.url.standardizedFileURL.path }
        if peers.contains(where: { Bundle(url: $0)?.bundleIdentifier == nil }) { catalogIncomplete = true }
        let sharedID = catalogIncomplete || peers.contains { Bundle(url: $0)?.bundleIdentifier == app.bundleID }
        let sharedName = peers.contains {
            let info = Bundle(url: $0)?.infoDictionary
            return ((info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String)
                    ?? $0.deletingPathExtension().lastPathComponent) == app.name
        }
        var items: [UninstallItem] = []
        var notes = ["仅扫描预设位置；共享群组容器、钥匙串、云端数据和其他自定义位置不自动清理。",
                     "应用支持与沙盒容器可能包含文稿、账号和设置，默认保留。带驱动或系统扩展的软件请优先使用官方卸载器。"]
        if catalogIncomplete { notes.append("无法完整核对其他已安装应用，关联文件暂时只读。请检查权限后重新扫描。") }
        else if sharedID { notes.append("检测到相同应用标识的其他副本，关联文件保留为只读，避免影响其他副本。") }
        var seen = Set<String>()
        func add(_ url: URL, _ kind: UninstallItem.Kind, _ title: String, _ note: String,
                 selected: Bool = false, data: Bool = false, readOnly: Bool = false) {
            guard !Task.isCancelled, seen.insert(url.path).inserted else { return }
            guard let identity = UninstallIdentity.read(url) else {
                if fm.fileExists(atPath: url.path) { notes.append("未纳入不可安全访问的路径：\(url.path)") }
                return
            }
            let size = measureSizes ? FileSizer.measure(url) : FileSizer.Measurement(bytes: 0, partial: false)
            items.append(UninstallItem(url: url, kind: kind, title: title, note: note,
                defaultSelected: selected && !readOnly, requiresDataConsent: data, readOnly: readOnly,
                identity: identity, sizeBytes: size.bytes, partial: size.partial))
        }
        add(app.url, .application, "应用本体", "卸载时必须包含应用本体", selected: true)
        let library = environment.home.appendingPathComponent("Library")
        let id = app.bundleID
        let sharedNote = sharedID ? "其他应用副本仍在使用，保留" : "按应用标识精确匹配"
        add(library.appendingPathComponent("Caches/\(id)"), .cache, "缓存", sharedNote, selected: true, readOnly: sharedID)
        add(library.appendingPathComponent("Preferences/\(id).plist"), .preferences, "偏好设置", sharedNote, selected: true, readOnly: sharedID)
        add(library.appendingPathComponent("Saved Application State/\(id).savedState"), .state, "窗口状态", sharedNote, selected: true, readOnly: sharedID)
        add(library.appendingPathComponent("Application Support/\(id)"), .support, "应用数据", "可能包含文稿和账号数据；\(sharedNote)", data: true, readOnly: sharedID)
        add(library.appendingPathComponent("Containers/\(id)"), .container, "沙盒数据", "可能包含文稿和账号数据；\(sharedNote)", data: true, readOnly: sharedID)
        add(library.appendingPathComponent("Logs/\(id)"), .logs, "日志", sharedNote, selected: true, readOnly: sharedID)
        if isName(app.name) && app.name != id {
            add(library.appendingPathComponent("Application Support/\(app.name)"), .support,
                "疑似应用数据", "仅名称相同，可能与其他应用共享；请核对内容", data: true, readOnly: sharedID || sharedName)
            add(library.appendingPathComponent("Logs/\(app.name)"), .logs,
                "疑似日志", "仅名称相同，请核对归属", data: true, readOnly: sharedID || sharedName)
        }
        for (directory, system) in [(library.appendingPathComponent("LaunchAgents"), false),
                                    (environment.systemLibrary.appendingPathComponent("LaunchAgents"), true),
                                    (environment.systemLibrary.appendingPathComponent("LaunchDaemons"), true)] {
            do {
                let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                for url in files.map(\.standardizedFileURL) where url.pathExtension == "plist" && agentLabel(at: url, app: app) != nil {
                    add(url, system ? .systemAgent : .agent, system ? "系统后台项" : "用户后台项",
                        system ? "只读；请使用官方卸载器处理" : "程序路径位于此应用内；移动前停止后台项",
                        selected: !system, readOnly: system)
                }
            } catch {
                if fm.fileExists(atPath: directory.path) { notes.append("无法完整读取后台项目录：\(directory.path)") }
            }
        }
        return UninstallPlan(app: app, items: items, notes: notes, blockedReason: nil)
    }

    /// The executable must be inside this exact app, not a similarly named sibling.
    static func agentLabel(at url: URL, app: ScannedApp) -> String? {
        guard UninstallIdentity.read(url) != nil,
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String, isBundleID(label),
              let executable = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first,
              executable.hasPrefix("/"),
              URL(fileURLWithPath: executable).standardizedFileURL.path.hasPrefix(app.url.path + "/") else { return nil }
        return label
    }

    static func stopAgent(_ item: UninstallItem, app: ScannedApp) async throws {
        guard let label = agentLabel(at: item.url, app: app) else { throw UninstallError("后台项归属已变化，请重新扫描") }
        let list = await CommandRunner.run("/bin/launchctl", ["list"], timeout: 15)
        guard list.code == 0, !list.truncated else { throw UninstallError("无法确认后台项状态：\(list.failureMessage)") }
        guard LoginItemsStore.parseLoaded(list.output)[label] != nil else { return }
        guard UninstallIdentity.read(item.url) == item.identity,
              agentLabel(at: item.url, app: app) == label else { throw UninstallError("后台项在状态检查后发生变化") }
        let result = await CommandRunner.run("/bin/launchctl", ["bootout", "gui/\(getuid())", item.id], timeout: 15)
        guard result.code == 0 else { throw UninstallError("无法停止后台项：\(result.failureMessage)") }
    }

    struct UninstallError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func perform(plan: UninstallPlan, selected: Set<String>, dataConsent: Bool = false, environment: UninstallEnvironment = .live,
                        isRunning: () async -> Bool,
                        trash: (URL) throws -> Void = { try fm.trashItem(at: $0, resultingItemURL: nil) },
                        stopAgent: (UninstallItem, ScannedApp) async throws -> Void = AppUninstaller.stopAgent,
                        onProgress: @MainActor (Int, Int) -> Void = { _, _ in }) async -> UninstallResult {
        let targets = plan.items.filter { selected.contains($0.id) }
        var outcomes: [UninstallOutcome] = []
        func failure(_ message: String) -> UninstallResult {
            UninstallResult(appName: plan.app.name,
                outcomes: targets.isEmpty
                    ? [UninstallOutcome(id: plan.app.id, title: "应用本体", status: .failed, detail: message)]
                    : targets.map { UninstallOutcome(id: $0.id, title: $0.title, status: .failed, detail: message) },
                remaining: plan.items.filter { fm.fileExists(atPath: $0.id) }.map(\.id))
        }
        guard plan.blockedReason == nil, !targets.isEmpty,
              targets.contains(where: { $0.kind == .application }),
              targets.count == selected.count, targets.allSatisfy({ !$0.readOnly && (!$0.requiresDataConsent || dataConsent) }) else {
            return failure("选择无效，请重新扫描并包含应用本体")
        }
        let fresh = scan(app: plan.app, environment: environment, measureSizes: false)
        guard fresh.blockedReason == nil else { return failure(fresh.blockedReason!) }
        func valid(_ item: UninstallItem) -> Bool {
            fresh.items.contains { $0.id == item.id && !$0.readOnly && $0.kind == item.kind && $0.identity == item.identity }
                && UninstallIdentity.read(item.url) == item.identity
                && (item.kind != .agent || agentLabel(at: item.url, app: plan.app) != nil)
        }
        guard targets.allSatisfy(valid) else { return failure("文件或归属在扫描后发生变化，请重新扫描；未移动任何项目") }
        let agents = targets.filter { $0.kind == .agent }
        if agents.isEmpty {
            guard !(await isRunning()) else { return failure("应用仍在运行，请退出后重试；未移动任何项目") }
        }
        // Stop selected agents before moving anything. Never persist launchctl disable overrides.
        do {
            for item in agents {
                guard valid(item) else { throw UninstallError("后台项路径已变化") }
                try await stopAgent(item, plan.app)
            }
        } catch { return failure("\(error.localizedDescription)；未移动文件，已停止的后台项不会自动重启") }
        if !agents.isEmpty {
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while await isRunning(), ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        guard !(await isRunning()) else { return failure("应用或辅助进程仍在运行；未移动文件，已停止的后台项不会自动重启") }
        // Move the app first. If it cannot be moved, preserve all its data.
        let ordered = targets.sorted { ($0.kind == .application ? 0 : 1) < ($1.kind == .application ? 0 : 1) }
        var appMoved = false
        for item in ordered {
            let message: String?
            if await isRunning() { message = "应用重新运行，已停止后续移动" }
            else if !valid(item) { message = "路径或文件身份已变化，请重新扫描" }
            else if item.kind != .application && !appMoved { message = "应用本体未移动，已保留关联文件" }
            else { message = nil }
            if let message {
                outcomes.append(UninstallOutcome(id: item.id, title: item.title, status: .failed, detail: message))
            } else {
                do {
                    try trash(item.url)
                    appMoved = appMoved || item.kind == .application
                    outcomes.append(UninstallOutcome(id: item.id, title: item.title, status: .moved, detail: "已移到废纸篓"))
                } catch {
                    outcomes.append(UninstallOutcome(id: item.id, title: item.title, status: .failed, detail: error.localizedDescription))
                }
            }
            await onProgress(outcomes.count, targets.count)
        }
        for item in plan.items where !selected.contains(item.id) {
            outcomes.append(UninstallOutcome(id: item.id, title: item.title, status: .retained,
                detail: item.readOnly ? "只读项目，已保留" : "未选择，已保留"))
        }
        // Recheck known paths, including newly created files at the same path.
        let remaining = plan.items.filter { fm.fileExists(atPath: $0.id) }.map(\.id)
        return UninstallResult(appName: plan.app.name, outcomes: outcomes, remaining: remaining)
    }
}
