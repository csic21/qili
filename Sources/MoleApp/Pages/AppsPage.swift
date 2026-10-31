import AppKit
import SwiftUI

struct AppsPage: View {
    private enum Sub: String, CaseIterable { case inventory = "应用清单", update = "更新", login = "启动项" }

    @ObservedObject var store: AppsStore
    @ObservedObject var loginStore: LoginItemsStore
    @ObservedObject var updateStore: UpdateStore
    @State private var sub: Sub = .inventory
    private enum Sort: String, CaseIterable { case name = "名称", size = "占用大小" }
    @State private var search = ""
    @AppStorage("qili.apps.sort") private var sort: Sort = .name
    @State private var expanded: String?
    @State private var leftoverCache: [String: [LeftoverItem]] = [:]
    @State private var pendingEntry: LoginEntry?
    @State private var showConfirm = false
    @State private var uninstallApp: ScannedApp?

    init(store: AppsStore, loginStore: LoginItemsStore, updateStore: UpdateStore) {
        self.store = store
        self.loginStore = loginStore
        self.updateStore = updateStore
    }

#if DEBUG
    enum PreviewSection { case inventory, updates, login }

    /// Captures render the production page while all three stores stay inert.
    @MainActor
    init(store: AppsStore, loginStore: LoginItemsStore, updateStore: UpdateStore,
         previewSection: PreviewSection) {
        precondition(!store.allowsLiveOperations && !loginStore.allowsLiveOperations
                     && !updateStore.allowsLiveOperations, "Page snapshots require isolated stores")
        self.init(store: store, loginStore: loginStore, updateStore: updateStore)
        let initialSection: Sub
        switch previewSection {
        case .inventory: initialSection = .inventory
        case .updates: initialSection = .update
        case .login: initialSection = .login
        }
        _sub = State(initialValue: initialSection)
    }
#endif

    private var allowsLiveOperations: Bool {
        store.allowsLiveOperations && loginStore.allowsLiveOperations && updateStore.allowsLiveOperations
    }
    // Never persist a fixture's controls to the user's normal sort preference.
    private var activeSort: Sort { allowsLiveOperations ? sort : .name }
    private var sortSelection: Binding<Sort> { allowsLiveOperations ? $sort : .constant(.name) }
    private var apps: [ScannedApp] { store.apps }

    private var visibleApps: [ScannedApp] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = apps.filter { query.isEmpty || $0.name.localizedStandardContains(query) || $0.bundleID.localizedStandardContains(query) }
        return filtered.sorted {
            if activeSort == .size && !store.measuring && !store.scanning && $0.sizeBytes != $1.sizeBytes { return ($0.sizeBytes ?? -1) > ($1.sizeBytes ?? -1) }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            subnav

            switch sub {
            case .inventory: inventoryList
            case .update: updateList
            case .login: loginList
            }
        }
        .task {
            guard allowsLiveOperations else { return }
            if !store.hasScanned && !store.scanning && !store.stopped {
                store.refresh()
            }
        }
        .sheet(item: $uninstallApp) { app in
            AppUninstallView(store: store, app: app)
        }
        .onChange(of: store.generation) { _, _ in leftoverCache = [:]; expanded = nil }
        .onChange(of: store.uninstalling) { _, busy in
            if !busy && store.uninstallResult != nil && allowsLiveOperations { loginStore.scan() }
        }
    }

    private var subnav: some View {
        HStack(spacing: 4) {
            Picker("应用视图", selection: $sub) {
                ForEach(Sub.allCases, id: \.self) { item in Text(item.rawValue).tag(item) }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            .accessibilityLabel("应用管理视图")
            Spacer()
            if store.scanning {
                Text("正在扫描 /Applications…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim3)
            } else {
                Text("\(apps.count) 个应用 · 大小 \(store.sizedCount)/\(apps.count) 已测量")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim3)
            }
            if store.measuring {
                Button("停止测量") {
                    guard allowsLiveOperations else { return }
                    store.stopMeasuring()
                }.buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
            Button("重新扫描") {
                guard allowsLiveOperations else { return }
                store.refresh()
            }
                .buttonStyle(WorkspaceButtonStyle(kind: .quiet))
        }
        .padding(.bottom, 10)
    }

    private var inventoryList: some View {
        LazyVStack(spacing: 2) {
            HStack(spacing: 14) {
                TextField("搜索应用名称或 Bundle ID", text: $search)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 340)
                    .accessibilityLabel("搜索应用")
                Picker("排序", selection: sortSelection) {
                    ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(width: 170).disabled(store.measuring).help(store.measuring ? "测量完成后可按大小排序" : "按名称或占用大小排序")
                Spacer()
                Text("\(visibleApps.count) / \(apps.count) 个应用").font(Theme.monoSmall).foregroundStyle(Theme.dim3)
            }.padding(.bottom, 12)
            if store.scanning && apps.isEmpty {
                scanningPlaceholder
            } else if apps.isEmpty {
                Text(store.stopped ? "扫描已停止，可重新扫描" : "没有在 /Applications 与 ~/Applications 找到应用")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dim2)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
            } else {
                Text("已安装 App \(apps.count) 个 · 大小测量 \(store.sizedCount)/\(apps.count)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.dim2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                    .padding(.bottom, 6)
                Notice(text: "展开应用查看关联文件，选择卸载后可逐项确认并移到废纸篓。", symbol: "info.circle")
                    .padding(.bottom, 10)
            }

            if let result = store.uninstallResult {
                Notice(text: "\(result.appName)：\(result.title)，移动 \(result.moved) 项，失败 \(result.failed) 项。废纸篓未清空。",
                       symbol: result.failed > 0 ? "exclamationmark.circle" : "checkmark.circle")
                    .padding(.bottom, 10)
            }

            // ForEach 直接挂在 LazyVStack 下:滚动时只渲染可见行。
            ForEach(visibleApps) { app in
                RowBox {
                    Button { expanded = expanded == app.id ? nil : app.id } label: {
                    HStack(spacing: 12) {
                        appIcon(app)
                        Text(app.name)
                            .font(.system(size: 13.5))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(app.version) · \(app.modified)")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.dim2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(app.sizeBytes == nil ? (store.measuring ? "测量中…" : "未测量") : (app.partial ? "≥ " : "") + AppsStore.formatBytes(app.sizeBytes))
                            .font(Theme.mono)
                            .foregroundStyle(Theme.dim2)
                        Image(systemName: expanded == app.id ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11)).foregroundStyle(Theme.accent)
                    }
                    .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("\(app.name)，查看关联文件")
                }

                if expanded == app.id {
                    expandPanel(app)
                }
            }

            if !apps.isEmpty && visibleApps.isEmpty {
                ContentUnavailableView.search(text: search).padding(.vertical, 30)
            }
        }
    }

    private func appIcon(_ app: ScannedApp) -> some View {
        Group {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 28, height: 28)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 28, height: 28)
            }
        }
        .task {
            guard allowsLiveOperations else { return }
            store.loadIcon(for: app.id)
        }
    }

    private var scanningPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("正在读取 /Applications 与 ~/Applications …")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.dim2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }

    private func expandPanel(_ app: ScannedApp) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("关联文件")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim2)
                Spacer()
                Button("在访达中显示") {
                    guard allowsLiveOperations else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([app.url])
                }
                .buttonStyle(WorkspaceButtonStyle(kind: .quiet))
                Button("卸载…") {
                    guard allowsLiveOperations else { return }
                    store.prepareUninstall(app)
                    uninstallApp = app
                }
                .buttonStyle(WorkspaceButtonStyle())
                .disabled(store.uninstalling || updateStore.busyID != nil || !loginStore.busyIDs.isEmpty)
                .accessibilityLabel("卸载\(app.name)，先查看文件清单")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if let items = leftoverCache[app.id] {
                if items.isEmpty {
                    Text("没有找到关联残留文件")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.dim3)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                } else {
                    ForEach(items) { item in
                        RowBox {
                            HStack(spacing: 12) {
                                Image(systemName: "doc").foregroundStyle(Theme.dim3)
                                Text(item.kind)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Theme.star.opacity(0.72))
                                    .frame(width: 90, alignment: .leading)
                                Text(item.path)
                                    .font(Theme.monoSmall)
                                    .foregroundStyle(Theme.dim3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text((item.partial ? "≥ " : "") + AppsStore.formatBytes(item.sizeBytes))
                                    .font(Theme.mono)
                                    .foregroundStyle(Theme.dim2)
                            }
                        }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在检查关联文件…")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.dim3)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .padding(6)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .task(id: app.id) { await loadLeftoversIfNeeded(app) }
    }

    private func loadLeftoversIfNeeded(_ app: ScannedApp) async {
        guard allowsLiveOperations else { return }
        guard leftoverCache[app.id] == nil else { return }
        let task = Task.detached(priority: .userInitiated) { AppsStore.leftovers(for: app) }
        let items = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled else { return }
        leftoverCache[app.id] = items
    }

    // ---------------------------------------------------------- 更新检查与启动项管理

    private var updateList: some View {
        LazyVStack(spacing: 2) {
            Text("检查来源:Sparkle 应用与 Homebrew;App Store 更新请在 App Store 中查看")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.dim2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
                .padding(.bottom, 6)

            if updateStore.checking {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(updateStore.progress.isEmpty ? "正在检查更新…" : updateStore.progress)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.dim2)
                    }
                    Button("停止并查看已完成结果") {
                        guard allowsLiveOperations else { return }
                        updateStore.stopChecking()
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 12))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else if updateStore.updates.isEmpty {
                Text(updateStore.emptyCheckMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dim2)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 50)
            }

            if !updateStore.checking && !updateStore.checkWarnings.isEmpty {
                DisclosureGroup("\(updateStore.checkWarnings.count) 个来源未完成检查") {
                    ForEach(Array(updateStore.checkWarnings.enumerated()), id: \.offset) { _, warning in
                        Text(warning)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.warm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }

            ForEach(updateStore.checking ? [] : updateStore.updates) { info in
                RowBox {
                    HStack(spacing: 12) {
                        Text(info.name)
                            .font(.system(size: 13.5))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(info.source)
                            .font(.system(size: 10.5))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(Theme.dim3)
                        Text("\(info.from) → \(info.to)")
                            .font(Theme.monoSmall)
                            .foregroundStyle(Theme.dim2)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let message = updateStore.messages[info.id] {
                            Text(message)
                                .font(.system(size: 11.5))
                                .foregroundStyle(
                                    message.contains("未完成") || message.contains("失败") ? Theme.danger : Theme.dim3
                                )
                                .lineLimit(1)
                                .frame(width: 210, alignment: .trailing)
                                .help(message)
                        }
                        Button {
                            guard allowsLiveOperations else { return }
                            Task { await updateStore.perform(info) }
                        } label: {
                            Text(buttonTitle(for: info))
                                .font(.system(size: 12))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 6))
                                .foregroundStyle(Color(hex: 0x17181B))
                        }
                        .buttonStyle(.plain)
                        .disabled(updateStore.busyID != nil)
                        .opacity(updateStore.busyID == nil ? 1 : 0.5)
                    }
                    if let log = updateStore.commandLogs[info.id], !log.isEmpty {
                        DisclosureGroup("执行记录") {
                            Text(log)
                                .font(Theme.monoSmall)
                                .foregroundStyle(Theme.dim2)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 11.5))
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    }
                }
            }

            if !updateStore.checking && updateStore.checkWasCancelled && !updateStore.updates.isEmpty {
                Text(updateStore.emptyCheckMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
            }

            FootBar(note: updateStore.lastCheckedText()) {
                PillButton(title: "重新检查", disabled: updateStore.checking || updateStore.busyID != nil) {
                    Task { await runCheck(force: true) }
                }
            }
        }
        .task {
            await runCheck(force: false)
        }
    }

    private func runCheck(force: Bool) async {
        guard allowsLiveOperations else { return }
        if store.apps.isEmpty {
            if !store.scanning { store.refresh() }
            var waited = 0
            while store.scanning && waited < 100 {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 300_000_000)
                waited += 1
            }
        }
        await updateStore.check(apps: store.apps, force: force)
    }

    private func buttonTitle(for info: UpdateInfo) -> String {
        switch info.action {
        case .sparkle: "打开更新"
        case .brew: "更新"
        }
    }

    private var loginList: some View {
        LazyVStack(spacing: 2) {
            Text("来自 ~/Library 与 /Library 的 LaunchAgents;macOS 设置的登录项(BTM)暂不读取")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.dim2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
                .padding(.bottom, 6)

            if loginStore.scanning && loginStore.entries.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取登录项…")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.dim2)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            }

            if let error = loginStore.stateError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                    .padding(.bottom, 4)
            }

            ForEach(loginStore.scanning && loginStore.entries.isEmpty ? [] : loginStore.entries) { entry in
                RowBox {
                    HStack(spacing: 12) {
                        CheckView(on: !entry.disabled, label: entry.scope == .system ? "系统启动项\(entry.label)，只读" : "\(entry.disabled ? "启用" : "停用")\(entry.label)") {
                            guard allowsLiveOperations else { return }
                            guard entry.scope == .user else { return }
                            pendingEntry = entry
                            showConfirm = true
                        }
                        .disabled(entry.scope != .user || !entry.stateKnown || loginStore.scanning
                                  || !loginStore.busyIDs.isEmpty)
                        .help(entry.scope == .user ? "变更前会请求确认" : "系统启动项只读")

                        HStack(spacing: 6) {
                            Text(entry.label)
                                .font(.system(size: 13))
                                .lineLimit(1)
                            Text(entry.scope == .user ? "用户" : "系统")
                                .font(.system(size: 10.5))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                                .foregroundStyle(Theme.dim3)
                        }
                        .frame(width: 330, alignment: .leading)

                        Text(entry.program.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "—")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.dim2)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let error = loginStore.errors[entry.id] {
                            Text(error)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.danger)
                                .lineLimit(1)
                                .frame(width: 200, alignment: .trailing)
                        }

                        Text(loginStore.busyIDs.contains(entry.id) ? "正在应用…" : entry.stateText)
                            .font(Theme.monoSmall)
                            .foregroundStyle(Theme.dim2)
                            .frame(width: 130, alignment: .trailing)
                    }
                }
            }

            FootBar(note: "用户级 \(loginStore.entries.filter { $0.scope == .user && !$0.disabled }.count) 项启用 · 状态列区分已加载与真实运行") {
                PillButton(title: "重新扫描", disabled: loginStore.scanning || !loginStore.busyIDs.isEmpty) {
                    guard allowsLiveOperations else { return }
                    loginStore.scan()
                }
            }
        }
        .task {
            guard allowsLiveOperations else { return }
            if loginStore.entries.isEmpty && !loginStore.scanning {
                loginStore.scan()
            }
        }
        .alert("登录项", isPresented: $showConfirm) {
            Button("取消", role: .cancel) { pendingEntry = nil }
            if let entry = pendingEntry {
                Button(entry.disabled ? "启用" : "停用", role: entry.disabled ? nil : .destructive) {
                    guard allowsLiveOperations else { return }
                    Task {
                        await loginStore.setEnabled(entry, enabled: entry.disabled)
                        pendingEntry = nil
                    }
                }
            }
        } message: {
            if let entry = pendingEntry {
                Text(entry.disabled
                    ? "启用 \(entry.label) 会立即加载,并在之后每次登录自动运行。"
                    : "停用 \(entry.label) 会立即停止它,之后每次登录也不再运行;随时可以再启用。")
            }
        }
    }
}
