import Foundation

enum ResolvedAppLanguage: String, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
}

enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> ResolvedAppLanguage {
        switch self {
        case .english:
            return .english
        case .simplifiedChinese:
            return .simplifiedChinese
        case .system:
            let preferred = preferredLanguages.first?.lowercased() ?? "en"
            return preferred.hasPrefix("zh") ? .simplifiedChinese : .english
        }
    }

    var locale: Locale {
        switch resolved() {
        case .english: Locale(identifier:"en_US")
        case .simplifiedChinese: Locale(identifier:"zh_Hans_CN")
        }
    }

    func displayName(in interfaceLanguage: AppLanguage) -> String {
        switch self {
        case .system: L10n.text("language.system",language:interfaceLanguage)
        case .simplifiedChinese: L10n.text("language.simplified_chinese",language:interfaceLanguage)
        case .english: L10n.text("language.english",language:interfaceLanguage)
        }
    }
}

enum SharedLanguagePreference {
    static let defaultsKey = "appLanguage"

    static func read(from defaults: UserDefaults) -> AppLanguage {
        defaults.string(forKey:defaultsKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    static func widgetDefaults() -> UserDefaults? {
        UserDefaults(suiteName:WidgetQuotaSnapshotStore.configuredAppGroupIdentifier)
    }

    static func widgetLanguage() -> AppLanguage {
        guard let defaults = widgetDefaults() else { return .system }
        return read(from:defaults)
    }

    static func writeToWidget(_ language: AppLanguage, defaults: UserDefaults? = widgetDefaults()) {
        defaults?.set(language.rawValue,forKey:defaultsKey)
    }
}

enum L10n {
    private struct Translation: Sendable {
        let english: String
        let simplifiedChinese: String
    }

    static func text(_ key: String, language: AppLanguage) -> String {
        guard let translation = translations[key] else { return key }
        return switch language.resolved() {
        case .english: translation.english
        case .simplifiedChinese: translation.simplifiedChinese
        }
    }

    static func format(_ key: String, language: AppLanguage, _ arguments: CVarArg...) -> String {
        String(format:text(key,language:language),locale:language.locale,arguments:arguments)
    }

    private static let translations: [String:Translation] = [
        "language.system": .init(english:"Follow System",simplifiedChinese:"跟随系统"),
        "language.simplified_chinese": .init(english:"Simplified Chinese",simplifiedChinese:"简体中文"),
        "language.english": .init(english:"English",simplifiedChinese:"English"),

        "app.settings_title": .init(english:"Haloscope Settings",simplifiedChinese:"Haloscope 设置"),
        "onboarding.title": .init(english:"Keep the Codex widget up to date?",simplifiedChinese:"让 Codex 小组件保持最新？"),
        "onboarding.message": .init(english:"Enable the login item so Haloscope can launch at sign-in and keep the desktop widget updated. You can change this later in Settings.",simplifiedChinese:"开启登录项后，Haloscope 会在登录时启动并更新桌面小组件。你也可以稍后在设置中更改。"),
        "action.enable": .init(english:"Enable",simplifiedChinese:"开启"),
        "action.later": .init(english:"Later",simplifiedChinese:"稍后"),

        "settings.tab.general": .init(english:"General",simplifiedChinese:"常规"),
        "settings.language": .init(english:"Language",simplifiedChinese:"语言"),
        "settings.collapse_outside": .init(english:"Collapse when clicking outside",simplifiedChinese:"点击外部收起"),
        "settings.launch_login": .init(english:"Launch at Login",simplifiedChinese:"开机自启"),
        "settings.login_status": .init(english:"Login item status: %@",simplifiedChinese:"登录项状态：%@"),
        "settings.tab.codex": .init(english:"Codex",simplifiedChinese:"Codex 连接"),
        "settings.codex_path": .init(english:"Codex path",simplifiedChinese:"Codex 路径"),
        "action.choose": .init(english:"Choose…",simplifiedChinese:"选择…"),
        "action.choose_codex": .init(english:"Choose Codex",simplifiedChinese:"选择 Codex"),
        "action.detect_codex": .init(english:"Detect Codex",simplifiedChinese:"检测 Codex"),
        "action.test_connection": .init(english:"Test Connection",simplifiedChinese:"测试连接"),
        "settings.version": .init(english:"Version: %@",simplifiedChinese:"版本：%@"),
        "settings.experimental": .init(english:"Allow experimental APIs",simplifiedChinese:"允许实验接口"),
        "settings.mock": .init(english:"Mock preview mode",simplifiedChinese:"Mock 预览模式"),
        "settings.binding": .init(english:"Thread binding",simplifiedChinese:"线程绑定策略"),
        "settings.tab.display": .init(english:"Displays",simplifiedChinese:"刘海与显示器"),
        "settings.display.detect": .init(english:"Automatically detects safeAreaInsets and the top auxiliary areas.",simplifiedChinese:"自动检测 safeAreaInsets 与顶部辅助区域"),
        "settings.display.fallback": .init(english:"Uses a top capsule on displays without a physical notch.",simplifiedChinese:"无物理刘海时使用顶部胶囊"),
        "settings.tab.diagnostics": .init(english:"Diagnostics",simplifiedChinese:"诊断"),
        "settings.diagnostics.privacy": .init(english:"Logs are redacted by default and never include message bodies, file contents, or authentication data.",simplifiedChinese:"日志默认脱敏，不记录消息正文、文件内容或认证数据"),
        "action.copy_diagnostics": .init(english:"Copy Diagnostics",simplifiedChinese:"复制诊断信息"),
        "action.reset_settings": .init(english:"Reset Settings",simplifiedChinese:"重置设置"),

        "connection_check.not_checked": .init(english:"Not checked",simplifiedChinese:"尚未检测"),
        "connection_check.not_found": .init(english:"Codex not found",simplifiedChinese:"未找到 Codex"),
        "connection_check.cannot_execute": .init(english:"Unable to run Codex",simplifiedChinese:"无法执行"),
        "connection_check.detected": .init(english:"Detected",simplifiedChinese:"检测成功"),
        "connection_check.connecting": .init(english:"Connecting…",simplifiedChinese:"正在连接…"),
        "connection_check.connected": .init(english:"App Server connected",simplifiedChinese:"App Server 连接成功"),
        "connection_check.login_error": .init(english:"Login item error: %@",simplifiedChinese:"登录项错误：%@"),
        "connection_check.failed": .init(english:"Connection failed: %@",simplifiedChinese:"连接失败：%@"),

        "login.enabled": .init(english:"Enabled",simplifiedChinese:"已启用"),
        "login.not_registered": .init(english:"Not enabled",simplifiedChinese:"未启用"),
        "login.requires_approval": .init(english:"Requires approval",simplifiedChinese:"需要批准"),
        "login.not_found": .init(english:"Not found",simplifiedChinese:"未找到"),
        "login.unavailable": .init(english:"Unavailable",simplifiedChinese:"不可用"),

        "binding.manual": .init(english:"Manual",simplifiedChinese:"手动绑定"),
        "binding.running": .init(english:"Auto-detect",simplifiedChinese:"自动识别"),
        "binding.inferred": .init(english:"Inferred",simplifiedChinese:"推断"),
        "binding.unavailable": .init(english:"Unavailable",simplifiedChinese:"数据不可用"),

        "context.open_codex": .init(english:"Open Codex Desktop",simplifiedChinese:"打开 Codex Desktop"),
        "context.refresh": .init(english:"Refresh Now",simplifiedChinese:"立即刷新"),
        "context.expand": .init(english:"Expand Details",simplifiedChinese:"展开详情"),
        "context.settings": .init(english:"Settings",simplifiedChinese:"设置"),
        "context.reconnect": .init(english:"Reconnect Codex",simplifiedChinese:"重新连接 Codex"),
        "context.quit": .init(english:"Quit Haloscope",simplifiedChinese:"退出 Haloscope"),

        "account.status": .init(english:"Account status",simplifiedChinese:"账户状态"),
        "plan.format": .init(english:"%@ plan",simplifiedChinese:"%@ 方案"),
        "quota.section": .init(english:"Account Quota",simplifiedChinese:"账户额度"),
        "quota.unavailable_7d": .init(english:"The current account did not return a 7-day quota.",simplifiedChinese:"当前账户未返回 7 天额度"),
        "quota.available_resets": .init(english:"Available resets",simplifiedChinese:"可用重置"),
        "task.current": .init(english:"Current Task",simplifiedChinese:"当前任务"),
        "task.recent_activity": .init(english:"Recent thread activity · Inferred",simplifiedChinese:"最近有线程活动 · 推断"),
        "task.no_activity": .init(english:"No activity",simplifiedChinese:"无活动"),
        "task.no_recent_thread": .init(english:"No recent thread",simplifiedChinese:"没有最近线程"),
        "threads.recent": .init(english:"Recent Conversations",simplifiedChinese:"最近对话"),
        "threads.empty": .init(english:"No thread data yet",simplifiedChinese:"暂无线程数据"),
        "threads.untitled": .init(english:"Untitled thread",simplifiedChinese:"无标题线程"),
        "usage.section": .init(english:"Token Usage",simplifiedChinese:"Token 使用"),
        "usage.latest_day": .init(english:"Latest day",simplifiedChinese:"最近统计日"),
        "usage.seven_days": .init(english:"7 days",simplifiedChinese:"7 天"),
        "usage.thirty_days": .init(english:"30 days",simplifiedChinese:"30 天"),
        "usage.unavailable": .init(english:"Account usage data is unavailable.",simplifiedChinese:"账户用量数据不可用"),
        "stats.section": .init(english:"Codex Statistics",simplifiedChinese:"Codex 统计"),
        "stats.lifetime": .init(english:"Lifetime",simplifiedChinese:"累计 Token"),
        "stats.peak": .init(english:"Peak",simplifiedChinese:"峰值 Token"),
        "stats.longest_task": .init(english:"Longest Task",simplifiedChinese:"最长任务"),
        "stats.current_streak": .init(english:"Current Streak",simplifiedChinese:"当前连续"),
        "stats.longest_streak": .init(english:"Longest Streak",simplifiedChinese:"最长连续"),
        "quota.reset_time": .init(english:"Reset time",simplifiedChinese:"重置时间"),
        "quota.updated": .init(english:"Quota updated: %@ · Refreshes every 60 seconds",simplifiedChinese:"额度更新：%@ · 每 60 秒刷新"),
        "rate.seven_day": .init(english:"7-day quota",simplifiedChinese:"7 天额度"),
        "rate.minutes": .init(english:"%d-minute quota",simplifiedChinese:"%d 分钟额度"),
        "rate.account": .init(english:"Account quota",simplifiedChinese:"账户额度"),
        "connection.persistent": .init(english:"Persistent thread · Refreshes every 5 seconds",simplifiedChinese:"持久化线程 · 每 5 秒刷新"),
        "connection.disconnected": .init(english:"Disconnected",simplifiedChinese:"已断开"),
        "connection.connecting": .init(english:"Connecting",simplifiedChinese:"正在连接"),
        "connection.connected": .init(english:"Connected",simplifiedChinese:"已连接"),
        "connection.error": .init(english:"Connection error",simplifiedChinese:"连接错误"),
        "status.recent_activity": .init(english:"Active · Inferred",simplifiedChinese:"最近活动 · 推断"),
        "status.no_activity": .init(english:"No activity",simplifiedChinese:"无活动"),
        "duration.hours_minutes": .init(english:"%dh %dm",simplifiedChinese:"%d时%d分"),
        "duration.minutes": .init(english:"%d min",simplifiedChinese:"%d 分"),
        "duration.day": .init(english:"%d day",simplifiedChinese:"%d 天"),
        "duration.days": .init(english:"%d days",simplifiedChinese:"%d 天"),
        "mock.running": .init(english:"Mock: Running task",simplifiedChinese:"Mock：正在执行的任务"),
        "mock.history": .init(english:"Mock: Previous conversation",simplifiedChinese:"Mock：历史对话"),

        "error.codex_not_found": .init(english:"Codex executable not found",simplifiedChinese:"未找到 codex 可执行文件"),
        "error.server_connection": .init(english:"Codex App Server connection failed",simplifiedChinese:"Codex App Server 连接失败"),
        "error.quota": .init(english:"Quota: %@",simplifiedChinese:"额度：%@"),
        "error.thread_refresh": .init(english:"Thread refresh failed: %@",simplifiedChinese:"线程刷新失败：%@"),
        "error.server_exited": .init(english:"App Server exited unexpectedly. Reconnecting…",simplifiedChinese:"App Server 意外退出，正在重新连接"),
        "error.recovering": .init(english:"Connection temporarily interrupted. Recovering automatically…",simplifiedChinese:"连接暂时中断，正在自动恢复…"),
        "error.quota_unavailable": .init(english:"The current account did not return a Codex quota",simplifiedChinese:"当前账户未返回 Codex 额度"),
        "list.separator": .init(english:"; ",simplifiedChinese:"；"),

        "rpc.timeout": .init(english:"Request timed out",simplifiedChinese:"请求超时"),
        "rpc.disconnected": .init(english:"App Server disconnected",simplifiedChinese:"App Server 已断开"),
        "rpc.malformed": .init(english:"App Server returned an unreadable response",simplifiedChinese:"App Server 返回了无法解析的响应"),
        "rpc.server_code": .init(english:"App Server request failed (error code %d)",simplifiedChinese:"App Server 请求失败（错误码 %d）"),
        "rpc.server": .init(english:"App Server request failed",simplifiedChinese:"App Server 请求失败"),
        "store.app_group": .init(english:"Cannot access shared container %@. Confirm that the host app and widget use the same signing team.",simplifiedChinese:"无法访问共享容器 %@。请确认宿主和小组件使用同一签名团队。"),
        "store.keychain": .init(english:"Cannot access the shared keychain (OSStatus %d).",simplifiedChinese:"无法访问共享钥匙串（OSStatus %d）。"),

        "widget.description": .init(english:"Codex weekly usage, reset time, and available resets.",simplifiedChinese:"显示 Codex 七天剩余用量、重置时间和可用重置次数。"),
        "widget.left": .init(english:"left",simplifiedChinese:"剩余"),
        "widget.name": .init(english:"Codex Weekly Usage",simplifiedChinese:"Codex 七天用量"),
        "widget.open_app": .init(english:"Open Haloscope",simplifiedChinese:"打开 Haloscope"),
        "widget.reset_count": .init(english:"%d resets available",simplifiedChinese:"可用重置次数：%d"),
        "widget.reset_count_unavailable": .init(english:"Reset count unavailable",simplifiedChinese:"重置次数不可用"),
        "widget.reset_unavailable": .init(english:"Reset time unavailable",simplifiedChinese:"重置时间不可用"),
        "widget.resets_in": .init(english:"Resets in %@",simplifiedChinese:"距重置 %@"),
        "widget.duration.days_hours": .init(english:"%dd %dh",simplifiedChinese:"%d天%d小时"),
        "widget.duration.days": .init(english:"%dd",simplifiedChinese:"%d天"),
        "widget.duration.hours_minutes": .init(english:"%dh %dm",simplifiedChinese:"%d小时%d分钟"),
        "widget.duration.hours": .init(english:"%dh",simplifiedChinese:"%d小时"),
        "widget.duration.minutes": .init(english:"%dm",simplifiedChinese:"%d分钟"),
        "widget.signing_required": .init(english:"Finish signing setup",simplifiedChinese:"请完成签名设置"),
        "widget.stale": .init(english:"Data may be stale",simplifiedChinese:"数据可能已过期"),
        "widget.waiting_refresh": .init(english:"Waiting for refresh",simplifiedChinese:"等待刷新")
    ]
}

extension Notification.Name {
    static let haloscopeLanguageDidChange = Notification.Name("Haloscope.LanguageDidChange")
}
