# 签名与密钥

BarFold 采用**固定自签身份**分发，不上架 App Store，也不做 Apple 公证。目标是让每次升级后的 TCC 授权、通知权限和登录项审批保持稳定：只要证书叶节点不变，macOS 就把新旧版本视为同一个 App。

## 为什么不能重建证书

`codesign` 的 designated requirement 绑定证书叶节点。重建一张同名证书会得到新的指纹，macOS 会把它当成另一个 App：

- 辅助功能/屏幕录制等 TCC 授权需要重新授予（BarFold 本身不申请这些权限，但登录项审批会重置）；
- 登录项需要重新批准；
- 用户已保存的信任设置失效。

因此：**证书只备份，不重建**。如果 p12 丢失，只能接受一次身份重置，并重新走一遍授权流程。

## 密钥材料

全部位于 `~/.config/barfold/signing`（`0700`），绝不可提交到仓库：

| 文件 | 用途 | 备份 |
|---|---|---|
| `BarFold.p12` | 固定身份的私钥 + 证书 | 1Password + 离线第二份 |
| `BarFold.p12.password` | p12 的随机口令 | 1Password |
| `BarFold.crt` | 证书（可公开） | 仓库外 |
| `Sparkle.edseed` | Sparkle EdDSA 私钥种子（32 字节 base64） | 1Password + 离线第二份 |
| `Sparkle.public-key` | 由种子推导的公钥，写入 `SUPublicEDKey` | 可公开 |

`scripts/build.sh` 只从 `SIGNING_DIR` 读取；它不会把私钥写进登录钥匙串，也不会把口令放进命令行参数或构建日志。

## 创建

先确认：

```bash
op signin                 # 1Password CLI 必须已登录
scripts/setup-signing.sh check
```

`check` 只读，不会生成任何东西。确认后：

```bash
BARFOLD_CONFIRM_SIGNING=1 scripts/setup-signing.sh apply
```

它会生成：

- RSA 3072、10 年、`CA:FALSE`、`extendedKeyUsage=critical,codeSigning` 的自签证书；
- 随机口令的 `BarFold.p12`；
- 32 字节 EdDSA 种子，并用 CryptoKit 推导公钥。

脚本故意不自动上传 1Password：创建后请手动建立两个 Secure Note：

1. `BarFold Code Signing`：附上 `BarFold.p12`、`BarFold.p12.password`，备注 SHA-256 指纹。
2. `BarFold Sparkle EdDSA`：附上 `Sparkle.edseed`，备注公钥。

备份完成后删除本地秘密文件；构建前再用 `op read` 取回。

## 构建

```bash
# 开发
scripts/build.sh --debug --adhoc
scripts/signing-check.sh --adhoc

# 固定身份
scripts/build.sh --local-signed
scripts/signing-check.sh
```

构建过程：

1. `swift build -c release --arch arm64`；
2. 组装 `BarFold.app`，嵌入 `Sparkle.framework`；
3. 从 p12 建立一次性钥匙串（10 分钟自动锁定），导入并设置 partition list；
4. 先签 Sparkle 内嵌的 XPC/Updater/Autoupdate，再签 framework、CLI、App；
5. `codesign --verify --deep --strict`，并断言 `Authority=BarFold Code Signing`、`Signature` 非 ad-hoc、Bundle ID 固定。

`TeamIdentifier=not set` 是自签的正常结果，不是失败条件。

## 分发

- 直接分发 `.zip`（或 DMG），不上架 App Store。
- 不公证、不启用 Hardened Runtime。自签没有 Team ID，启用 library validation 会拒绝加载 Sparkle。
- 首次打开需要右键 → 打开，或在系统设置 → 隐私与安全性中选“仍要打开”。这是自签的代价，不做绕过。
- 不要把 `BarFold.app` 放进 iCloud Drive / 同步盘再运行；移动 App 后登录项路径会失效，需要在设置里重新开启。

## 更新链

Sparkle 2 使用 EdDSA：

- `SUPublicEDKey` 来自 `Sparkle.public-key`；
- `generate_appcast` 使用 `Sparkle.edseed` 签 appcast；
- 私钥只通过临时文件/标准输入传给工具，绝不进入 argv、日志或仓库。

发布前在 `scripts/lib/app-config.sh` 中把 `REPO_SLUG` 改成真实仓库，确认：

```bash
defaults read "$PWD/release/0.1.0/BarFold.app/Contents/Info" SUFeedURL 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Print :SUFeedURL" "release/0.1.0/BarFold.app/Contents/Info.plist"
```

## 故障

| 现象 | 处理 |
|---|---|
| `scripts/build.sh --local-signed` 报缺 p12 | 先 `op signin`，把 p12 和口令 materialize 到 `SIGNING_DIR` |
| `security import` 后 codesign 仍弹窗 | 检查 `set-key-partition-list` 是否执行成功 |
| `signing-check.sh` 报 Authority 不对 | 确认 `SIGN_IDENTITY` 与证书 CN 完全一致 |
| 升级后登录项失效 | 证书换了（不应发生）；或 App 被移动，重新开启登录项 |
| Sparkle 报 `SUPublicEDKey` 无效 | 公钥与 appcast 签名不匹配；不要重新生成种子，检查是否用错了密钥 |
