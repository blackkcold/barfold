import BarFoldProtocol
import SwiftUI

enum BarFoldTheme {
    static let accent = Color(red: 0.36, green: 0.40, blue: 0.98)
    static let accentSecondary = Color(red: 0.16, green: 0.78, blue: 0.68)
    static let cardRadius: CGFloat = 14
    static let controlRadius: CGFloat = 8

    @ViewBuilder
    static func background(_ scheme: ColorScheme) -> some View {
        ZStack {
            if scheme == .dark {
                LinearGradient(
                    colors: [
                        Color(red: 0.055, green: 0.065, blue: 0.105),
                        Color(red: 0.085, green: 0.090, blue: 0.160),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0.975, green: 0.975, blue: 0.995),
                        Color(red: 0.925, green: 0.940, blue: 0.985),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            RadialGradient(
                colors: [accent.opacity(scheme == .dark ? 0.16 : 0.10), .clear],
                center: .topTrailing,
                startRadius: 10,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
    }
}

struct BarFoldMark: View {
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [BarFoldTheme.accent, BarFoldTheme.accentSecondary],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "arrow.left.to.line")
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
        }
        .frame(width: size, height: size)
        .shadow(color: BarFoldTheme.accent.opacity(0.35), radius: 10, y: 4)
        .accessibilityHidden(true)
    }
}

struct SettingsCard<Content: View>: View {
    private let title: String?
    private let icon: String?
    private let content: Content
    @Environment(\.colorScheme) private var colorScheme

    init(_ title: String? = nil, icon: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                HStack(spacing: 8) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(BarFoldTheme.accent)
                            .frame(width: 16)
                    }
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: BarFoldTheme.cardRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.52 : 0.76))
        )
        .overlay(
            RoundedRectangle(cornerRadius: BarFoldTheme.cardRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.065), lineWidth: 1)
        )
    }
}

struct ToggleRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool
    var disabled: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(disabled)
                .accessibilityLabel(title)
        }
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var enabled: Bool = true
    let valueText: String

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(valueText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.45)
        }
    }
}

struct StatusPill: View {
    let collapsed: Bool

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(collapsed ? Color.orange : Color.green)
                .frame(width: 7, height: 7)
            Text(collapsed ? L10n.collapsed : L10n.expanded)
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

struct CheckRow: View {
    let check: JSONValue

    private var status: String { check["status"]?.stringValue ?? "warn" }

    private var color: Color {
        switch status {
        case "pass": return .green
        case "fail": return .red
        default: return .orange
        }
    }

    private var icon: String {
        switch status {
        case "pass": return "checkmark.circle.fill"
        case "fail": return "xmark.octagon.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }

    private var label: String {
        switch status {
        case "pass": return L10n.t("通过", "Pass")
        case "fail": return L10n.t("失败", "Fail")
        default: return L10n.t("注意", "Warn")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(check["name"]?.stringValue ?? "?")
                    .font(.system(size: 12, weight: .medium))
                Text(check["detail"]?.stringValue ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(color.opacity(0.12)))
        }
    }
}

struct FeatureBadge: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .medium))
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .overlay(Capsule().stroke(Color.primary.opacity(0.07), lineWidth: 1))
    }
}
