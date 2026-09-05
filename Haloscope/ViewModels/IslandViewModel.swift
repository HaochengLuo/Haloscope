import AppKit
import SwiftUI

enum PanelState: String { case hidden, collapsedIdle, collapsedHover, expanded, settingsPresented, disconnected, error }

struct PanelPresentationPolicy {
    static func connectedState(from current: PanelState) -> PanelState {
        preservesInteractiveState(current) ? current : .collapsedIdle
    }

    static func failedState(from current: PanelState) -> PanelState {
        preservesInteractiveState(current) ? current : .error
    }

    private static func preservesInteractiveState(_ state: PanelState) -> Bool {
        state == .expanded || state == .settingsPresented
    }
}

struct WidgetTimelineReloadPolicy: Sendable {
    func shouldReload(
        snapshot: WidgetQuotaSnapshot,
        previous: WidgetQuotaSnapshot?,
        hasRequestedReload: Bool
    ) -> Bool {
        !hasRequestedReload || snapshot.materiallyDiffers(from:previous)
    }
}

actor WidgetSnapshotCoordinator {
    private let store: WidgetQuotaSnapshotStore
    private let reloadTimelines: @Sendable () -> Void
    private let reloadPolicy: WidgetTimelineReloadPolicy
    private var hasRequestedReload = false

    init(
        store: WidgetQuotaSnapshotStore = WidgetQuotaSnapshotStore(),
        reloadTimelines: @escaping @Sendable () -> Void = {},
        reloadPolicy: WidgetTimelineReloadPolicy = .init()
    ) {
        self.store = store
        self.reloadTimelines = reloadTimelines
        self.reloadPolicy = reloadPolicy
    }

    func read() -> WidgetQuotaSnapshot? {
        try? store.read()
    }

    func publish(_ snapshot: WidgetQuotaSnapshot) {
        do {
            let previous = try? store.read()
            try store.write(snapshot)
            if reloadPolicy.shouldReload(
                snapshot:snapshot,
                previous:previous,
                hasRequestedReload:hasRequestedReload
            ) {
                reloadTimelines()
                hasRequestedReload = true
            }
        } catch {
            // SwiftPM and unsigned development builds do not have an App Group container.
        }
    }

    func publishUnavailableIfNeeded(_ message: String) {
        do {
            guard (try? store.read()) == nil else { return }
            try store.write(.unavailable(message))
            reloadTimelines()
            hasRequestedReload = true
        } catch {
            // Keep the host functional when signing/App Group setup is incomplete.
        }
    }
}

@MainActor final class IslandViewModel: ObservableObject {
    @Published var panelState: PanelState = .disconnected
    @Published var connection: ConnectionState = .disconnected
    @Published var windows: [RateWindow] = []
    @Published var threads: [CodexThread] = []
    @Published var errorMessage: String?
    @Published var usageSummary: UsageSummary?
    @Published var planType: String?
    @Published var credits: String?
    @Published var availableResetCredits: Int?
    @Published var lastUpdated: Date?
    @Published var isMockData = false
    @Published var contextSnapshots: [String:ThreadContextSnapshot] = [:]
    @Published var realtimeStatuses: [String:RealtimeThreadStatus] = [:]
    @Published var threadDataUpdatedAt: Date?
    @Published var notchGeometry: ScreenGeometry?
    @Published var isPinnedExpanded = false
    var onPanelStateChange: (() -> Void)?
    private let client: JSONRPCClient
    private let resolveCodexPath: () -> String?
    private let widgetSnapshots: WidgetSnapshotCoordinator?
    private let retryPolicy = RPCRequestRetryPolicy()
    private var reconnectTask: Task<Void,Never>?
    private var disconnectTask: Task<Void,Never>?
    private var monitoringTask: Task<Void,Never>?
    private var accountMonitoringTask: Task<Void,Never>?
    private var isRefreshingAccount = false
    private var isRefreshingThreads = false
    private var session = 0
    private var lastUsageAttempt: Date?
    private var lastAccountAttempt: Date?
    init(widgetSnapshots: WidgetSnapshotCoordinator? = DistributionChannel.supportsWidget ? WidgetSnapshotCoordinator() : nil,
         client: JSONRPCClient = JSONRPCClient(),
         resolveCodexPath: @escaping () -> String? = { CodexProcessResolver().resolve(custom:SettingsStore.shared.customCodexPath) }) {
        self.widgetSnapshots = widgetSnapshots
        self.client = client
        self.resolveCodexPath = resolveCodexPath
    }
    var hasWidgetSnapshotCoordinator: Bool { widgetSnapshots != nil }
    var bindingKind: BindingKind { SettingsStore.shared.binding }
    var selectedThreadID: String? { SettingsStore.shared.selectedThreadID }
    var activeQuotaWindow: RateWindow? {
        windows.first { $0.limitID == "codex" && $0.role == .primary }
            ?? windows.first { $0.role == .primary }
            ?? windows.first
    }
    var isRunning: Bool { threads.contains { $0.status == .active || $0.status == .waiting } }
    func connect() {
        guard reconnectTask == nil, connection != .connected else { return }
        restoreCachedQuotaIfNeeded(); connection = .connecting
        if SettingsStore.shared.mockMode { loadMockData(); return }
        session += 1
        let currentSession = session
        let cleanup = disconnectTask
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            defer { if session == currentSession { reconnectTask = nil } }
            await cleanup?.value
            guard isCurrent(currentSession) else { return }
            guard let path = resolveCodexPath() else {
                connection = .error; errorMessage = t("error.codex_not_found"); publishUnavailableIfNeeded(errorMessage!); return
            }
            do {
                await client.setNotificationHandler { [weak self] notification in
                    await self?.handle(notification,session:currentSession)
                }
                await client.setDisconnectHandler { [weak self] in
                    await self?.handleServerExit(session:currentSession)
                }
                guard isCurrent(currentSession) else { return }
                try await client.connect(path:path,experimental:SettingsStore.shared.experimental)
                guard isCurrent(currentSession) else { return }
                connection = .connected; panelState = PanelPresentationPolicy.connectedState(from:panelState)
                errorMessage = nil; onPanelStateChange?(); await refresh()
                guard isCurrent(currentSession), connection == .connected else { return }
                startMonitoring()
            } catch {
                guard isCurrent(currentSession) else { return }
                // A failed handshake must never enter a process restart loop.
                pauseConnection(message:L10n.format("error.monitoring_paused",language:SettingsStore.shared.language,friendly(error)))
            }
        }
    }
    private func isCurrent(_ value: Int) -> Bool { session == value && !Task.isCancelled }
    private func handle(_ notification: RPCResponse, session currentSession: Int) {
        guard isCurrent(currentSession), connection == .connected else { return }
        switch notification.method {
        case "thread/tokenUsage/updated":
            if let snapshot=CodexPayloadDecoder().contextNotification(notification.params) { contextSnapshots[snapshot.threadID]=snapshot }
        case "account/rateLimits/updated":
            // A notification may contain only one bucket/window. Merge it into
            // the last snapshot without querying quota, history, and threads.
            guard let value = notification.params else { return }
            let previous = AccountSnapshot(windows:windows,planType:planType,credits:credits,primaryWindow:activeQuotaWindow,availableResetCredits:availableResetCredits)
            let account = CodexPayloadDecoder().mergingAccountNotification(value,into:previous)
            windows = account.windows; planType = account.planType; credits = account.credits
            availableResetCredits = account.availableResetCredits
            lastUpdated = .now
            publishWidgetSnapshot(window:account.primaryWindow,account:account)
        case "thread/status/changed":
            if let status=CodexPayloadDecoder().statusNotification(notification.params) { realtimeStatuses[status.threadID]=status }
            // The regular task poll reconciles the list; a burst of status
            // notifications does not need a burst of list requests.
        default: break
        }
    }
    var monitoredThread: CodexThread? {
        switch bindingKind {
        case .manual:
            guard let selectedThreadID else { return nil }
            return threads.first { $0.id == selectedThreadID }
        case .running:
            return threads.first { $0.status == .active || $0.status == .waiting }
        case .recent, .project:
            return threads.first
        case .unavailable:
            return nil
        }
    }
    var monitoredContext: ThreadContextSnapshot? { monitoredThread.flatMap{contextSnapshots[$0.id]} }
    var monitoredRealtimeStatus: RealtimeThreadStatus? { monitoredThread.flatMap{realtimeStatuses[$0.id]} }
    private func startMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for:.seconds(60)); guard !Task.isCancelled else { return }
                await self?.refreshThreads()
            }
        }
        accountMonitoringTask?.cancel()
        accountMonitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for:.seconds(30)); guard !Task.isCancelled else { return }
                await self?.refreshAccountData()
            }
        }
    }
    private func stopMonitoring() {
        monitoringTask?.cancel(); monitoringTask = nil
        accountMonitoringTask?.cancel(); accountMonitoringTask = nil
    }
    private func refreshAccountData() async {
        guard connection == .connected, !Task.isCancelled, !isRefreshingAccount else { return }
        let currentSession = session
        isRefreshingAccount = true
        defer { if session == currentSession { isRefreshingAccount = false } }
        // Reserve the account refresh, then let an in-flight thread request finish so the app
        // server never receives both request families at the same time.
        while isRefreshingThreads {
            do { try await Task.sleep(for:.milliseconds(50)) }
            catch { return }
        }
        guard isCurrent(currentSession), connection == .connected else { return }
        lastAccountAttempt = .now
        let decoder = CodexPayloadDecoder()
        var failures: [String] = []
        do {
            let quota = try await requestWithTransientRetry("account/rateLimits/read")
            guard isCurrent(currentSession), connection == .connected else { return }
            let account = decoder.account(quota); windows = account.windows; planType = account.planType; credits = account.credits; availableResetCredits = account.availableResetCredits
            lastUpdated = .now
            publishWidgetSnapshot(window:account.primaryWindow ?? activeQuotaWindow, account:account)
        } catch {
            guard isCurrent(currentSession) else { return }
            if pauseForTransportFailure(error) { return }
            let message = L10n.format("error.quota",language:SettingsStore.shared.language,friendly(error))
            if windows.isEmpty { failures.append(message); publishUnavailableIfNeeded(message) }
        }
        if lastUsageAttempt == nil || Date.now.timeIntervalSince(lastUsageAttempt!) >= 3_600 {
            // History is daily data. Cache the attempt as well as the success
            // so unsupported/failing endpoints are not retried every refresh.
            lastUsageAttempt = .now
            do {
                let value = try await requestWithTransientRetry("account/usage/read")
                guard isCurrent(currentSession), connection == .connected else { return }
                usageSummary = decoder.usage(value)
            } catch {
                guard isCurrent(currentSession) else { return }
                if pauseForTransportFailure(error) { return }
                // Usage history is supplementary. Preserve the last successful value.
            }
        }
        errorMessage = failures.isEmpty ? nil : failures.joined(separator:t("list.separator"))
    }
    private func requestWithTransientRetry(_ method: String, params: JSONValue = .object([:])) async throws -> JSONValue {
        let currentSession = session
        var failureIndex = 0
        while true {
            guard isCurrent(currentSession), connection == .connected else { throw CancellationError() }
            do { return try await client.request(method, params:params) }
            catch {
                guard let delay = retryPolicy.delay(afterFailure:failureIndex,error:error) else { throw error }
                failureIndex += 1
                try await Task.sleep(for:.milliseconds(Int64(delay * 1_000)))
            }
        }
    }
    private func refreshThreads() async {
        guard connection == .connected, !Task.isCancelled, !isRefreshingThreads, !isRefreshingAccount else { return }
        let currentSession = session
        isRefreshingThreads = true
        defer { if session == currentSession { isRefreshingThreads = false } }
        do {
            let value = try await requestWithTransientRetry("thread/list",params:.object(["limit":.number(50),"sortKey":.string("updated_at"),"sortDirection":.string("desc"),"sourceKinds":.array([])]))
            guard isCurrent(currentSession), connection == .connected else { return }
            threads = CodexPayloadDecoder().threads(value); threadDataUpdatedAt = .now
        } catch {
            guard isCurrent(currentSession) else { return }
            if pauseForTransportFailure(error) { return }
            if threads.isEmpty, windows.isEmpty { errorMessage = L10n.format("error.thread_refresh",language:SettingsStore.shared.language,friendly(error)) }
        }
    }
    private func loadMockData() {
        let now = Date.now
        windows = [.init(id:"mock-primary",limitName:"Mock preview",usedPercent:12,windowDurationMins:10080,resetsAt:now.addingTimeInterval(432000),limitID:"codex",role:.primary)]
        threads = [.init(id:"mock-running",preview:t("mock.running"),cwd:"~/Projects/Demo",updatedAt:now,status:.active,tokenUsage:.init(input:1200,cachedInput:600,output:350,reasoningOutput:180)),.init(id:"mock-idle",preview:t("mock.history"),cwd:"~/Projects/Demo",updatedAt:now.addingTimeInterval(-1800),status:.idle)]
        realtimeStatuses["mock-running"] = .init(threadID:"mock-running",type:"active",activeFlags:[],updatedAt:now)
        contextSnapshots["mock-running"] = .init(threadID:"mock-running",total:.init(input:18240,cachedInput:9120,output:4280,reasoningOutput:1360),last:.init(input:1240,cachedInput:620,output:380,reasoningOutput:160),modelContextWindow:200000,updatedAt:now)
        usageSummary = .init(buckets:(0..<30).map { .init(startDate:Calendar.current.date(byAdding:.day,value:-$0,to:now)!,tokens:1000+$0*25) },lifetimeTokens:42000,peakDailyTokens:3200)
        planType = "mock"; credits = nil; availableResetCredits = 2; lastUpdated = now; threadDataUpdatedAt = now; isMockData = true; connection = .connected; panelState = PanelPresentationPolicy.connectedState(from:panelState); reconnectTask = nil
        publishWidgetSnapshot(window:activeQuotaWindow, account:.init(windows:windows,planType:planType,credits:nil,primaryWindow:activeQuotaWindow,availableResetCredits:availableResetCredits)); onPanelStateChange?()
    }
    func reconnect() {
        // Only an explicit reconnect or a real sleep/wake cycle starts a new
        // process. Cancelled work must finish cleanup before the next launch.
        disconnect()
        connect()
    }
    func disconnect() {
        session += 1
        reconnectTask?.cancel(); reconnectTask = nil; stopMonitoring()
        isRefreshingAccount = false; isRefreshingThreads = false
        let previousCleanup = disconnectTask
        disconnectTask = Task { [client] in
            await previousCleanup?.value
            await client.disconnect()
        }
        connection = .disconnected
    }
    func shutdown() async {
        disconnect()
        await disconnectTask?.value
    }
    func refresh() async {
        guard connection == .connected else { return }
        isMockData = false; await refreshAccountData(); await refreshThreads()
    }
    func refreshIfStale(maxAge: TimeInterval = 30) {
        guard connection == .connected else { return }
        guard lastUpdated == nil || Date.now.timeIntervalSince(lastUpdated!) > maxAge else { return }
        guard lastAccountAttempt == nil || Date.now.timeIntervalSince(lastAccountAttempt!) >= 30 else { return }
        Task { [weak self] in await self?.refreshAccountData() }
    }
    private func t(_ key: String) -> String { L10n.text(key,language:SettingsStore.shared.language) }
    private func friendly(_ error: Error) -> String {
        if let rpcError = error as? RPCError { return rpcError.localizedDescription(language:SettingsStore.shared.language) }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
    func toggleExpanded() { panelState = panelState == .expanded ? .collapsedIdle : .expanded; onPanelStateChange?() }
    func expandPinned() { isPinnedExpanded = true; panelState = .expanded; onPanelStateChange?(); refreshIfStale() }
    func collapse() { isPinnedExpanded = false; panelState = .collapsedIdle; onPanelStateChange?() }
    func selectThread(_ id: String) {
        SettingsStore.shared.selectedThreadID = id
        SettingsStore.shared.binding = .manual
    }
    private func handleServerExit(session currentSession: Int) {
        guard session == currentSession, connection == .connected else { return }
        pauseConnection(message:t("error.server_exited"))
    }
    @discardableResult private func pauseForTransportFailure(_ error: Error) -> Bool {
        guard let rpcError = error as? RPCError, rpcError.shouldReconnect else { return false }
        pauseConnection(message:L10n.format("error.monitoring_paused",language:SettingsStore.shared.language,friendly(error)))
        return true
    }
    private func pauseConnection(message: String) {
        disconnect()
        connection = .error; panelState = PanelPresentationPolicy.failedState(from:panelState)
        errorMessage = message; publishUnavailableIfNeeded(message); onPanelStateChange?()
    }
    private func restoreCachedQuotaIfNeeded() {
        guard DistributionChannel.supportsWidget, let widgetSnapshots else { return }
        Task { [weak self] in
            guard let snapshot = await widgetSnapshots.read(),
                  snapshot.availability == .available,
                  let remaining = snapshot.normalizedRemainingPercent,
                  let self,
                  windows.isEmpty else { return }
            windows = [.init(
                id:"cached-codex-primary",
                limitName:"Codex",
                usedPercent:100 - remaining,
                windowDurationMins:snapshot.windowDurationMins,
                resetsAt:snapshot.resetsAt,
                limitID:"codex",
                role:.primary
            )]
            planType = snapshot.planType
            availableResetCredits = snapshot.availableResetCredits
            lastUpdated = snapshot.updatedAt
        }
    }
    private func publishWidgetSnapshot(window: RateWindow?, account: AccountSnapshot) {
        guard DistributionChannel.supportsWidget, let widgetSnapshots else { return }
        guard let window else { publishUnavailableIfNeeded(t("error.quota_unavailable")); return }
        let snapshot = WidgetQuotaSnapshot(
            remainingPercent:window.remainingPercent,
            windowDurationMins:window.windowDurationMins,
            resetsAt:window.resetsAt,
            availableResetCredits:account.availableResetCredits,
            planType:account.planType,
            updatedAt:.now,
            availability:.available,
            errorMessage:nil
        )
        Task { await widgetSnapshots.publish(snapshot) }
    }
    private func publishUnavailableIfNeeded(_ message: String) {
        guard DistributionChannel.supportsWidget, let widgetSnapshots else { return }
        Task { await widgetSnapshots.publishUnavailableIfNeeded(message) }
    }
    var hasRecentThreadActivity: Bool { guard let updated=threads.first?.updatedAt else { return false }; return Date.now.timeIntervalSince(updated) < 20 }
}
