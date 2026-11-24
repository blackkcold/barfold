# Changelog

## v0.1.0 — 2026-11-24

### Added

- 菜单栏折叠：可见箭头 + 分隔符，把左侧图标推出可视区；状态从分隔符长度派生。
- 固定的状态项位置：创建前预置 `NSStatusItem Preferred Position`，在已溢出的菜单栏上也能让箭头留在屏内。
- 悬停展开：10Hz 轮询鼠标位置，仅右半屏、菜单栏空白处、非图标、非箭头；停留时间可调。
- 自动收回：离开菜单栏后按延迟收回；菜单层 101 打开时顺延；只在用户主动展开后武装。
- 全局热键：Carbon `RegisterEventHotKey`，默认 `⌃⌥H`，设置内可录制/清除，冲突会报错。
- 多显示器：按最宽屏计算折叠长度，屏幕变化先归零再重算。
- 登录时启动：`SMAppService` 优先，LaunchAgent 兜底；设置内显示实际后端。
- 原生设置窗：通用/交互/诊断/关于；含菜单栏折叠演示、诊断报告复制。
- 首启引导：解释“新图标出现在箭头左侧”，含交互式菜单栏演示。
- 诊断：`doctor` 检查引擎、箭头、分隔符、屏幕、socket 权限、登录项、热键、其他菜单栏工具。
- `selftest`：折叠→校验→展开→校验，失败自动恢复。
- CLI/Agent 接口：Unix socket + JSON Lines，稳定退出码；`status/collapse/expand/toggle/probe/wait/settings/hotkey/loginitem/update/selftest/logs/launch/quit`。
- 失败兜底：引擎异常、退出、睡眠、屏幕变化先展开；`UnsupportedEngine` 在 macOS 27+ 明确降级。
- Sparkle 2 集成：`UpdateController` 在 `SUPublicEDKey` 为空时完全惰性；`release.sh` 支持 ad-hoc 开发 zip 与签名 appcast 流程。
- 固定自签脚本：`setup-signing.sh`、临时钥匙串 `signing.sh`、`signing-check.sh`、`docs/signing.md`。
- App 图标：1024 母版 + 全尺寸 iconset + `AppIcon.icns`。

### Verification

- `swift test`：19 个单测通过。
- `scripts/e2e.sh`：折叠 3856pt 分隔符、canary 离屏、可见图标 38→10、展开恢复、selftest/doctor 全绿。
- `scripts/signing-check.sh --adhoc`：ad-hoc 签名、Bundle ID、CLI、Sparkle 嵌入通过。
- 设置窗四页与首启引导已用 cua-driver 截图复核。
- 开发 zip：`release/0.1.0/BarFold-0.1.0.zip`（2.6MB）。

### Known limitations

- macOS 27+ 暂不支持折叠（不做未验证的私有 API 引擎）。
- 不做聚合浮窗、始终隐藏区、图标间距/顺序。
- 与 iBar/Hidden Bar/Ice 等折叠工具互斥。
- 开发包为 ad-hoc 签名；固定证书/EdDSA 密钥待 1Password 登录与用户确认。
- Sparkle appcast 与端到端升级链待密钥完成后验证。

### Pending

- 生成固定自签身份与 Sparkle EdDSA 种子，存入 1Password。
- `scripts/build.sh --local-signed` + `scripts/signing-check.sh` + `scripts/release.sh --signed`。
- 另一台 Mac 的安装与升级验收。
- `/Applications` 安装与登录项重新注册（签名版）。
