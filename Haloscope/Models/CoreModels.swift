import Foundation

enum ConnectionState: String, Codable, Sendable {
    case disconnected, connecting, connected, error

    func localizedLabel(language: AppLanguage) -> String {
        L10n.text("connection.\(rawValue)",language:language)
    }
}
enum BindingKind: String, Codable, CaseIterable, Sendable {
    case manual, recent, running, project, unavailable
    func localizedLabel(language: AppLanguage) -> String {
        switch self {
        case .manual: L10n.text("binding.manual",language:language)
        case .running: L10n.text("binding.running",language:language)
        case .recent, .project: L10n.text("binding.inferred",language:language)
        case .unavailable: L10n.text("binding.unavailable",language:language)
        }
    }
}
enum ThreadState: String, Codable, Sendable { case notLoaded, idle, active, waiting, error, unknown }
enum RateWindowRole: String, Codable, Sendable { case primary, secondary }

struct TokenUsage: Codable, Equatable, Sendable {
    var input = 0, cachedInput = 0, output = 0, reasoningOutput = 0
    var total: Int { input + cachedInput + output + reasoningOutput }
}
struct ThreadContextSnapshot: Equatable, Sendable {
    var threadID: String; var total: TokenUsage; var last: TokenUsage
    var modelContextWindow: Int?; var updatedAt: Date
}
struct RealtimeThreadStatus: Equatable, Sendable {
    var threadID: String; var type: String; var activeFlags: [String]; var updatedAt: Date
    var displayValue: String { activeFlags.isEmpty ? type : "\(type) · \(activeFlags.joined(separator:", "))" }
}

struct RateWindow: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var limitName: String?
    var usedPercent: Double
    var windowDurationMins: Int?
    var resetsAt: Date?
    var limitID: String? = nil
    var role: RateWindowRole? = nil
    var remainingPercent: Double { min(100, max(0, 100 - usedPercent)) }
    var roundedRemainingPercent: Int { Int(remainingPercent.rounded()) }
    func localizedDisplayName(language: AppLanguage) -> String {
        if let windowDurationMins {
            if abs(windowDurationMins - 10080) <= 60 { return L10n.text("rate.seven_day",language:language) }
            return limitName ?? L10n.format("rate.minutes",language:language,windowDurationMins)
        }
        return limitName ?? L10n.text("rate.account",language:language)
    }
}

struct DailyUsageBucket: Codable, Equatable, Sendable { var startDate: Date; var tokens: Int }
struct UsageSummary: Equatable, Sendable {
    var buckets: [DailyUsageBucket]; var lifetimeTokens: Int?; var peakDailyTokens: Int?
    var longestRunningTurnSec: Int? = nil; var currentStreakDays: Int? = nil; var longestStreakDays: Int? = nil
    func sum(days: Int, now: Date = .now, calendar: Calendar = .current) -> Int {
        let cutoff = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now))!
        return buckets.filter { $0.startDate >= cutoff && $0.startDate <= now }.reduce(0) { $0 + $1.tokens }
    }
}

struct CodexThread: Identifiable, Codable, Equatable, Sendable {
    var id: String; var preview: String?; var cwd: String?; var updatedAt: Date
    var status: ThreadState; var parentThreadId: String?; var tokenUsage: TokenUsage?
}

struct SubagentGraph: Sendable {
    var threads: [CodexThread]
    func descendants(of root: String) -> [CodexThread] {
        var seen = Set<String>(), queue = [root], out: [CodexThread] = []
        while let parent = queue.popLast() {
            for item in threads where item.parentThreadId == parent && seen.insert(item.id).inserted { out.append(item); queue.append(item.id) }
        }
        return out
    }
    func aggregateTokens(of root: String) -> (usage: TokenUsage, complete: Bool) {
        let nodes = threads.filter { $0.id == root } + descendants(of: root)
        var value = TokenUsage(); var complete = true
        for node in nodes { guard let u = node.tokenUsage else { complete = false; continue }; value.input += u.input; value.cachedInput += u.cachedInput; value.output += u.output; value.reasoningOutput += u.reasoningOutput }
        return (value, complete)
    }
}
