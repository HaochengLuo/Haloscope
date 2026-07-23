import SwiftUI
import AppKit
import WidgetKit

enum HaloscopeDeepLink {
    static let widgetScheme = "haloscope-widget"
    static let legacyHaloscopeScheme = "haloscope"
    static let legacyCodexIslandScheme = "codexisland"

    private static let supportedSchemes = Set([
        widgetScheme,
        legacyHaloscopeScheme,
        legacyCodexIslandScheme
    ])

    static func handles(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return supportedSchemes.contains(scheme)
    }
}

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
        migrateLegacyWidgetDeepLinkIfNeeded()
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(didWake),name:NSWorkspace.didWakeNotification,object:nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(willSleep),name:NSWorkspace.willSleepNotification,object:nil)
        NotificationCenter.default.addObserver(self,selector:#selector(openSettings),name:.haloscopeOpenSettings,object:nil)
        NotificationCenter.default.addObserver(self,selector:#selector(languageDidChange),name:.haloscopeLanguageDidChange,object:nil)
        offerLaunchAtLoginIfNeeded()
    }
    @objc private func didWake() { controller?.recalculateGeometry(); model.reconnect() }
    @objc private func willSleep() { model.disconnect() }
    @objc private func openSettings() {
        if settingsWindow == nil {
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:620,height:420),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
            window.title=L10n.text("app.settings_title",language:SettingsStore.shared.language); window.isReleasedWhenClosed=false; window.center(); window.contentViewController=NSHostingController(rootView:SettingsView()); settingsWindow=window
        }
        NSApp.activate(ignoringOtherApps:true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func languageDidChange() {
        settingsWindow?.title = L10n.text("app.settings_title",language:SettingsStore.shared.language)
        WidgetCenter.shared.reloadTimelines(ofKind:"CodexWeeklyQuotaWidget")
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where:HaloscopeDeepLink.handles) else { return }
        showIslandFromWidget()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showIslandFromWidget()
        return false
    }
    private func showIslandFromWidget() {
        controller?.showFromWidget()
    }
    private func migrateLegacyWidgetDeepLinkIfNeeded() {
        let migrationKey = "legacyCodexIslandWidgetDeepLinkMigration.v1"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey:migrationKey) else { return }

        NSWorkspace.shared.setDefaultApplication(
            at:Bundle.main.bundleURL,
            toOpenURLsWithScheme:HaloscopeDeepLink.legacyCodexIslandScheme
        ) { error in
            guard error == nil else { return }
            Task { @MainActor in
                UserDefaults.standard.set(true,forKey:migrationKey)
            }
        }
    }
    private func offerLaunchAtLoginIfNeeded() {
        let settings = SettingsStore.shared, service = LoginItemService()
        guard !settings.hasOfferedLaunchAtLogin else { return }
        settings.markLaunchAtLoginOffered()
        if service.status() == .enabled { settings.launchAtLogin = true; return }
        Task { @MainActor in
            try? await Task.sleep(for:.milliseconds(700))
            let language = settings.language
            let alert = NSAlert()
            alert.messageText = L10n.text("onboarding.title",language:language)
            alert.informativeText = L10n.text("onboarding.message",language:language)
            alert.addButton(withTitle:L10n.text("action.enable",language:language))
            alert.addButton(withTitle:L10n.text("action.later",language:language))
            NSApp.activate(ignoringOtherApps:true)
            if alert.runModal() == .alertFirstButtonReturn {
                do { try service.setEnabled(true); settings.launchAtLogin = service.status() == .enabled }
                catch { openSettings() }
            }
        }
    }
    func applicationWillTerminate(_ notification: Notification) { controller?.stop(); model.disconnect(); NSWorkspace.shared.notificationCenter.removeObserver(self); NotificationCenter.default.removeObserver(self) }
}

private enum SettingsConnectionStatus {
    case notChecked, codexNotFound, cannotExecute, detected, connecting, connected
    case loginItemError(String), failed(String)

    func localized(language: AppLanguage) -> String {
        switch self {
        case .notChecked: L10n.text("connection_check.not_checked",language:language)
        case .codexNotFound: L10n.text("connection_check.not_found",language:language)
        case .cannotExecute: L10n.text("connection_check.cannot_execute",language:language)
        case .detected: L10n.text("connection_check.detected",language:language)
        case .connecting: L10n.text("connection_check.connecting",language:language)
        case .connected: L10n.text("connection_check.connected",language:language)
        case .loginItemError(let detail): L10n.format("connection_check.login_error",language:language,detail)
        case .failed(let detail): L10n.format("connection_check.failed",language:language,detail)
        }
    }
}

struct SettingsView: View {
    private static let displayLabelWidth: CGFloat = 170
    private static let displayControlWidth: CGFloat = 280

    @ObservedObject var settings = SettingsStore.shared
    @State private var codexVersion: String?
    @State private var connectionStatus = SettingsConnectionStatus.notChecked
    @State private var loginStatus = LoginItemStatus.notRegistered

    var body: some View {
        TabView {
            Form {
                Picker(t("settings.language"),selection:$settings.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName(in:settings.language)).tag(language)
                    }
                }
                Toggle(t("settings.collapse_outside"),isOn:$settings.clickOutside)
                Toggle(t("settings.launch_login"),isOn:$settings.launchAtLogin)
                    .onChange(of:settings.launchAtLogin) { _, enabled in setLoginItem(enabled) }
                Text(L10n.format("settings.login_status",language:settings.language,loginStatus.localizedLabel(language:settings.language)))
                    .foregroundStyle(.secondary)
            }
            .tabItem { Text(t("settings.tab.general")) }

            Form {
                HStack {
                    TextField(t("settings.codex_path"),text:Binding(
                        get:{ settings.customCodexPath ?? "" },
                        set:{ settings.customCodexPath = $0.isEmpty ? nil:$0 }
                    ))
                    Button(t("action.choose"),action:chooseCodex)
                }
                HStack {
                    Button(t("action.detect_codex")) { Task { await detectCodex() } }
                    Button(t("action.test_connection")) { Task { await testConnection() } }
                    Spacer()
                    Text(connectionStatus.localized(language:settings.language))
                }
                if let codexVersion {
                    Text(L10n.format("settings.version",language:settings.language,codexVersion))
                }
                Toggle(t("settings.experimental"),isOn:$settings.experimental)
                Toggle(t("settings.mock"),isOn:$settings.mockMode)
                Picker(t("settings.binding"),selection:$settings.binding) {
                    ForEach([BindingKind.manual,.recent,.running],id:\.self) {
                        Text($0.localizedLabel(language:settings.language))
                    }
                }
            }
            .tabItem { Text(t("settings.tab.codex")) }

            displaySettings
            .tabItem { Text(t("settings.tab.display")) }

            Form {
                Text(t("settings.diagnostics.privacy"))
                Button(t("action.copy_diagnostics"),action:copyDiagnostics)
                Button(t("action.reset_settings"),role:.destructive,action:resetSettings)
            }
            .tabItem { Text(t("settings.tab.diagnostics")) }
        }
        .padding()
        .frame(width:620,height:420)
        .environment(\.locale,settings.language.locale)
        .onAppear {
            loginStatus = LoginItemService().status()
            settings.launchAtLogin = loginStatus == .enabled
            Task { await detectCodex() }
        }
    }

    private func t(_ key: String) -> String {
        L10n.text(key,language:settings.language)
    }

    private var displaySettings: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack(spacing:16) {
                Text(t("settings.appearance"))
                    .frame(width:Self.displayLabelWidth,alignment:.trailing)
                Picker("",selection:$settings.islandAppearance) {
                    ForEach(IslandAppearance.allCases) { appearance in
                        Text(appearance.localizedLabel(language:settings.language)).tag(appearance)
                    }
                }
                .labelsHidden()
                .frame(width:Self.displayControlWidth)
            }

            HStack(spacing:16) {
                Text(t("settings.card_opacity"))
                    .frame(width:Self.displayLabelWidth,alignment:.trailing)
                HStack(spacing:8) {
                    Slider(
                        value:$settings.liquidGlassCardOpacity,
                        in:IslandAppearance.liquidGlassCardOpacityRange,
                        step:IslandAppearance.liquidGlassCardOpacityStep
                    )
                    Text("\(Int((settings.liquidGlassCardOpacity*100).rounded()))%")
                        .monospacedDigit()
                        .frame(width:36,alignment:.trailing)
                }
                .frame(width:Self.displayControlWidth)
                .disabled(settings.islandAppearance != .liquidGlass)
                .opacity(settings.islandAppearance == .liquidGlass ? 1:0.45)
            }

            HStack(spacing:16) {
                Text(t("settings.text_color"))
                    .frame(width:Self.displayLabelWidth,alignment:.trailing)
                Picker("",selection:$settings.liquidGlassTextColor) {
                    ForEach(LiquidGlassTextColor.allCases) { color in
                        Text(color.localizedLabel(language:settings.language)).tag(color)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width:Self.displayControlWidth)
                .disabled(settings.islandAppearance != .liquidGlass)
                .opacity(settings.islandAppearance == .liquidGlass ? 1:0.45)
            }

            HStack(alignment:.top,spacing:16) {
                Color.clear.frame(width:Self.displayLabelWidth,height:1)
                VStack(alignment:.leading,spacing:7) {
                    Text(t("settings.liquid_glass_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Divider()
                    Text(t("settings.display.detect"))
                    Text(t("settings.display.fallback"))
                }
                .fixedSize(horizontal:false,vertical:true)
                .frame(width:Self.displayControlWidth,alignment:.leading)
            }
        }
        .frame(
            width:Self.displayLabelWidth+16+Self.displayControlWidth,
            alignment:.leading
        )
        .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top)
        .padding(.top,28)
    }

    private func setLoginItem(_ enabled: Bool) {
        do {
            try LoginItemService().setEnabled(enabled)
            loginStatus = LoginItemService().status()
        } catch {
            connectionStatus = .loginItemError(error.localizedDescription)
            loginStatus = LoginItemService().status()
        }
    }

    private func chooseCodex() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = t("action.choose_codex")
        if panel.runModal() == .OK {
            settings.customCodexPath = panel.url?.path
            Task { await detectCodex() }
        }
    }

    private func detectCodex() async {
        guard let path = CodexProcessResolver().resolve(custom:settings.customCodexPath) else {
            connectionStatus = .codexNotFound
            codexVersion = nil
            return
        }
        settings.customCodexPath = path
        codexVersion = await CodexExecutableInspector().version(path:path)
        connectionStatus = codexVersion == nil ? .cannotExecute:.detected
    }

    private func testConnection() async {
        guard let path = CodexProcessResolver().resolve(custom:settings.customCodexPath) else {
            connectionStatus = .codexNotFound
            return
        }
        connectionStatus = .connecting
        let client = JSONRPCClient()
        do {
            try await client.connect(path:path,experimental:settings.experimental)
            _ = try await client.request("account/rateLimits/read")
            await client.disconnect()
            connectionStatus = .connected
        } catch {
            await client.disconnect()
            connectionStatus = .failed(localizedError(error))
        }
    }

    private func localizedError(_ error: Error) -> String {
        if let rpcError = error as? RPCError {
            return rpcError.localizedDescription(language:settings.language)
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func copyDiagnostics() {
        let path = CodexProcessResolver().resolve(custom:settings.customCodexPath) ?? "unavailable"
        let value = "Haloscope diagnostics\nmacOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\nCodex path: \(path)\nCodex version: \(codexVersion ?? "unknown")\nExperimental API: \(settings.experimental)\nLogin item: \(loginStatus.rawValue)\nLanguage: \(settings.language.rawValue)\nIsland appearance: \(settings.islandAppearance.rawValue)\nLiquid Glass card opacity: \(settings.liquidGlassCardOpacity)\nLiquid Glass text color: \(settings.liquidGlassTextColor.rawValue)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value,forType:.string)
    }

    private func resetSettings() {
        settings.customCodexPath = nil
        settings.experimental = false
        settings.mockMode = false
        settings.islandAppearance = .solidBlack
        settings.liquidGlassCardOpacity = IslandAppearance.defaultLiquidGlassCardOpacity
        settings.liquidGlassTextColor = .white
        settings.clickOutside = true
        settings.binding = .recent
        settings.selectedThreadID = nil
        settings.language = .system
        Task { await detectCodex() }
    }
}
