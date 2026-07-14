import Foundation

struct AccountSnapshot: Sendable {
    var windows: [RateWindow]
    var planType: String?
    var credits: String?
    var primaryWindow: RateWindow? = nil
    var availableResetCredits: Int? = nil
}

struct CodexPayloadDecoder: Sendable {
    func account(_ value: JSONValue, now: Date = .now) -> AccountSnapshot {
        guard let root = value.objectValue else { return .init(windows:[],planType:nil,credits:nil) }
        var groups: [(String, JSONValue)] = []
        if let byID = root["rateLimitsByLimitId"]?.objectValue {
            groups = byID.map { ($0.key,$0.value) }.sorted { left, right in
                if left.0 == "codex" { return true }
                if right.0 == "codex" { return false }
                return left.0 < right.0
            }
        }
        else if let limits = root["rateLimits"] { groups = [(limits["limitId"]?.stringValue ?? "default",limits)] }
        var windows: [RateWindow] = [], plan: String?, credits: String?, primaryWindow: RateWindow?
        for (fallbackID, raw) in groups {
            let id = raw["limitId"]?.stringValue ?? fallbackID
            let name = raw["limitName"]?.stringValue; plan = plan ?? raw["planType"]?.stringValue
            if let c = raw["credits"]?["balance"]?.stringValue { credits = c }
            for key in ["primary","secondary"] {
                guard let item = raw[key], let used = item["usedPercent"]?.doubleValue else { continue }
                let duration = item["windowDurationMins"]?.intValue
                let reset = item["resetsAt"]?.doubleValue.map(Date.init(timeIntervalSince1970:))
                let role = RateWindowRole(rawValue:key)
                let window = RateWindow(id:"\(id)-\(key)",limitName:name,usedPercent:used,windowDurationMins:duration,resetsAt:reset,limitID:id,role:role)
                windows.append(window)
                if role == .primary, primaryWindow == nil || id == "codex" { primaryWindow = window }
            }
        }
        return .init(
            windows:windows,
            planType:plan,
            credits:credits,
            primaryWindow:primaryWindow,
            availableResetCredits:root["rateLimitResetCredits"]?["availableCount"]?.intValue
        )
    }

    func usage(_ value: JSONValue) -> UsageSummary {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier:.gregorian); formatter.locale = Locale(identifier:"en_US_POSIX"); formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd"
        let buckets = (value["dailyUsageBuckets"]?.arrayValue ?? []).compactMap { item -> DailyUsageBucket? in
            guard let dateString=item["startDate"]?.stringValue, let date=formatter.date(from:dateString), let tokens=item["tokens"]?.intValue else { return nil }
            return .init(startDate:date,tokens:tokens)
        }.sorted { $0.startDate < $1.startDate }
        return .init(buckets:buckets,lifetimeTokens:value["summary"]?["lifetimeTokens"]?.intValue,peakDailyTokens:value["summary"]?["peakDailyTokens"]?.intValue,longestRunningTurnSec:value["summary"]?["longestRunningTurnSec"]?.intValue,currentStreakDays:value["summary"]?["currentStreakDays"]?.intValue,longestStreakDays:value["summary"]?["longestStreakDays"]?.intValue)
    }

    func threads(_ value: JSONValue) -> [CodexThread] {
        (value["data"]?.arrayValue ?? []).compactMap { item in
            guard let id=item["id"]?.stringValue else { return nil }
            let seconds=item["updatedAt"]?.doubleValue ?? item["createdAt"]?.doubleValue ?? 0
            return CodexThread(id:id,preview:item["name"]?.stringValue ?? item["preview"]?.stringValue,cwd:item["cwd"]?.stringValue,updatedAt:Date(timeIntervalSince1970:seconds),status:threadState(item["status"]),parentThreadId:item["parentThreadId"]?.stringValue,tokenUsage:tokenUsage(item["tokenUsage"]))
        }
    }

    func tokenUsage(_ value: JSONValue?) -> TokenUsage? {
        guard let value else { return nil }
        let total = value["total"] ?? value
        let input = total["inputTokens"]?.intValue ?? 0, cached = total["cachedInputTokens"]?.intValue ?? 0
        let output = total["outputTokens"]?.intValue ?? 0, reasoning = total["reasoningOutputTokens"]?.intValue ?? 0
        return (input+cached+output+reasoning) == 0 ? nil : .init(input:input,cachedInput:cached,output:output,reasoningOutput:reasoning)
    }
    func contextNotification(_ value: JSONValue?) -> ThreadContextSnapshot? {
        guard let value, let threadID=value["threadId"]?.stringValue, let usage=value["tokenUsage"], let total=breakdown(usage["total"]), let last=breakdown(usage["last"]) else { return nil }
        return .init(threadID:threadID,total:total,last:last,modelContextWindow:usage["modelContextWindow"]?.intValue,updatedAt:.now)
    }
    func statusNotification(_ value: JSONValue?) -> RealtimeThreadStatus? {
        guard let value, let threadID=value["threadId"]?.stringValue, let type=value["status"]?["type"]?.stringValue else { return nil }
        let flags=(value["status"]?["activeFlags"]?.arrayValue ?? []).compactMap(\.stringValue)
        return .init(threadID:threadID,type:type,activeFlags:flags,updatedAt:.now)
    }
    private func breakdown(_ value: JSONValue?) -> TokenUsage? {
        guard let value else { return nil }
        return .init(input:value["inputTokens"]?.intValue ?? 0,cachedInput:value["cachedInputTokens"]?.intValue ?? 0,output:value["outputTokens"]?.intValue ?? 0,reasoningOutput:value["reasoningOutputTokens"]?.intValue ?? 0)
    }

    private func threadState(_ value: JSONValue?) -> ThreadState {
        let raw = value?["type"]?.stringValue ?? value?.stringValue
        let flags = value?["activeFlags"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if raw?.lowercased() == "active", flags.contains(where: { $0 == "waitingOnApproval" || $0 == "waitingOnUserInput" }) { return .waiting }
        return switch raw?.lowercased() { case "active","running","inprogress":.active; case "idle","loaded":.idle; case "waiting","waitingforapproval","waitingforuserinput":.waiting; case "systemerror","error","failed":.error; case "notloaded":.notLoaded; default:.unknown }
    }
}
