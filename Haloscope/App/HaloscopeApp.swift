import SwiftUI
import AppKit

@main struct HaloscopeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { SettingsView() } }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchPanelController?; private var settingsWindow: NSWindow?; private let model = IslandViewModel()
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A hosted XCTest launches the app executable. Keep onboarding and the
        // live Codex connection out of that process so tests stay deterministic.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        NSApp.setActivationPolicy(.accessory); controller = NotchPanelController(model:model); model.connect()
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(didWake),name:NSWorkspace.didWakeNotification,object:nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(willSleep),name:NSWorkspace.willSleepNotification,object:nil)
        NotificationCenter.default.addObserver(self,selector:#selector(openSettings),name:.haloscopeOpenSettings,object:nil)
        offerLaunchAtLoginIfNeeded()
    }
    @objc private func didWake() { controller?.recalculateGeometry(); model.reconnect() }
    @objc private func willSleep() { model.disconnect() }
    @objc private func openSettings() {
        if settingsWindow == nil {
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:620,height:420),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
            window.title="Haloscope 设置"; window.isReleasedWhenClosed=false; window.center(); window.contentViewController=NSHostingController(rootView:SettingsView()); settingsWindow=window
        }
        NSApp.activate(ignoringOtherApps:true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where:{ $0.scheme?.caseInsensitiveCompare("haloscope") == .orderedSame }) else { return }
        showIslandFromWidget()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showIslandFromWidget()
        return false
    }
    private func showIslandFromWidget() {
        controller?.showFromWidget()
    }
    private func offerLaunchAtLoginIfNeeded() {
        let settings = SettingsStore.shared, service = LoginItemService()
        guard !settings.hasOfferedLaunchAtLogin else { return }
        settings.markLaunchAtLoginOffered()
        if service.status() == .enabled { settings.launchAtLogin = true; return }
        Task { @MainActor in
            try? await Task.sleep(for:.milliseconds(700))
            let alert = NSAlert()
            alert.messageText = "让 Codex 小组件保持最新？"
            alert.informativeText = "开启登录项后，Haloscope 会在登录时启动并更新桌面小组件。你也可以稍后在设置中更改。"
            alert.addButton(withTitle:"开启")
            alert.addButton(withTitle:"稍后")
            NSApp.activate(ignoringOtherApps:true)
            if alert.runModal() == .alertFirstButtonReturn {
                do { try service.setEnabled(true); settings.launchAtLogin = service.status() == .enabled }
                catch { openSettings() }
            }
        }
    }
    func applicationWillTerminate(_ notification: Notification) { controller?.stop(); model.disconnect(); NSWorkspace.shared.notificationCenter.removeObserver(self); NotificationCenter.default.removeObserver(self) }
}

struct SettingsView: View {
    @ObservedObject var settings = SettingsStore.shared
    @State private var codexVersion: String?
    @State private var connectionMessage = "尚未检测"
    @State private var loginStatus = LoginItemStatus.notRegistered
    var body: some View { TabView {
        Form { Toggle("点击外部收起",isOn:$settings.clickOutside); Toggle("开机自启",isOn:$settings.launchAtLogin).onChange(of:settings.launchAtLogin) { _, enabled in setLoginItem(enabled) }; Text("登录项状态：\(loginStatus.rawValue)").foregroundStyle(.secondary) }.tabItem { Text("常规") }
        Form {
            HStack { TextField("Codex 路径",text:Binding(get:{settings.customCodexPath ?? ""},set:{settings.customCodexPath=$0.isEmpty ? nil:$0})); Button("选择…",action:chooseCodex) }
            HStack { Button("检测 Codex") { Task { await detectCodex() } }; Button("测试连接") { Task { await testConnection() } }; Spacer(); Text(connectionMessage) }
            if let codexVersion { Text("版本：\(codexVersion)") }
            Toggle("允许实验接口",isOn:$settings.experimental)
            Toggle("Mock 预览模式",isOn:$settings.mockMode)
            Picker("线程绑定策略",selection:$settings.binding){ForEach([BindingKind.manual,.recent,.running],id:\.self){Text($0.label)}}
        }.tabItem { Text("Codex 连接") }
        Form { Text("自动检测 safeAreaInsets 与顶部辅助区域"); Text("无物理刘海时使用顶部胶囊") }.tabItem { Text("刘海与显示器") }
        Form { Text("日志默认脱敏，不记录消息正文、文件内容或认证数据"); Button("复制诊断信息",action:copyDiagnostics); Button("重置设置",role:.destructive,action:resetSettings) }.tabItem { Text("诊断") }
    }.padding().frame(width:620,height:420).onAppear { loginStatus = LoginItemService().status(); settings.launchAtLogin = loginStatus == .enabled; Task { await detectCodex() } } }
    private func setLoginItem(_ enabled: Bool) {
        do { try LoginItemService().setEnabled(enabled); loginStatus = LoginItemService().status() }
        catch { connectionMessage = "登录项错误：\(error.localizedDescription)"; loginStatus = LoginItemService().status() }
    }
    private func chooseCodex() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.prompt = "选择 Codex"
        if panel.runModal() == .OK { settings.customCodexPath = panel.url?.path; Task { await detectCodex() } }
    }
    private func detectCodex() async {
        guard let path = CodexProcessResolver().resolve(custom:settings.customCodexPath) else { connectionMessage = "未找到 Codex"; codexVersion = nil; return }
        settings.customCodexPath = path; codexVersion = await CodexExecutableInspector().version(path:path); connectionMessage = codexVersion == nil ? "无法执行" : "检测成功"
    }
    private func testConnection() async {
        guard let path = CodexProcessResolver().resolve(custom:settings.customCodexPath) else { connectionMessage = "未找到 Codex"; return }
        connectionMessage = "正在连接…"
        let client = JSONRPCClient()
        do {
            try await client.connect(path:path,experimental:settings.experimental)
            _ = try await client.request("account/rateLimits/read")
            await client.disconnect()
            connectionMessage = "App Server 连接成功"
        } catch {
            await client.disconnect()
            connectionMessage = "连接失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }
    private func copyDiagnostics() {
        let path = CodexProcessResolver().resolve(custom:settings.customCodexPath) ?? "unavailable"
        let value = "Haloscope diagnostics\nmacOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\nCodex path: \(path)\nCodex version: \(codexVersion ?? "unknown")\nExperimental API: \(settings.experimental)\nLogin item: \(loginStatus.rawValue)"
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value,forType:.string)
    }
    private func resetSettings() { settings.customCodexPath = nil; settings.experimental = false; settings.mockMode = false; settings.clickOutside = true; settings.binding = .recent; settings.selectedThreadID = nil; Task { await detectCodex() } }
}
