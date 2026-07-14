# Codex 0.144.1 协议记录

- 传输：stdin/stdout，每行一个 JSON-RPC 2.0 对象。OpenAI 官方说明 wire 上可省略 `jsonrpc: "2.0"`；本机 0.144.1 同时接受带该字段的消息。
- 初始化：`initialize` 的 `clientInfo.name/version` 必填，随后发送 `initialized` notification。
- `account/rateLimits/read`：返回 `rateLimits`、`rateLimitsByLimitId` 与 `rateLimitResetCredits`。2026-07-14 本机复测的 `codex` limit 仅有 10080 分钟 primary 窗口，`resetsAt` 为 Unix 秒，`availableCount` 为可用重置次数；此前 300 分钟样本保留为历史探针证据，不再驱动当前 UI。
- `account/usage/read`：返回 `summary.lifetimeTokens`、`summary.peakDailyTokens` 和 `dailyUsageBuckets[{startDate,tokens}]`；这是自然日 bucket。
- `thread/list`：返回 `id/sessionId/parentThreadId/preview/createdAt/updatedAt/recencyAt/status/source/name/turns` 等；列表的 turns 为空属协议设计。
- `thread/tokenUsage/updated` 稳定 schema：notification params 包含 `threadId` 与 `tokenUsage`。本次探针没有活动线程，因此未捕获实时实例，应用不得填入推测值。
- 未知 notification 与未知字段必须解码为通用 `JSONValue`，不得断开连接。
- 实验 `thread/turns/list` 成功；`thread/items/list` 当前调用失败，保持 capability 关闭并记录原始 RPC error（脱敏）。
