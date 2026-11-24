import SwiftUI

struct MenuBarPreview: View {
    @Binding var collapsed: Bool
    var interactive: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let hiddenApps: [(String, Color)] = [
        ("message.fill", .green),
        ("calendar", .red),
        ("cloud.fill", .blue),
        ("music.note", .pink),
        ("camera.fill", .gray),
        ("doc.text.fill", .orange),
    ]
    private let systemIcons = ["wifi", "battery.75", "speaker.wave.2.fill"]

    var body: some View {
        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.17), Color(white: 0.10)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            HStack(spacing: 0) {
                HStack(spacing: 9) {
                    ForEach(Array(hiddenApps.enumerated()), id: \.offset) { _, app in
                        appIcon(app.0, color: app.1)
                    }
                }
                .frame(width: 190, alignment: .leading)
                .offset(x: collapsed ? -190 : 0)
                .opacity(collapsed ? 0 : 1)

                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    ForEach(systemIcons, id: \.self) { name in
                        Image(systemName: name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                    }

                    Rectangle()
                        .fill(Color.white.opacity(0.14))
                        .frame(width: 1, height: 18)
                        .padding(.horizontal, 2)

                    Button {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.86)) {
                            collapsed.toggle()
                        }
                    } label: {
                        Image(systemName: collapsed ? "chevron.right" : "chevron.left")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 24, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.white.opacity(0.10))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!interactive)
                    .accessibilityLabel(
                        collapsed
                            ? L10n.t("展开菜单栏", "Expand menu bar")
                            : L10n.t("收起菜单栏", "Collapse menu bar")
                    )
                }
            }
            .padding(.horizontal, 12)

            if collapsed {
                Text(L10n.t("已收起", "Collapsed"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.leading, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .frame(height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.86), value: collapsed)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("菜单栏折叠演示", "Menu bar folding preview"))
    }

    private func appIcon(_ name: String, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(color.gradient)
            Image(systemName: name)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 18, height: 18)
        .shadow(color: color.opacity(0.35), radius: 2, y: 1)
    }
}
