# 发布与更新

BarFold 只做直接分发：`.zip` + Sparkle 2 appcast，不上架 App Store，不公证。完整签名背景见 [signing.md](signing.md)。

## 前置条件

- 固定自签身份已创建并备份在 1Password；
- `Sparkle.edseed` 与 `Sparkle.public-key` 已生成；
- `scripts/lib/app-config.sh` 中的 `REPO_SLUG` 指向真实仓库；
- 1Password CLI 已登录，且 p12/口令/种子可 materialize 到 `~/.config/barfold/signing`。

检查：

```bash
scripts/setup-signing.sh check
scripts/build.sh --local-signed
scripts/signing-check.sh
```

## 发版步骤

1. 修改 `version.txt`（语义化版本）和 `CHANGELOG.md`。
2. 构建并验证固定身份：

   ```bash
   scripts/build.sh --local-signed
   scripts/signing-check.sh
   ```

3. 生成 zip、校验和与 appcast：

   ```bash
   scripts/release.sh --signed
   ```

   产物：

   - `release/<version>/BarFold-<version>.zip`
   - `release/<version>/BarFold-<version>.zip.sha256`
   - `release/<version>/BarFold-<version>.md`
   - `release/<version>/appcast.xml`

4. 检查 `appcast.xml`：
   - `sparkle:edSignature` 存在；
   - `enclosure url` 指向 `https://github.com/<repo>/releases/download/v<version>/BarFold-<version>.zip`；
   - `sparkle:version` 与 `CFBundleVersion` 一致。

5. 发布 GitHub Release（确认后再执行）：

   ```bash
   gh release create v<version> \
     "release/<version>/BarFold-<version>.zip" \
     "release/<version>/appcast.xml" \
     --title "BarFold <version>" \
     --notes-file "release/<version>/BarFold-<version>.md"
   ```

   `SUFeedURL` 使用 `releases/latest/download/appcast.xml`，因此每次最新 Release 都必须带 `appcast.xml`。

6. 在另一台 Mac 上验证：
   - 安装旧版 vN；
   - 打开新版检查更新；
   - 升级后确认 `codesign -dv` 的 Authority 仍是 `BarFold Code Signing`；
   - 登录项、TCC 授权未被重置；
   - `barfold doctor` 没有 fail。

## 本地 dry-run

没有发布仓库时，只能验证：

- 固定身份签名链（`signing-check.sh`）；
- appcast 生成与 EdDSA 签名（`release.sh --signed`）；
- app 本体启动与 CLI/e2e。

Sparkle 的真实下载/替换链路需要 HTTPS feed 和已发布的 zip。不要用 `file://` 或明文 HTTP 做“通过”结论；这只能验证解析，不能验证分发。

## 开发包

```bash
scripts/release.sh --adhoc
```

只生成 zip，不生成 appcast；`SUPublicEDKey` 为空时 `UpdateController` 不启动 Sparkle，菜单里的“检查更新”会明确提示未配置。这是有意的 fail-soft，不是缺陷。

## 回滚

- Sparkle 的 `appcast.xml` 只保留最新版本；回滚时重新发布旧版本 zip 和对应 appcast，并把 `version.txt` 回退。
- 不要删除旧 Release 的 zip，否则已安装客户端的更新检查会 404。
- 证书不随版本回滚；身份永远保持同一张。
