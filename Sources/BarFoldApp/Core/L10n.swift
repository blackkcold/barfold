import Foundation

enum L10n {
    static var isChinese: Bool {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") ?? false
    }

    static func t(_ chinese: String, _ english: String) -> String {
        isChinese ? chinese : english
    }

    static var appName: String { "BarFold" }

    static var collapse: String { t("收起菜单栏图标", "Collapse menu bar icons") }
    static var expand: String { t("展开菜单栏图标", "Expand menu bar icons") }
    static var collapsed: String { t("已收起", "Collapsed") }
    static var expanded: String { t("已展开", "Expanded") }
    static var settings: String { t("设置…", "Settings…") }
    static var about: String { t("关于 BarFold", "About BarFold") }
    static var quit: String { t("退出 BarFold", "Quit BarFold") }
    static var safeMode: String { t("安全模式", "Safe mode") }
    static var safeModeHelp: String {
        t("保持展开并暂停自动收起，便于排查问题", "Stay expanded and pause auto-collapse for troubleshooting")
    }
    static var exitSafeMode: String { t("退出安全模式", "Exit safe mode") }
    static var checkForUpdates: String { t("检查更新…", "Check for Updates…") }
    static var noEngine: String {
        t("当前系统暂不支持折叠", "Folding is not supported on this macOS version")
    }
    static var newIconsHint: String {
        t("新图标可能出现在箭头左侧", "New icons may appear left of the arrow")
    }
}
