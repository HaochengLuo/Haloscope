# 分发决策

MVP 采用 Developer ID 直接分发，不面向 Mac App Store。原因是应用需要启动用户选择的 `codex app-server` 子进程并通过管道通信；App Sandbox 对任意用户可执行文件与其 `~/.codex` 状态访问不适合此架构。

- 签名：Developer ID Application，所有嵌套代码统一签名。
- 工程：打开 `Haloscope.xcodeproj`，主应用与 Widget extension 必须选择同一个 Team，并共同使用属于该 Team 的 App Group 与 Keychain Group。仓库不保存个人 Team ID；Xcode Automatic Signing 用于本机开发安装。
- Hardened Runtime：开启；发布前验证子进程启动与管道行为。
- 公证：`notarytool submit --wait`，随后 staple 并用 Gatekeeper 验证。
- 构建：`scripts/build_app.sh` 在系统临时目录完成签名与严格校验，再生成 `dist/Haloscope.zip`，避免 Documents 的 File Provider 元数据污染嵌套 Widget 签名。
- 本地签名：通过 `HALOSCOPE_DEVELOPMENT_TEAM` 环境变量传入 Team ID；分叉项目还应覆盖 `HALOSCOPE_APP_GROUP_IDENTIFIER` 与 `HALOSCOPE_KEYCHAIN_GROUP_SUFFIX`。
- App Sandbox：MVP 关闭；不借此读取凭证、Cookie 或 Desktop 私有数据库。
- 登录项：使用 `SMAppService.mainApp`，正确展示 enabled/notRegistered/requiresApproval/notFound。
- 隐私：仅访问用户指定的 Codex CLI；日志不记录消息正文、文件内容、认证响应和秘密环境变量。
- 升级：签名的 Sparkle 等第三方依赖尚未引入；初版采用签名下载替换，后续评估官方更新框架并单独记录资源/签名影响。
