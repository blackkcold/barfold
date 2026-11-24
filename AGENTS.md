# AGENTS.md — BarFold

本文件是仓库的 agent 入口。先读它，再读 `README.md` 与 `docs/`。冲突时以仓库规则为准。

## 项目

BarFold 是一个核心零权限的 macOS 菜单栏折叠工具。Swift 6 编译器 / Swift 5 language mode，SwiftPM + AppKit + SwiftUI，唯一第三方依赖 Sparkle 2。

- Bundle ID：`com.haoran.BarFold`（首次发版后冻结）
- 最低系统：macOS 14
- 签名：固定自签身份 `BarFold Code Signing`；不公证、不开 Hardened Runtime
- 分发：直接分发 zip；不上架 App Store

## 命令

```bash
swift build -c debug
swift test
scripts/build.sh --debug --adhoc
scripts/e2e.sh
scripts/signing-check.sh --adhoc
scripts/release.sh --adhoc
```

- 任何 UI/交互改动后必须跑 `scripts/e2e.sh`。
- 任何签名/打包改动后必须跑 `scripts/signing-check.sh --adhoc`。
- 固定身份构建：`scripts/build.sh --local-signed`；材料未就绪时不要伪造通过。
- 发布流程见 `docs/release.md`。

## 不变量（改代码前先读）

1. **状态项创建顺序**：箭头 → 分隔符 → canary。后创建的状态项出现在左侧；顺序反了会把箭头自己藏掉。
2. **预置位置**：创建前写入 `NSStatusItem Preferred Position barfold_toggle`（默认 250）和 `barfold_separator`（toggle + 15）。数值越大越靠左。已有合法值不要覆盖，否则会打乱用户拖拽后的位置。
3. **状态从长度派生**：`isCollapsed = separator.length > expandedLength + 4`，不要另存 bool。
4. **分隔符窗口必须 `ignoresMouseEvents = true`**，否则折叠后左侧菜单栏点击被吞。
5. **退出/睡眠/屏幕变化/引擎异常一律先展开**；绝不能让用户退出后菜单栏还处于折叠状态。
6. **自动收回只在用户主动展开后武装**（click/hover/hotkey/menu），启动恢复、CLI expand、设置展开不武装。菜单层 101 打开时暂停收回。
7. **悬停只在右半屏、菜单栏带内、非状态项窗口、非箭头、非菜单打开时触发**；10Hz 轮询，不申请权限。
8. **不做未验证的 macOS 27 引擎**。27+ 返回 `UnsupportedEngine`，保持展开并明确提示。私有 API 只在未来实验开关中出现。
9. **核心零权限**：折叠、悬停、热键、自动收回、登录启动不申请辅助功能、屏幕录制、输入监控、通知。可选的图标管理（`items.*` / `layout.*` 命令、设置里的菜单栏页）只在用户主动开启时请求辅助功能；未授权必须明确降级，不能假装可用。聚合浮窗（需要权限）不在 v1。
10. **CLI 是一等接口**：Unix socket `0600` + peer UID 校验；JSON Lines；退出码 `0/2/3/4/5` 稳定；破坏性变更必须版本化。
11. **固定身份只备份不重建**。重建证书会重置 TCC、通知和登录项审批。见 `docs/signing.md`。
12. **不复用 GPL 代码**（Ice/Thaw/Dimble）。Hidden Bar（MIT）、menubar-hide（MIT）、MenuTidy（Unlicense）只作思路参考时也要保留归属说明。
13. **UX 是验收项**：设置窗/引导在浅色/深色、降低动态、键盘操作下都要可用；不牺牲可读性换“高级感”。
14. **失败软着陆**：任何引擎/探针失败都退回展开，并在 `doctor` 中给出可读原因。
15. **移动别人的图标只有合成 ⌘-拖拽一条路**（macOS 26.4 实测）：菜单栏项的 `AXPosition` 全部 `settable=false`，AX 只能读不能移。任何移动都必须在用户显式操作后执行，先快照、失败回滚。唯一例外是用户开启的「新图标自动移入隐藏组」：只处理新出现的项，插到隐藏组最左侧，绝不重排已有图标。
16. **分隔符永不隐藏**：`isVisible = false` 会让 AppKit 删除 `NSStatusItem Preferred Position`，重新显示后右缘会落到几百点之外，折叠直接失效（实测 1621 → 950）。AppKit 还会把 `isVisible` 持久化到 `NSStatusItem VisibleCC`，启动时必须清掉并强制 `isVisible = true`。展开态最小长度 1（窗口 17pt），0 会让项消失。分隔符内容区只有 1pt，宽于它的图像会被裁掉；竖线必须画成 1×12 的模板图并设 `imageScaling = .scaleNone`。

## 目录

- `Sources/BarFoldProtocol/`：共享协议、几何、JSON、KeyCombo、交互状态机（可单测）
- `Sources/BarFoldApp/`：AppKit/SwiftUI 应用
- `Sources/BarFoldCLI/`：`barfold` CLI
- `Tests/BarFoldTests/`：纯逻辑单测
- `scripts/`：构建、签名、e2e、图标、发布
- `docs/`：方案、签名、发版

## 验收阶梯

1. **L0 静态**：`swift build` 无 error；不新增 `as any` / `@ts-ignore` 类绕过。
2. **L1 单元**：`swift test` 全绿（几何、状态机、KeyCombo）。
3. **L2 接口**：`barfold doctor` 无 fail；`barfold wait` 无竞态。
4. **L3 集成**：`scripts/e2e.sh` 全绿（折叠/展开/canary/几何/selftest）。
5. **L4 真机 UI**：设置窗、引导、菜单栏、热键在真实桌面验证；截图仅作诊断，不作唯一判据。
6. **L5 更新链**：固定身份 + EdDSA + appcast + 旧版→新版升级；当前依赖密钥材料。

没有跑过的层级，只能声明“未验证”。

## 发布门槛

- `version.txt` 语义化版本；`CHANGELOG.md` 更新。
- `scripts/build.sh --local-signed` 通过。
- `scripts/signing-check.sh` 通过：Authority 固定、非 ad-hoc、Bundle ID 固定、Sparkle 嵌套签名完整、`SUPublicEDKey` 非空。
- `scripts/release.sh --signed` 生成 zip + appcast；`appcast.xml` 的 `edSignature` 存在。
- 另一台 Mac 安装、打开、升级；升级后 Authority 不变、登录项不重置。
- 不上架 App Store；不做公证绕过。

## 已知限制

- macOS 27 不支持折叠（v1）。
- 不做聚合浮窗、始终隐藏区、间距/顺序。
- 开发构建为 ad-hoc；固定身份/EdDSA 密钥需 1Password 登录后生成。
- Sparkle 在 `SUPublicEDKey` 为空时完全惰性，菜单“检查更新”只显示配置提示。
- iBar/Hidden Bar/Ice 同时运行会互斥；`doctor` 会 warn。

## 记忆

跨会话的项目事实写入 `.memory/`（若存在）；临时假设/失败尝试写入 `.context/` 或 PENDING，不要写进稳定文档。
