import AppKit
import BarFoldProtocol
import SwiftUI

/// Drives the menu bar page: one scan at a time, one move at a time, and a
/// refresh loop that only runs while the page is visible.
@MainActor
final class MenuBarItemsModel: ObservableObject {
    @Published var items: [MenuBarItemSnapshot] = []
    @Published var capacity: MenuBarCapacity?
    @Published var trusted = false
    @Published var loading = false
    @Published var search = ""
    @Published var selection: Set<String> = []
    @Published var message: String?
    @Published var undoAvailable = false
    @Published var job: MenuBarMoveJob?
    @Published var syncedAt = Date()

    private let actions: SettingsActions
    private var pollTimer: Timer?
    private var refreshTimer: Timer?
    private var iconCache: [String: NSImage] = [:]

    init(actions: SettingsActions) {
        self.actions = actions
    }

    func start() {
        stop()
        trusted = actions.itemsTrusted()
        guard trusted else { return }
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollJob() }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfIdle() }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh() {
        guard trusted else { return }
        loading = items.isEmpty
        actions.refreshItems { [weak self] items, capacity in
            guard let self else { return }
            self.items = items
            self.capacity = capacity
            self.loading = false
            self.undoAvailable = self.actions.canUndoItems()
            self.selection = self.selection.filter { id in items.contains { $0.id == id } }
            self.syncedAt = Date()
            self.message = nil
        }
    }

    private func refreshIfIdle() {
        guard job == nil || job?.isRunning == false else { return }
        refresh()
    }

    private func pollJob() {
        guard let job = actions.currentMoveJob() else {
            if self.job != nil {
                self.job = nil
                undoAvailable = actions.canUndoItems()
                refresh()
            }
            return
        }
        self.job = job
        if !job.isRunning {
            self.job = nil
            undoAvailable = actions.canUndoItems()
            if job.state == .failed {
                message = job.errorMessage
            }
            refresh()
        }
    }

    func move(_ ids: Set<String>, to group: MenuBarItemGroup, before: String?) {
        guard !ids.isEmpty else { return }
        guard actions.moveItems(Array(ids), group, before) else {
            message = L10n.t("已有任务在执行，请稍候", "A move is already running")
            return
        }
        selection.removeAll()
        message = nil
        pollJob()
    }

    func undo() {
        guard actions.undoItems() else {
            message = L10n.t("没有可撤销的操作", "Nothing to undo")
            return
        }
        pollJob()
    }

    func toggleSelection(_ id: String, extending: Bool) {
        if extending {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
    }

    func icon(for item: MenuBarItemSnapshot) -> NSImage? {
        if let cached = iconCache[item.bundleID] { return cached }
        guard item.kind != .system,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.bundleID) else {
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[item.bundleID] = image
        return image
    }

    var filtered: [MenuBarItemSnapshot] {
        guard !search.trimmingCharacters(in: .whitespaces).isEmpty else { return items }
        let needle = search.lowercased()
        return items.filter { item in
            item.displayName.lowercased().contains(needle)
                || item.bundleID.lowercased().contains(needle)
                || item.title.lowercased().contains(needle)
        }
    }

    /// System extras are pinned by macOS; they are listed separately and never
    /// belong to a draggable group.
    func group(_ group: MenuBarItemGroup) -> [MenuBarItemSnapshot] {
        filtered
            .filter { $0.isManaged && $0.group == group }
            .sorted { $0.index < $1.index }
    }

    var systemItems: [MenuBarItemSnapshot] {
        filtered
            .filter { $0.kind == .system }
            .sorted { $0.x < $1.x }
    }

    var visibleCount: Int { items.filter { $0.isManaged && $0.group == .visible }.count }
    var hiddenCount: Int { items.filter { $0.isManaged && $0.group == .hidden }.count }
}

struct MenuBarItemsView: View {
    let actions: SettingsActions

    @StateObject private var model: MenuBarItemsModel
    @State private var collapsed = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(actions: SettingsActions) {
        self.actions = actions
        _model = StateObject(wrappedValue: MenuBarItemsModel(actions: actions))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !model.trusted {
                permissionCard
            } else {
                previewCard
                toolbar
                if model.loading && model.items.isEmpty {
                    skeleton
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        groupColumn(.visible)
                        groupColumn(.hidden)
                    }
                }
                systemRow
                footer
            }
        }
        .onAppear {
            collapsed = actions.isCollapsed()
            model.start()
        }
        .onDisappear { model.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .barFoldStateDidChange)) { _ in
            collapsed = actions.isCollapsed()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            let trusted = actions.itemsTrusted()
            if trusted != model.trusted {
                model.trusted = trusted
                if trusted { model.start() }
            }
        }
    }

    // MARK: - Permission

    private var permissionCard: some View {
        SettingsCard(L10n.t("图标管理需要辅助功能", "Icon management needs Accessibility"), icon: "hand.raised") {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.t(
                    "按 App 列出图标、读取它们的位置、在设置里拖动排序，都需要读取其他进程的辅助功能树。macOS 不允许写入菜单栏项的 AXPosition，所以真正的移动使用与按住 ⌘ 拖动相同的合成事件。",
                    "Listing icons by app, reading their positions and reordering them in Settings all require the accessibility tree of other processes. macOS marks menu bar AX positions read-only, so moves use the same synthetic ⌘-drag a person would perform."
                ))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button {
                        actions.openAccessibilitySettings()
                    } label: {
                        Label(L10n.t("打开系统设置", "Open System Settings"), systemImage: "gear")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button {
                        model.trusted = actions.itemsTrusted()
                        if model.trusted { model.start() }
                    } label: {
                        Label(L10n.t("已授权，重新检查", "Granted, check again"), systemImage: "arrow.clockwise")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Label(
                    L10n.t("折叠、悬停、热键仍然零权限；不授权不影响核心功能。", "Folding, hover and the hotkey stay permission-free; declining does not affect them."),
                    systemImage: "lock.shield"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Preview

    private var previewCard: some View {
        SettingsCard(L10n.t("菜单栏预览", "Menu bar preview"), icon: "menubar.rectangle") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 4) {
                    ForEach(model.group(.hidden).suffix(8)) { item in
                        previewIcon(item, dimmed: true)
                    }
                    if model.hiddenCount > 8 {
                        Text("+\(model.hiddenCount - 8)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Capsule()
                        .fill(Color.primary.opacity(0.18))
                        .frame(width: 1.5, height: 14)
                        .padding(.horizontal, 4)
                    Image(systemName: collapsed ? "chevron.right" : "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(BarFoldTheme.accent)
                        .padding(.horizontal, 3)
                    ForEach(model.group(.visible).prefix(8)) { item in
                        previewIcon(item, dimmed: false)
                    }
                    if model.visibleCount > 8 {
                        Text("+\(model.visibleCount - 8)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Divider().frame(height: 14)
                    ForEach(model.systemItems.prefix(6)) { item in
                        previewIcon(item, dimmed: true)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 30)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.05))
                )

                Text(L10n.t(
                    "左侧图标收起后隐藏，右侧图标保持可见。拖动任一行即可换组或排序。",
                    "Icons on the left hide when collapsed; the ones on the right stay visible. Drag any row to regroup or reorder."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func previewIcon(_ item: MenuBarItemSnapshot, dimmed: Bool) -> some View {
        Group {
            if let icon = model.icon(for: item) {
                Image(nsImage: icon).resizable().frame(width: 15, height: 15)
            } else {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(dimmed ? 0.45 : 1)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField(L10n.t("搜索 App 或图标", "Search apps or icons"), text: $model.search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )

            Spacer(minLength: 8)

            if let job = model.job, job.isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(L10n.t("移动 \(job.results.count)/\(max(job.steps.count, 1))", "Moving \(job.results.count)/\(max(job.steps.count, 1))"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }

            Button {
                model.undo()
            } label: {
                Label(L10n.t("撤销", "Undo"), systemImage: "arrow.uturn.backward")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!model.undoAvailable || (model.job?.isRunning ?? false))
            .keyboardShortcut("z", modifiers: .command)

            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(L10n.t("重新扫描", "Scan again"))
        }
    }

    // MARK: - Groups

    private func groupColumn(_ group: MenuBarItemGroup) -> some View {
        let items = model.group(group)
        let isVisible = group == .visible
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isVisible ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(isVisible ? L10n.t("收起时仍显示", "Visible when collapsed") : L10n.t("收起时隐藏", "Hidden when collapsed"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(items.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 4) {
                    ForEach(items) { item in
                        row(item, in: group)
                    }
                    if !items.isEmpty {
                        dropTail(group)
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 320)

            if items.isEmpty {
                Text(model.search.isEmpty
                     ? L10n.t("拖动图标到这里", "Drag icons here")
                     : L10n.t("没有匹配的图标", "No matches"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: BarFoldTheme.cardRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.45 : 0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: BarFoldTheme.cardRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func row(_ item: MenuBarItemSnapshot, in group: MenuBarItemGroup) -> some View {
        let selected = model.selection.contains(item.id)
        return HStack(spacing: 8) {
            if let icon = model.icon(for: item) {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            } else {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if !item.title.isEmpty && item.kind != .system {
                    Text(item.title)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? BarFoldTheme.accent.opacity(0.16) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(selected ? BarFoldTheme.accent.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            model.toggleSelection(item.id, extending: NSEvent.modifierFlags.contains(.command))
        }
        .draggable(payload(for: item))
        .dropDestination(for: String.self) { payloads, _ in
            drop(payloads, before: item.id, into: group)
        }
        .contextMenu {
            Button(group == .visible ? L10n.t("移到隐藏组", "Move to hidden") : L10n.t("移到显示组", "Move to visible")) {
                model.move(model.selection.contains(item.id) ? model.selection : [item.id],
                           to: group == .visible ? .hidden : .visible,
                           before: nil)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(item, group: group))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func dropTail(_ group: MenuBarItemGroup) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.clear)
            .frame(height: 18)
            .overlay(
                Text(L10n.t("拖到末尾", "Drop at end"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            )
            .dropDestination(for: String.self) { payloads, _ in
                drop(payloads, before: nil, into: group)
            }
    }

    private func payload(for item: MenuBarItemSnapshot) -> String {
        let ids = model.selection.contains(item.id) ? Array(model.selection) : [item.id]
        return ids.joined(separator: "\n")
    }

    private func drop(_ payloads: [String], before anchor: String?, into group: MenuBarItemGroup) -> Bool {
        let ids = payloads
            .flatMap { $0.split(separator: "\n").map(String.init) }
            .filter { id in model.items.contains { $0.id == id && $0.isManaged } }
        guard !ids.isEmpty else { return false }
        model.move(Set(ids), to: group, before: anchor)
        return true
    }

    private func accessibilityLabel(_ item: MenuBarItemSnapshot, group: MenuBarItemGroup) -> String {
        let position = L10n.t(
            "第 \(item.index + 1) 个，共 \(model.group(group).count) 个",
            "Item \(item.index + 1) of \(model.group(group).count)"
        )
        let side = group == .visible
            ? L10n.t("收起时仍显示", "Visible when collapsed")
            : L10n.t("收起时隐藏", "Hidden when collapsed")
        return "\(item.displayName)，\(side)，\(position)"
    }

    // MARK: - System / footer

    private var systemRow: some View {
        Group {
            if !model.systemItems.isEmpty {
                SettingsCard(L10n.t("系统菜单栏", "System extras"), icon: "switch.2") {
                    HStack(spacing: 10) {
                        ForEach(model.systemItems) { item in
                            HStack(spacing: 5) {
                                Image(systemName: "circle.grid.2x1")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Text(item.displayName)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.primary.opacity(0.05)))
                        }
                        Spacer(minLength: 0)
                    }
                    Text(L10n.t("系统项由 macOS 管理，不参与分组与排序。", "System extras are managed by macOS and are not regrouped or reordered."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let capacity = model.capacity {
                HStack(spacing: 8) {
                    Text(L10n.t("显示组占用", "Visible group usage"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    ProgressView(value: min(1, capacity.usedWidth / max(capacity.menuBarWidth, 1)))
                        .progressViewStyle(.linear)
                        .tint(capacity.level == .overflow ? .red : (capacity.level == .tight ? .orange : BarFoldTheme.accent))
                    Text("\(Int(capacity.usedWidth)) / \(Int(capacity.menuBarWidth)) px")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if capacity.level == .overflow {
                    Label(
                        L10n.t("显示组过大，会把系统图标挤出屏幕。请移回隐藏组。", "The visible group is too wide and will push system extras off-screen. Move some back."),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                }
            }

            if let message = model.message {
                Label(message, systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.05))
                    .frame(height: 34)
            }
        }
        .padding(.vertical, 8)
    }
}
