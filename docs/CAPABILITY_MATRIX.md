# Codex App Server 能力矩阵

验证环境：macOS 26.5.1 arm64；Codex CLI 0.144.1。官方依据优先采用该版本自身生成的稳定/实验 JSON Schema；运行 `scripts/generate_protocol_schemas.sh` 可在被 Git 忽略的 `docs/protocol/` 中本地重建。实测使用脱敏 stdio JSONL 探针（`docs/probe/`）。

官方参考：OpenAI [Codex App Server](https://developers.openai.com/codex/app-server/)；Apple [NSScreen.safeAreaInsets](https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets)、[auxiliaryTopLeftArea](https://developer.apple.com/documentation/appkit/nsscreen/auxiliarytopleftarea)、[SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)。

| 需求 | 官方数据源 | 实际测试结果 | 数据精度 | 稳定 API | 实验 API | 已知限制 | 降级方案 |
|---|---|---|---|---|---|---|---|
| 账户与计划 | `account/read` | 成功，返回 chatgpt/plus | 服务端原值 | 是 | 否 | 不保存账户身份 | 显示未登录/不可用 |
| 额度窗口 | `account/rateLimits/read` | 2026-07-14 实测仅返回 10080 分钟主窗口 | 服务端百分比/时间戳 | 是 | 否 | 5H 已取消，不再假设存在 secondary | 优先 `codex.primary`，缺失即明确提示 |
| 可用重置次数 | `account/rateLimits/read` 的 `rateLimitResetCredits.availableCount` | 成功，实测为 2 | 服务端整数 | 是 | 否 | 仅展示，不触发消费操作 | 字段缺失显示不可用 |
| 账户使用 | `account/usage/read` | 成功，9 个 daily bucket | 自然日粒度 | 是 | 否 | 不是滚动 24 小时 | 标为“最近可用日/按日统计” |
| Desktop 线程列表 | `thread/list` | 成功，列出 9 个既有线程 | 持久化线程元数据 | 是 | 否 | 只能证明可列出，不能证明 UI 选择态 | 手动/最近活跃/项目目录绑定 |
| 当前选中线程 | 无公开字段 | 未验证可得 | 不可用 | 否 | 否 | App Server 不暴露 Desktop 选择态 | 不称为当前选中，显示绑定方式 |
| 正在执行线程 | `thread/loaded/list` + status events | 本次返回 0 | 实时状态（有事件时） | 是 | 否 | 探针时没有 loaded thread | 当前执行优先，否则最近活跃推断 |
| 线程详情 | `thread/read` | 成功 | 已持久化 turn/item 元数据 | 是 | 否 | 不采集消息正文 | 空状态/字段不可用 |
| 历史累计 token | token usage event/turn 数据 | 非活跃样本未返回 token 字段 | 不可用 | 部分 | 否 | 不允许字符数估算 | 明示“历史 token 数据未由当前接口提供” |
| 输入/缓存/输出/推理 token | `thread/tokenUsage/updated` | schema 支持；本次无活跃事件 | 事件原值 | 是 | 否 | 仅事件发生时可验证 | 分字段显示不可用，不合并猜测 |
| 上下文窗口/剩余量 | token usage schema | schema 含相关 usage 模型；本次无事件 | 事件原值 | 是 | 否 | 未获实机通知 | 不显示精确百分比 |
| 父子线程 | `parentThreadId` | 稳定 schema 有字段；样本为 null | ID 关系 | 是 | 否 | 样本未形成父子关系 | 可识别时建图，否则“数据不可用” |
| 后代筛选 | `ancestorThreadId` | schema 存在，未取得有关系样本 | ID 关系 | 否 | 是 | 需 experimentalApi | 独立开关，稳定客户端不依赖 |
| 分页 turns | `thread/turns/list` | 实测成功 | 已持久化数据 | 否 | 是 | 不读取正文 | 默认关闭 |
| 分页 items | `thread/items/list` | 当前参数调用失败 | 不可用 | 否 | 是 | 需按实际 error/schema 再适配 | 使用 `thread/read` 元数据 |
| 子代理 collabToolCall | item schema/事件 | 未取得真实样本 | 未验证 | 部分 | 部分 | 不能据字段存在宣称可用 | 子代理 token 标部分数据 |
| Desktop 当前运行任务 | status events | 本次无事件 | 未验证 | 是 | 否 | 探针期间没有任务 | 空闲/无法确认，不伪报 |

结论：当前 7D 账户额度、重置次数、自然日用量与持久化线程列表可可靠实现；Desktop 选择态不可得；历史 token、实时 token/context 和子代理需在真实事件样本出现后才能宣称完整可用。
