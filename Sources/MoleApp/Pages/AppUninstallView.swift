import AppKit
import SwiftUI

/// A fixed review/action bar keeps the final action outside the scrollable paths.
struct AppUninstallView: View {
    @ObservedObject var store: AppsStore
    let app: ScannedApp
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var dataConsent = false
    @State private var showConfirmation = false

    private var selectedItems: [UninstallItem] {
        store.uninstallPlan?.items.filter { selected.contains($0.id) } ?? []
    }
    private var needsDataConsent: Bool { selectedItems.contains { $0.requiresDataConsent } }
    private var canUninstall: Bool {
        store.allowsLiveOperations && !store.uninstallScanning && !store.uninstalling
            && store.uninstallPlan?.blockedReason == nil && selected.contains(app.url.path)
            && (!needsDataConsent || dataConsent) && store.uninstallResult == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.uninstallResult == nil ? "卸载 \(app.name)" : "\(app.name) · 处理结果")
                        .font(Theme.display)
                    Text("核对路径与数据，再决定哪些一起移走。")
                        .font(.system(size: 13)).foregroundStyle(Theme.dim2)
                }
                Spacer()
                Button(store.uninstallResult == nil ? "取消" : "完成") { dismiss() }
                    .buttonStyle(WorkspaceButtonStyle(kind: .quiet))
                    .keyboardShortcut(.cancelAction)
                    .disabled(store.uninstalling)
            }
            Divider()
            if store.uninstallScanning {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("正在检查关联文件与后台项…").font(.system(size: 13)).foregroundStyle(Theme.dim2)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let result = store.uninstallResult {
                outcome(result)
            } else if let plan = store.uninstallPlan {
                if let reason = plan.blockedReason {
                    Notice(text: reason, symbol: "lock.shield")
                    Spacer()
                } else {
                    review(plan)
                }
            }
            if let error = store.uninstallError {
                Notice(text: error, symbol: "exclamationmark.circle", tone: Theme.danger)
            }
            if store.uninstalling {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: Double(store.uninstallProgress), total: Double(max(1, store.uninstallTotal)))
                    Text(store.uninstallProgress == 0 ? "正在退出应用、复核路径并处理后台项…" : "已处理 \(store.uninstallProgress) / \(store.uninstallTotal) 项")
                        .font(.system(size: 12)).foregroundStyle(Theme.dim2)
                }
            }
            if store.uninstallResult == nil && store.uninstallPlan?.blockedReason == nil && !store.uninstallScanning {
                Divider()
                if needsDataConsent {
                    Toggle("我确认所选应用数据可以移到废纸篓，可能包括文稿、账号和设置", isOn: $dataConsent)
                        .font(.system(size: 12)).disabled(store.uninstalling)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("已选 \(selectedItems.count) 项 · \(selectedItems.contains(where: \.partial) ? "≥ " : "")\(AppsStore.formatBytes(selectedItems.reduce(0) { $0 + $1.sizeBytes }))")
                            .font(.system(size: 13, weight: .medium))
                        Text("废纸篓清空前仍占磁盘空间。不会自动清空。")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.dim2)
                    }
                    Spacer()
                    Button("卸载并移到废纸篓…") { showConfirmation = true }
                        .buttonStyle(WorkspaceButtonStyle()).disabled(!canUninstall)
                }
            }
        }
        .padding(22)
        .frame(width: 760, height: 660)
        .foregroundStyle(Theme.star)
        .background(Theme.canvas)
        .interactiveDismissDisabled(store.uninstalling)
        .onAppear { selected = store.uninstallPlan?.defaultSelection ?? [] }
        .onChange(of: store.uninstallScanning) { _, scanning in
            if !scanning { selected = store.uninstallPlan?.defaultSelection ?? []; dataConsent = false }
        }
        .onDisappear { store.cancelUninstallScan() }
        .alert("退出并卸载 \(app.name)？", isPresented: $showConfirmation) {
            Button("取消", role: .cancel) {}
            Button("退出并移到废纸篓", role: .destructive) {
                guard canUninstall else { return }
                let ids = selected
                let consent = dataConsent
                Task { await store.uninstall(selected: ids, dataConsent: consent) }
            }
        } message: {
            Text("将尝试正常退出应用，停止选中的用户后台项，并把应用和所选关联文件共 \(selectedItems.count) 项移到废纸篓。请先保存工作；应用未退出时会停止卸载。")
        }
    }

    private func review(_ plan: UninstallPlan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(plan.items) { item in
                    RowBox(selected: selected.contains(item.id)) {
                        HStack(alignment: .top, spacing: 10) {
                            CheckView(on: selected.contains(item.id), label: "\(item.title)：\(item.id)\(item.readOnly ? "，只读" : "")") {
                                guard !store.uninstalling, !item.readOnly, item.kind != .application else { return }
                                if !selected.insert(item.id).inserted { selected.remove(item.id) }
                                dataConsent = false
                            }
                            .disabled(item.readOnly || item.kind == .application || store.uninstalling)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(item.title + (item.readOnly ? " · 只读" : "")).font(.system(size: 13, weight: .medium))
                                    Spacer()
                                    Text((item.partial ? "≥ " : "") + AppsStore.formatBytes(item.sizeBytes)).font(Theme.monoSmall)
                                }
                                Text(item.id).font(Theme.monoSmall).foregroundStyle(Theme.dim2)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                Text(item.note).font(.system(size: 11.5)).foregroundStyle(Theme.dim2)
                            }
                            Button { reveal(item.url) } label: { Image(systemName: "arrow.up.forward.square") }
                                .buttonStyle(.plain).help("在访达中显示").accessibilityLabel("在访达中显示\(item.title)")
                                .disabled(store.uninstalling)
                        }
                    }
                }
                ForEach(plan.notes, id: \.self) { note in Notice(text: note) }
            }.padding(.trailing, 5)
        }.disabled(store.uninstalling)
    }

    private func outcome(_ result: UninstallResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Notice(text: "\(result.title)。移动 \(result.moved) 项，失败 \(result.failed) 项。",
                       symbol: result.failed > 0 ? "exclamationmark.circle" : "checkmark.circle",
                       tone: result.failed > 0 ? Theme.warm : Theme.accent)
                ForEach(result.outcomes) { item in
                    RowBox {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(item.title)：\(item.detail)").font(.system(size: 12.5))
                                .foregroundStyle(item.status == .failed ? Theme.danger : Theme.star)
                            Text(item.id).font(Theme.monoSmall).foregroundStyle(Theme.dim2).textSelection(.enabled)
                            if item.status != .moved {
                                Button("在访达中显示") { reveal(URL(fileURLWithPath: item.id)) }
                                    .buttonStyle(WorkspaceButtonStyle(kind: .quiet))
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Notice(text: "复查后，已知路径仍存在 \(result.remaining.count) 项。未选择与只读项目会保留；其他自定义位置未扫描。废纸篓仍占用空间，恢复文件不会自动恢复后台项的运行状态。")
            }.padding(.trailing, 5)
        }
    }

    private func reveal(_ url: URL) {
        guard store.allowsLiveOperations else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
