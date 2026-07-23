# Haloscope

[English](README.md) | 简体中文

[![CI](https://github.com/HaochengLuo/Haloscope/actions/workflows/ci.yml/badge.svg)](https://github.com/HaochengLuo/Haloscope/actions/workflows/ci.yml)

原生 SwiftUI + AppKit `NSPanel` 的 Codex 状态监控器，包含刘海状态面板与 macOS 桌面小组件，部署目标 macOS 14。数据来自独立的 `codex app-server --stdio`，不读取 Codex Desktop 私有数据库，不抓取 UI，不估算 token。

> Haloscope 是非官方开源项目，与 OpenAI 不存在隶属或背书关系。Codex 名称及相关商标归其权利人所有。

## 界面预览

<p align="center">
  <img src="docs/images/haloscope-widget-zh-cn-v2.png" width="280" alt="Haloscope 桌面小组件，显示 Codex 七天剩余额度与重置倒计时">
</p>

<p align="center"><em>Liquid Glass 桌面小组件</em></p>

<p align="center">
  <img src="docs/images/haloscope-notch-compact-zh-cn-v2.png" width="600" alt="Haloscope 紧凑刘海状态，显示最近活动与七天剩余额度">
</p>

<p align="center"><em>紧凑刘海状态</em></p>

<table>
  <tr>
    <td width="50%" valign="top"><img src="docs/images/haloscope-panel-overview-zh-cn-v2.png" alt="Haloscope 刘海面板，显示账户额度、可用重置、当前任务与最近对话"></td>
    <td width="50%" valign="top"><img src="docs/images/haloscope-display-settings-zh-cn-v2.png" alt="Haloscope 显示设置，包含 Liquid Glass 外观、内容卡片透明度与面板文字颜色"></td>
  </tr>
  <tr>
    <td align="center"><em>账户与任务概览</em></td>
    <td align="center"><em>Liquid Glass 显示设置</em></td>
  </tr>
</table>

## 当前状态

界面支持跟随系统语言，或在英文与简体中文之间实时切换。桌面小组件显示当前 7D 剩余额度、重置倒计时与可用重置次数；桌面小组件和刘海面板均采用 Liquid Glass 设计。

## 构建与运行

> 当前公开 Beta 仅提供源代码，不包含预编译的 `.app` 或 `.dmg`。

要求：

- 运行 Haloscope 需要 macOS 14 或更高版本
- 编译当前 Liquid Glass 源码需要 Xcode 26 或更高版本，以及该 Xcode 版本所支持的 macOS
- 已安装并登录 Codex CLI；请先确认 `codex --version` 能够成功执行
- 本地签名构建需要在 Xcode 中添加 Apple Account

个人本地编译和运行不要求付费加入 Apple Developer Program。可以使用 Xcode 的[免费 Personal Team](https://developer.apple.com/support/compare-memberships/)，但这种构建不能用于再次分发，并且可能需要定期重新配置签名。

### 从 Xcode 运行

1. 下载[仅源码 Beta](https://github.com/HaochengLuo/Haloscope/releases/tag/v0.2.0-beta.2)，或克隆仓库：

   ```bash
   git clone https://github.com/HaochengLuo/Haloscope.git
   cd Haloscope
   open Haloscope.xcodeproj
   ```

2. 在 **Xcode → Settings → Accounts** 中添加 Apple Account。
3. 为 Haloscope 和 HaloscopeWidget 两个 target 启用自动签名，并选择同一个 Team。本地测试可以使用免费的 Personal Team。
4. 为两个 target 配置属于该 Team 的唯一标识，并保证 App Group 与 Keychain 后缀完全一致：

   - 主应用 Bundle ID：`com.example.haloscope`
   - Widget Bundle ID：`com.example.haloscope.widget`
   - `HALOSCOPE_APP_GROUP_IDENTIFIER`：`TEAM_ID.com.example.haloscope`
   - `HALOSCOPE_KEYCHAIN_GROUP_SUFFIX`：`com.example.haloscope.shared`

   Bundle ID 在 **Signing & Capabilities** 中设置；两个 `HALOSCOPE_...` 值需要在两个 target 的 **Build Settings** 中设置。请将 `TEAM_ID` 和 `com.example` 替换成自己的值。App Group 使用 Apple 的 [macOS Team ID 前缀格式](https://developer.apple.com/documentation/xcode/accessing-app-group-containers)；Keychain Access Group 的签名前缀由系统自动添加。
5. 选择 Haloscope scheme 和 **My Mac**，然后运行。
6. 在桌面右键“编辑小组件”，搜索 “Haloscope”，添加小号组件。

应用按自定义路径、`~/.local/bin`、Homebrew、系统路径、login shell 的顺序寻找 `codex`。

### 命令行检查与本地打包

运行测试：

```bash
swift test --disable-sandbox
```

没有签名身份时，可验证完整 app/appex 打包：

```bash
UNSIGNED=1 scripts/build_app.sh
```

未签名的小组件不能注册到系统。本地签名构建可通过环境变量提供 Team 和唯一标识，避免将个人签名信息保存进仓库：

```bash
HALOSCOPE_DEVELOPMENT_TEAM=TEAM_ID \
HALOSCOPE_APP_BUNDLE_IDENTIFIER=com.example.haloscope \
HALOSCOPE_WIDGET_BUNDLE_IDENTIFIER=com.example.haloscope.widget \
HALOSCOPE_APP_GROUP_IDENTIFIER=TEAM_ID.com.example.haloscope \
HALOSCOPE_KEYCHAIN_GROUP_SUFFIX=com.example.haloscope.shared \
scripts/build_app.sh
```

构建结果位于 `dist/Haloscope.zip`。Personal Team 生成的 ZIP 只适合在自己的 Mac 上测试：它没有 Developer ID 签名和公证，不应转发给其他用户；其他用户应使用自己的签名标识从源码编译。

### 维护者发行演练

可以在不签名或公证的情况下验证公开发行包和 DMG 布局：

```bash
scripts/release_app.sh --unsigned --tag v0.2.0-beta.2
```

无签名产物会明确带有 `-unsigned` 后缀，不能用于公开分发。Developer ID
发行条件和 GitHub Actions 配置详见[分发说明](docs/DISTRIBUTION.md)。

协议 Schema 不纳入 Git 历史，需要排查协议变化时运行 `scripts/generate_protocol_schemas.sh` 在本地重新生成。

## 权限与隐私

MVP 建议非 Sandbox 的 Developer ID 分发，因为需要启动用户的 Codex CLI 并访问其正常状态目录。应用不需要 Accessibility、屏幕录制、浏览器 Cookie 或 ChatGPT 凭证权限。详见 [分发说明](docs/DISTRIBUTION.md)。

## 已知限制

- App Server 没有暴露 Codex Desktop 当前选中线程；界面必须显示手动绑定、自动识别、推断或不可用。
- 2026-07-14 的 Codex CLI 0.144.1 实测仅返回 10080 分钟（7D）主额度；界面不再显示已取消的 5H 额度。
- `account/usage/read` 是自然日 bucket，“24 小时”只能表述为最近可用日。
- 本次探针没有活动线程，未取得实时 token/context notification 实例；不显示推测数字。
- 当前实现已可编译并通过测试；Developer ID 发行流程已经实现，但真正发布仍需要维护者的签名证书和 Apple 公证凭据。

## 故障排除

- “未找到 codex”：在设置中选择可执行文件，并确认 `codex --version` 可运行。
- App Server 失败：查看脱敏连接错误；不要复制认证响应。
- Swift/SDK mismatch：安装完整 Xcode并切换 `xcode-select`，确保 `xcrun swift --version` 与 SDK build 匹配。
- 登录项 requiresApproval：在“系统设置 → 通用 → 登录项”批准。

协议证据见 [能力矩阵](docs/CAPABILITY_MATRIX.md) 与 [协议记录](docs/CODEX_PROTOCOL_NOTES.md)。

## License

[MIT](LICENSE)
