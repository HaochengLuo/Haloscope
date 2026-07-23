# 分发决策

MVP 采用 Developer ID 直接分发，不面向 Mac App Store。原因是应用需要启动用户选择的 `codex app-server` 子进程并通过管道通信；App Sandbox 对任意用户可执行文件与其 `~/.codex` 状态访问不适合此架构。

- 签名：Developer ID Application，所有嵌套代码统一签名。
- 工程：打开 `Haloscope.xcodeproj`，主应用与 Widget extension 必须选择同一个 Team，并共同使用属于该 Team 的 App Group 与 Keychain Group。仓库不保存个人 Team ID；Xcode Automatic Signing 用于本机开发安装。
- Hardened Runtime：开启；发布前验证子进程启动与管道行为。
- 公证：`notarytool submit --wait`，随后 staple 并用 Gatekeeper 验证。
- 开发构建：`scripts/build_app.sh` 在系统临时目录完成签名与严格校验，再生成 `dist/Haloscope.zip`，避免 Documents 的 File Provider 元数据污染嵌套 Widget 签名。
- 发行构建：`scripts/release_app.sh` 使用 Developer ID 归档并导出主应用与 Widget，验证两者的 App Group，分别公证应用 ZIP 与最终 DMG，staple 后生成 GitHub Release 资产和 SHA-256 校验文件。
- 本地签名：通过 `HALOSCOPE_DEVELOPMENT_TEAM` 环境变量传入 Team ID；分叉项目还应覆盖 `HALOSCOPE_APP_GROUP_IDENTIFIER` 与 `HALOSCOPE_KEYCHAIN_GROUP_SUFFIX`。
- App Sandbox：MVP 关闭；不借此读取凭证、Cookie 或 Desktop 私有数据库。
- 登录项：使用 `SMAppService.mainApp`，正确展示 enabled/notRegistered/requiresApproval/notFound。
- 隐私：仅访问用户指定的 Codex CLI；日志不记录消息正文、文件内容、认证响应和秘密环境变量。
- 升级：签名的 Sparkle 等第三方依赖尚未引入；初版采用签名下载替换，后续评估官方更新框架并单独记录资源/签名影响。

## Beta 发行

首个公开测试版使用标签 `v0.2.0-beta.1`。应用内部
`CFBundleShortVersionString` 保持 `0.2.0`，GitHub 标签和资产名负责表示
Beta 通道。

本地发行需要安装 `Developer ID Application` 证书，并配置：

```bash
export HALOSCOPE_DEVELOPMENT_TEAM="YOUR_TEAM_ID"
export HALOSCOPE_APP_GROUP_IDENTIFIER="YOUR_REGISTERED_APP_GROUP"
export HALOSCOPE_NOTARY_KEY_PATH="/absolute/path/to/AuthKey_KEYID.p8"
export HALOSCOPE_NOTARY_KEY_ID="KEY_ID"
export HALOSCOPE_NOTARY_ISSUER_ID="ISSUER_ID"
scripts/release_app.sh --tag v0.2.0-beta.1
```

也可以先使用 `scripts/release_app.sh --unsigned --tag v0.2.0-beta.1`
验证构建与 DMG 布局。无签名资产带有 `-unsigned` 后缀，不能公开发行。

GitHub Actions 的 `release` Environment 应开启 required reviewer，发行标签必须指向
`main` 中已有的提交。该 Environment 需要以下 Repository Variables：

- `APPLE_TEAM_ID`
- `HALOSCOPE_APP_GROUP_IDENTIFIER`
- `HALOSCOPE_KEYCHAIN_GROUP_SUFFIX`

以及以下 Secrets：

- `DEVELOPER_ID_APPLICATION_P12`
- `DEVELOPER_ID_APPLICATION_PASSWORD`
- `KEYCHAIN_PASSWORD`
- `APPLE_API_KEY_P8`
- `APPLE_API_KEY_ID`
- `APPLE_API_KEY_ISSUER_ID`

P12 与 P8 使用 base64 编码后保存。推送已存在的 `v*` 标签会触发签名、
公证和 GitHub Release；含有连字符的版本会自动标记为 pre-release。
