# 实施状态

更新时间：2026-07-14

| 阶段 | 状态 | 结果 | 验证 |
|---|---|---|---|
| Phase 0 环境与能力矩阵 | 完成 | 环境命令、稳定/实验 schema、脱敏真实探针、能力矩阵 | 探针全部核心读取成功；items 实验调用失败并记录 |
| Phase 1 探针与 JSON-RPC | 部分完成 | actor 进程、JSONL、request ID、timeout、未知事件容忍 | Swift 6.3.3 编译通过；重连协调仅有单任务入口 |
| Phase 2 额度与线程 | 完成 | 真实 rate limits/usage/thread payload 映射、当前 7D 主窗口、重置次数、daily 聚合、空状态 | fixture、未知字段与共享快照测试通过 |
| Phase 3 刘海与 NSPanel | 部分完成 | `safeAreaInsets`、auxiliary top areas、屏幕通知、顶部 fallback、透明 NSPanel | 屏幕级校准设置 UI 待完成 |
| Phase 4 交互 | 完成 | 点击展开、原生 hover tracking、延迟收起、外部点击、Escape、key window、动画、右键菜单 | 编译与回归测试通过，仍需不同机型视觉 QA |
| Phase 5 token/子代理 | 部分完成 | 类型区分、去重图、部分合计语义 | 实机无 token event/子代理样本，UI 诚实降级 |
| Phase 6 设置/登录项/诊断 | 部分完成 | Codex 文件选择/检测/版本、首次启动登录项邀请、SMAppService 状态、脱敏诊断、Mock 模式 | 日志文件导出与完整外观设置待完成 |
| Phase 7 Widget/测试/分发 | 部分完成 | Liquid Glass 桌面组件、App Group 原子快照、正式 Xcode app + appex 工程、fixture、分发决策 | SwiftPM 测试与 Xcode 无签名构建通过；Developer ID 签名/公证待完成 |

## 构建验证

- Xcode 26.6（17F113），Swift 6.3.3。
- `swift test --disable-sandbox`：覆盖协议解码、额度选择、共享快照与既有核心逻辑。
- `xcodebuild -project Haloscope.xcodeproj -scheme Haloscope CODE_SIGNING_ALLOWED=NO build`：主应用、WidgetKit extension 与嵌入包装通过。
- 正式本机运行需要在 Xcode 为两个 target 选择同一个 Team，并启用 `group.com.lamluo.haloscope` App Group；无签名身份只能做构建验证，系统不会加载未签名小组件。

## 不会伪装为完成

Desktop 当前选择态、非活跃历史 token、实时 context、完整子代理 token 都没有足够实机证据；对应 UI 必须保持不可用/部分数据提示。
