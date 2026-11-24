import AppKit
import BarFoldProtocol
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case interaction
    case diagnostics
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L10n.t("通用", "General")
        case .interaction: return L10n.t("交互", "Interaction")
        case .diagnostics: return L10n.t("诊断", "Diagnostics")
        case .about: return L10n.t("关于", "About")
        }
    }

    var subtitle: String {
        switch self {
        case .general: return L10n.t("启动、更新与菜单栏提示", "Launch, updates and menu bar hints")
        case .interaction: return L10n.t("悬停、自动收回与全局热键", "Hover, auto-collapse and global shortcut")
        case .diagnostics: return L10n.t("引擎状态、屏幕与恢复工具", "Engine, displays and recovery tools")
        case .about: return L10n.t("版本、命令行接口与许可", "Version, CLI and credits")
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .interaction: return "cursorarrow.motionlines"
        case .diagnostics: return "stethoscope"
        case .about: return "info.circle"
        }
    }
}

@MainActor
final class SettingsNavigationModel: ObservableObject {
    @Published var tab: SettingsTab = .general
}

struct SettingsActions {
    var isCollapsed: () -> Bool
    var toggleCollapsed: () -> Void
    var expand: () -> Void
    var doctor: () -> JSONValue
    var selfTest: () -> JSONValue
    var screens: () -> [ScreenDescriptor]
    var engineDescription: () -> String
    var hotkeyError: () -> String?
    var setHotkey: (KeyCombo?) -> Void
    var loginItemStatus: () -> LoginItemSnapshot
    var setLoginItem: (Bool) -> Result<LoginItemSnapshot, Error>
    var openLoginItemSettings: () -> Void
    var checkForUpdates: () -> Void
    var setAutomaticUpdates: (Bool) -> Void
    var quit: () -> Void
    var resetOnboarding: () -> Void
    var arrowFrame: () -> String
    var socketPath: () -> String
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var navigation: SettingsNavigationModel
    let actions: SettingsActions

    @Environment(\.colorScheme) private var colorScheme
    @State private var collapsed = false
    @State private var doctor: JSONValue?
    @State private var selfTest: JSONValue?
    @State private var loginStatus = LoginItemSnapshot.disabled
    @State private var loginError: String?
    @State private var previewCollapsed = false

    var body: some View {
        ZStack {
            BarFoldTheme.background(colorScheme)
            HStack(spacing: 0) {
                sidebar
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: 1)
                contentColumn
            }
        }
        .frame(minWidth: 760, minHeight: 540)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .barFoldStateDidChange)) { _ in
            collapsed = actions.isCollapsed()
        }
    }

    // MARK: - Shell

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BarFoldMark(size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text("BarFold")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text("v\(appVersion)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 28)
            .padding(.horizontal, 18)
            .padding(.bottom, 22)

            ForEach(SettingsTab.allCases) { tab in
                Button {
                    navigation.tab = tab
                } label: {
                    sidebarRow(tab)
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 9) {
                Label(L10n.t("零权限 · 本地运行", "Zero permissions · local"), systemImage: "lock.shield")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button {
                    actions.quit()
                } label: {
                    Label(L10n.quit, systemImage: "power")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(18)
        }
        .frame(width: 196)
        .background(.thinMaterial)
    }

    private func sidebarRow(_ tab: SettingsTab) -> some View {
        let selected = navigation.tab == tab
        return HStack(spacing: 10) {
            Image(systemName: tab.icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 18)
            Text(tab.title)
                .font(.system(size: 13, weight: selected ? .semibold : .medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? BarFoldTheme.accent.opacity(0.14) : Color.clear)
        )
        .overlay(alignment: .leading) {
            if selected {
                Capsule()
                    .fill(BarFoldTheme.accent)
                    .frame(width: 3, height: 16)
                    .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
    }

    private var contentColumn: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                tabContent
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(navigation.tab.title)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text(navigation.tab.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(collapsed: collapsed)
            Button {
                actions.toggleCollapsed()
            } label: {
                Label(
                    collapsed ? L10n.expand : L10n.collapse,
                    systemImage: collapsed ? "chevron.right" : "chevron.left"
                )
                .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 18)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch navigation.tab {
        case .general:
            general
        case .interaction:
            interaction
        case .diagnostics:
            diagnostics
        case .about:
            about
        }
    }

    // MARK: - General

    private var general: some View {
        VStack(spacing: 16) {
            hero

            SettingsCard(L10n.t("启动与更新", "Launch & updates"), icon: "power") {
                ToggleRow(
                    title: L10n.t("登录时启动", "Launch at login"),
                    subtitle: loginStatus.detail,
                    isOn: Binding(
                        get: { loginStatus.enabled },
                        set: { setLoginItem($0) }
                    )
                )
                if loginStatus.requiresApproval {
                    HStack {
                        Spacer()
                        Button(L10n.t("打开系统设置", "Open System Settings")) {
                            actions.openLoginItemSettings()
                        }
                        .controlSize(.small)
                    }
                }
                if let loginError {
                    Label(loginError, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }

                Divider().opacity(0.5)

                ToggleRow(
                    title: L10n.t("自动检查更新", "Check for updates"),
                    subtitle: L10n.t("每天检查一次；有更新时在菜单中提示", "Once a day; a menu hint appears when an update exists"),
                    isOn: Binding(
                        get: { settings.updateAutomatically },
                        set: { value in
                            settings.updateAutomatically = value
                            actions.setAutomaticUpdates(value)
                        }
                    )
                )
                HStack {
                    Spacer()
                    Button(L10n.checkForUpdates) {
                        actions.checkForUpdates()
                    }
                    .controlSize(.small)
                }
            }

            SettingsCard(L10n.t("新图标提示", "New icon hint"), icon: "lightbulb") {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(BarFoldTheme.accent)
                    Text(L10n.t(
                        "新安装的 App 图标会出现在箭头左侧。点击箭头即可看到；也可以关闭这条提示。",
                        "Newly installed apps appear left of the arrow. Click the arrow to reveal them; you can turn this hint off."
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Toggle("", isOn: $settings.showNewIconHint)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
        }
    }

    private var hero: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(BarFoldTheme.accent.opacity(0.14))
                    .frame(width: 52, height: 52)
                Image(systemName: collapsed ? "chevron.right.2" : "chevron.left.2")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(BarFoldTheme.accent)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(collapsed ? L10n.t("菜单栏已收起", "Menu bar collapsed") : L10n.t("菜单栏已展开", "Menu bar expanded"))
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text(collapsed
                     ? L10n.t("被隐藏的图标仍在屏幕外；点击展开即可恢复。", "Hidden icons are still off-screen; expand to bring them back.")
                     : L10n.t("所有图标都在可见区域；点击收起可腾出空间。", "Every icon is visible; collapse to make room."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                actions.toggleCollapsed()
            } label: {
                Label(
                    collapsed ? L10n.expand : L10n.collapse,
                    systemImage: collapsed ? "chevron.right" : "chevron.left"
                )
                .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(BarFoldTheme.accent)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: BarFoldTheme.cardRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            BarFoldTheme.accent.opacity(0.16),
                            BarFoldTheme.accentSecondary.opacity(0.08),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: BarFoldTheme.cardRadius, style: .continuous)
                .stroke(BarFoldTheme.accent.opacity(0.18), lineWidth: 1)
        )
    }

    // MARK: - Interaction

    private var interaction: some View {
        VStack(spacing: 16) {
            SettingsCard(L10n.t("悬停展开", "Hover to expand"), icon: "cursorarrow.motionlines") {
                ToggleRow(
                    title: L10n.t("悬停在菜单栏空白处展开", "Expand when hovering empty menu bar"),
                    subtitle: L10n.t("只对右侧图标区域生效；划过图标不会触发", "Only the right icon area; passing over icons will not trigger"),
                    isOn: $settings.hoverEnabled
                )
                SliderRow(
                    title: L10n.t("停留时间", "Dwell time"),
                    value: $settings.hoverDelay,
                    range: 0.1...1.0,
                    step: 0.05,
                    enabled: settings.hoverEnabled,
                    valueText: String(format: "%.2fs", settings.hoverDelay)
                )
            }

            SettingsCard(L10n.t("自动收回", "Auto-collapse"), icon: "arrow.down.right.and.arrow.up.left") {
                ToggleRow(
                    title: L10n.t("离开菜单栏后自动收回", "Collapse after the pointer leaves"),
                    subtitle: L10n.t("菜单打开时会自动顺延，不会打断操作", "Open menus postpone it, so they are never interrupted"),
                    isOn: $settings.autoCollapseEnabled
                )
                SliderRow(
                    title: L10n.t("等待时间", "Delay"),
                    value: $settings.collapseDelay,
                    range: 0.2...3.0,
                    step: 0.1,
                    enabled: settings.autoCollapseEnabled,
                    valueText: String(format: "%.1fs", settings.collapseDelay)
                )
            }

            SettingsCard(L10n.t("全局热键", "Global shortcut"), icon: "command") {
                HotkeyRecorder(
                    combo: settings.hotkey,
                    onChange: actions.setHotkey,
                    errorMessage: actions.hotkeyError()
                )
            }

            SettingsCard(L10n.t("折叠演示", "Fold preview"), icon: "play.rectangle") {
                MenuBarPreview(collapsed: $previewCollapsed)
                HStack {
                    Text(L10n.t("这是演示，不会改变真实菜单栏。", "This is a demo; it does not change the real menu bar."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.t("播放", "Play")) {
                        withAnimation {
                            previewCollapsed.toggle()
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Diagnostics

    private var diagnostics: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                Button {
                    doctor = actions.doctor()
                } label: {
                    Label(L10n.t("刷新检查", "Refresh"), systemImage: "arrow.clockwise")
                }
                .controlSize(.small)

                Button {
                    selfTest = actions.selfTest()
                } label: {
                    Label(L10n.t("运行自检", "Run self-test"), systemImage: "checkmark.shield")
                }
                .controlSize(.small)

                Spacer()

                Button {
                    copyDiagnostics()
                } label: {
                    Label(L10n.t("复制报告", "Copy report"), systemImage: "doc.on.doc")
                }
                .controlSize(.small)
            }

            SettingsCard(L10n.t("系统检查", "System checks"), icon: "stethoscope") {
                if let checks = doctor?["checks"]?.arrayValue {
                    VStack(spacing: 10) {
                        ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
                            CheckRow(check: check)
                        }
                    }
                } else {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(L10n.t("正在检查…", "Checking…"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let checks = selfTest?["checks"]?.arrayValue {
                SettingsCard(L10n.t("自检结果", "Self-test result"), icon: "checkmark.seal") {
                    VStack(spacing: 10) {
                        ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
                            CheckRow(check: check)
                        }
                    }
                }
            }

            SettingsCard(L10n.t("系统信息", "System info"), icon: "desktopcomputer") {
                InfoRow(label: L10n.t("引擎", "Engine"), value: actions.engineDescription())
                InfoRow(label: "macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
                InfoRow(label: L10n.t("屏幕", "Displays"), value: screenSummary)
                InfoRow(label: L10n.t("箭头位置", "Arrow"), value: actions.arrowFrame())
                InfoRow(label: L10n.t("控制接口", "Control"), value: actions.socketPath())
            }

            SettingsCard(L10n.t("恢复", "Recovery"), icon: "wrench.and.screwdriver") {
                HStack {
                    Button {
                        actions.expand()
                    } label: {
                        Label(L10n.t("立即展开", "Expand now"), systemImage: "chevron.left")
                    }
                    .controlSize(.small)

                    Spacer()

                    Button {
                        actions.resetOnboarding()
                    } label: {
                        Label(L10n.t("重新显示引导", "Show welcome again"), systemImage: "sparkles")
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - About

    private var about: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                BarFoldMark(size: 72)
                Text("BarFold")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text(L10n.t("v\(appVersion) · 零权限菜单栏折叠", "v\(appVersion) · zero-permission menu bar folding"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)

            HStack(spacing: 8) {
                FeatureBadge(icon: "lock.shield", text: L10n.t("零权限", "Zero permissions"))
                FeatureBadge(icon: "cpu", text: L10n.t("本地运行", "Local"))
                FeatureBadge(icon: "person.crop.circle.badge.xmark", text: L10n.t("无账号", "No account"))
            }

            SettingsCard(L10n.t("命令行接口", "Command line"), icon: "terminal") {
                Text("""
                barfold status
                barfold collapse
                barfold probe --json
                """)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                Text(L10n.t("CLI 位于 BarFold.app/Contents/Helpers/barfold。", "The CLI lives at BarFold.app/Contents/Helpers/barfold."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            SettingsCard(L10n.t("关于 BarFold", "About BarFold"), icon: "info.circle") {
                Text(L10n.t(
                    "BarFold 用一根分隔符把菜单栏图标推出可视区；不请求辅助功能、屏幕录制或输入监控权限。",
                    "BarFold pushes menu bar icons off-screen with a separator; it requests no Accessibility, Screen Recording or Input Monitoring permission."
                ))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Text("SwiftUI · AppKit · Carbon")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Button {
                actions.resetOnboarding()
            } label: {
                Label(L10n.t("重新显示欢迎引导", "Show welcome again"), systemImage: "sparkles")
            }
            .controlSize(.small)
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    private var screenSummary: String {
        actions.screens()
            .map { "\($0.name) \(Int($0.frame.width))×\(Int($0.frame.height))" }
            .joined(separator: " · ")
    }

    private func refresh() {
        collapsed = actions.isCollapsed()
        loginStatus = actions.loginItemStatus()
        doctor = actions.doctor()
    }

    private func setLoginItem(_ enabled: Bool) {
        switch actions.setLoginItem(enabled) {
        case .success(let snapshot):
            loginStatus = snapshot
            loginError = nil
        case .failure(let error):
            loginError = error.localizedDescription
            loginStatus = actions.loginItemStatus()
        }
    }

    private func copyDiagnostics() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(doctor ?? .null),
              let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
