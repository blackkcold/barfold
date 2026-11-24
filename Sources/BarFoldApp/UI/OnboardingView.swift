import SwiftUI

struct OnboardingActions {
    var complete: () -> Void
    var setLoginItem: (Bool) -> Result<LoginItemSnapshot, Error>
    var loginItemStatus: () -> LoginItemSnapshot
}

struct OnboardingView: View {
    let actions: OnboardingActions

    @Environment(\.colorScheme) private var colorScheme
    @State private var collapsed = false
    @State private var launchAtLogin = true

    var body: some View {
        ZStack {
            BarFoldTheme.background(colorScheme)
            VStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 18) {
                        header
                        previewCard
                        featureList
                        note
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 24)
                    .padding(.bottom, 14)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                }
                footer
            }
        }
        .frame(width: 620, height: 740)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            loginCard
            buttons
            permissionNote
        }
        .padding(.horizontal, 32)
        .padding(.top, 12)
        .padding(.bottom, 20)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            BarFoldMark(size: 68)
            Text(L10n.t("欢迎使用 BarFold", "Welcome to BarFold"))
                .font(.system(size: 28, weight: .semibold, design: .rounded))
            Text(L10n.t("把菜单栏图标折叠起来，需要时再展开。",
                        "Fold your menu bar icons away, and bring them back when you need them."))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 4)
    }

    private var previewCard: some View {
        VStack(spacing: 10) {
            MenuBarPreview(collapsed: $collapsed)
            Text(L10n.t("点一下箭头试试", "Try clicking the arrow"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: BarFoldTheme.cardRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.52 : 0.76))
        )
        .overlay(
            RoundedRectangle(cornerRadius: BarFoldTheme.cardRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.065), lineWidth: 1)
        )
    }

    private var featureList: some View {
        VStack(spacing: 12) {
            OnboardingFeatureRow(
                icon: "arrow.left.to.line",
                color: BarFoldTheme.accent,
                title: L10n.t("一键收起", "One-click fold"),
                detail: L10n.t("点击箭头，把左侧图标推出可视区。",
                               "Click the arrow to push the icons on its left out of view.")
            )
            OnboardingFeatureRow(
                icon: "cursorarrow.motionlines",
                color: BarFoldTheme.accentSecondary,
                title: L10n.t("悬停展开", "Hover to expand"),
                detail: L10n.t("把鼠标停在菜单栏空白处，图标自动回来。",
                               "Rest the pointer on an empty part of the menu bar and the icons return.")
            )
            OnboardingFeatureRow(
                icon: "command",
                color: .orange,
                title: L10n.t("全局热键", "Global shortcut"),
                detail: L10n.t("默认 ⌃⌥H，随时切换，不需要鼠标。",
                               "The default ⌃⌥H toggles at any time, without the mouse.")
            )
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: BarFoldTheme.cardRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.52 : 0.76))
        )
        .overlay(
            RoundedRectangle(cornerRadius: BarFoldTheme.cardRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.065), lineWidth: 1)
        )
    }

    private var note: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(BarFoldTheme.accent)
            Text(L10n.t(
                "新安装的 App 图标可能出现在箭头左侧。点一下箭头就能看到，不需要重新启动。",
                "A newly installed app may appear left of the arrow. Click the arrow to see it; no relaunch needed."
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var loginCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToggleRow(
                title: L10n.t("登录时启动", "Launch at login"),
                subtitle: L10n.t("开机后自动在菜单栏待命", "Wait in the menu bar after you log in"),
                isOn: $launchAtLogin
            )
            Text(L10n.t("之后可以在设置中随时修改。", "You can change this later in Settings."))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: BarFoldTheme.cardRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.52 : 0.76))
        )
        .overlay(
            RoundedRectangle(cornerRadius: BarFoldTheme.cardRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.065), lineWidth: 1)
        )
    }

    private var buttons: some View {
        VStack(spacing: 10) {
            Button {
                finish()
            } label: {
                Text(L10n.t("开始使用", "Get started"))
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(BarFoldTheme.accent)
            .controlSize(.large)

            Button(L10n.t("稍后设置", "Set up later")) {
                actions.complete()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    private var permissionNote: some View {
        Text(L10n.t(
            "BarFold 不会请求辅助功能、屏幕录制或输入监控权限。",
            "BarFold requests no Accessibility, Screen Recording or Input Monitoring permission."
        ))
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
    }

    private func finish() {
        _ = actions.setLoginItem(launchAtLogin)
        actions.complete()
    }
}

private struct OnboardingFeatureRow: View {
    let icon: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color.opacity(0.14))
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(color)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
