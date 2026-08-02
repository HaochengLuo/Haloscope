# 分发决策

MVP 采用 Developer ID 直接分发，不面向 Mac App Store。原因是应用需要启动用户选择的 `codex app-server` 子进程并通过管道通信；App Sandbox 对任意用户可执行文件与其 `~/.codex` 状态访问不适合此架构。

- 签名：Developer ID Application，所有嵌套代码统一签名。
- 工程：打开 `Haloscope.xcodeproj`，主应用与 Widget extension 必须选择同一个 Team，并共同使用属于该 Team 的 App Group 与 Keychain Group。仓库不保存个人 Team ID；Xcode Automatic Signing 用于本机开发安装。
- Hardened Runtime：开启；发布前验证子进程启动与管道行为。
- 公证：`notarytool submit --wait`，随后 staple 并用 Gatekeeper 验证。
- 开发构建：`scripts/build_app.sh` 在系统临时目录完成签名与严格校验，再生成 `dist/Haloscope.zip`，避免 Documents 的 File Provider 元数据污染嵌套 Widget 签名。
- 发行构建：`scripts/release_app.sh` 使用 Developer ID 归档并导出主应用与 Widget，验证两者的 App Group，分别公证应用 ZIP 与最终 DMG，staple 后生成 GitHub Release 资产和 SHA-256 校验文件。
- 本地签名：通过 `HALOSCOPE_DEVELOPMENT_TEAM` 环境变量传入 Team ID；分叉项目还应覆盖 `HALOSCOPE_APP_BUNDLE_IDENTIFIER`、`HALOSCOPE_WIDGET_BUNDLE_IDENTIFIER`、`HALOSCOPE_APP_GROUP_IDENTIFIER` 与 `HALOSCOPE_KEYCHAIN_GROUP_SUFFIX`。
- App Sandbox：MVP 关闭；不借此读取凭证、Cookie 或 Desktop 私有数据库。
- 登录项：使用 `SMAppService.mainApp`，正确展示 enabled/notRegistered/requiresApproval/notFound。
- 隐私：仅访问用户指定的 Codex CLI；日志不记录消息正文、文件内容、认证响应和秘密环境变量。
- 升级：签名的 Sparkle 等第三方依赖尚未引入；初版采用签名下载替换，后续评估官方更新框架并单独记录资源/签名影响。

## Beta 发行

当前仅源码测试版使用标签 `v0.2.0-beta.2`。应用内部
`CFBundleShortVersionString` 保持 `0.2.0`，GitHub 标签和资产名负责表示
Beta 通道。

本地发行需要安装 `Developer ID Application` 证书，并配置：

```bash
export HALOSCOPE_DEVELOPMENT_TEAM="YOUR_TEAM_ID"
export HALOSCOPE_APP_GROUP_IDENTIFIER="YOUR_REGISTERED_APP_GROUP"
export HALOSCOPE_NOTARY_KEY_PATH="/absolute/path/to/AuthKey_KEYID.p8"
export HALOSCOPE_NOTARY_KEY_ID="KEY_ID"
export HALOSCOPE_NOTARY_ISSUER_ID="ISSUER_ID"
scripts/release_app.sh --tag v0.2.0-beta.2
```

也可以先使用 `scripts/release_app.sh --unsigned --tag v0.2.0-beta.2`
验证构建与 DMG 布局。无签名资产带有 `-unsigned` 后缀，不能公开发行。

GitHub Actions 的 `release` Environment 应开启 required reviewer，发行标签必须指向
`main` 中已有的提交。该 Environment 需要以下 Repository Variables：

- `HALOSCOPE_ENABLE_SIGNED_RELEASES=true`
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

P12 与 P8 使用 base64 编码后保存。只有
`HALOSCOPE_ENABLE_SIGNED_RELEASES` 明确设为 `true` 时，推送 `v*` 标签才会运行签名、
公证和二进制 GitHub Release 工作流；默认关闭时可安全发布仅源码 Release。含有连字符的版本会自动标记为 pre-release。

## Unsigned Preview 通道

Unsigned Preview 是给技术测试者使用的可选、明确降级的下载通道，不改变
`Haloscope` 主 target 的签名发行路径。它使用独立的 `HaloscopePreview` target、
`Haloscope Preview.app` 产品名和 `com.lamluo.haloscope.preview` Bundle ID，构建为
arm64/x86_64 通用二进制，并通过临时目录中的 `scripts/release_preview.sh` 生成
ZIP、DMG、dSYM（如可用）和 SHA-256 清单。

Preview 不包含 Widget extension，不使用 App Group、共享 Keychain、登录项或
Sparkle，也不提供 Developer ID 信任和公证。DMG 内包含 `README-FIRST.txt`；安装、
校验、升级、卸载和手动 QA 矩阵见 [Unsigned Preview 文档](UNSIGNED_PREVIEW.md)。
不要使用 `scripts/release_app.sh` 的签名发行流程代替 Preview 流程，也不要为
Preview 关闭 Gatekeeper 或自动移除 quarantine。

Preview workflow 仅支持手动 `workflow_dispatch`，要求输入精确的
`PUBLISH UNSIGNED PREVIEW` 确认字符串，检查标签提交包含在 `main` 中，并使用
`preview` Environment 在创建 GitHub pre-release 前等待人工批准。它永远不会将
Preview 标记为 `latest`，也不会读取 Developer ID 或公证秘密。初始任务不添加
Homebrew Cask；即使未来使用 Homebrew，也不能由 Cask 创造 Apple 信任。

可下载 Preview Release 必须包含以下资产：

- `Haloscope-<version>-macos-universal-unsigned.dmg`：Finder 安装包。
- `Haloscope-<version>-macos-universal-unsigned.zip`：备用归档安装包。
- `Haloscope-<version>-SHA256SUMS.txt`：DMG、ZIP 和可用 dSYM 的校验清单。
- `Haloscope-<version>-macos-universal.dSYM.zip`：可选诊断符号。

发布前运行 `scripts/release_preview.sh --tag vX.Y.Z-unsigned-preview.N`，它会在仓库外的临时目录构建、生成 DMG/ZIP/dSYM/校验和，并对最终 DMG 和解压后的 ZIP 再次验证。提交到 `main` 后，通过 Preview workflow 的人工确认、`preview` Environment 审批和 GitHub pre-release 上传完成公开下载；不要把 `dist/` 二进制资产提交进仓库。
