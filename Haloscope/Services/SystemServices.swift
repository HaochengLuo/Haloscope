import AppKit
import Foundation
import ServiceManagement

@MainActor enum CodexDesktopApplication {
    static let bundleIdentifier = "com.openai.codex"

    static func resolve(using applicationURL: (String) -> URL?) -> URL? {
        applicationURL(bundleIdentifier)
    }

    @discardableResult static func open(workspace: NSWorkspace = .shared) -> Bool {
        guard let applicationURL = resolve(using:{ workspace.urlForApplication(withBundleIdentifier:$0) }) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        workspace.openApplication(at:applicationURL,configuration:configuration) { _,_ in }
        return true
    }
}

struct CodexProcessResolver: Sendable {
    func resolve(custom: String?, home: String = NSHomeDirectory(), executable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        let candidates = [custom, "\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/usr/bin/codex"].compactMap { $0 }
        if let hit = candidates.first(where: executable) { return hit }
        let p = Process(), pipe = Pipe(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-lc", "command -v codex"]
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }; p.waitUntilExit()
        let value = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.flatMap { executable($0) ? $0 : nil }
    }
}

struct CodexExecutableInspector: Sendable {
    func version(path: String) async -> String? {
        await Task.detached {
            let process=Process(), pipe=Pipe(); process.executableURL=URL(fileURLWithPath:path); process.arguments=["--version"]
            process.standardOutput=pipe; process.standardError=pipe
            guard (try? process.run()) != nil else { return nil }; process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data:pipe.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines)
        }.value
    }
}

enum LoginItemStatus: String { case enabled, notRegistered, requiresApproval, notFound, unavailable }
@MainActor final class LoginItemService {
    func status() -> LoginItemStatus {
        switch SMAppService.mainApp.status { case .enabled: .enabled; case .notRegistered: .notRegistered; case .requiresApproval: .requiresApproval; case .notFound: .notFound; @unknown default: .unavailable }
    }
    func setEnabled(_ enabled: Bool) throws { enabled ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
}

struct Backoff: Sendable {
    var base: TimeInterval = 1, maximum: TimeInterval = 60
    func delay(attempt: Int) -> TimeInterval { min(maximum, base * pow(2, Double(max(0, attempt)))) }
}

@MainActor final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    @Published var customCodexPath: String? { didSet { defaults.set(customCodexPath, forKey:"codexPath") } }
    @Published var experimental = false { didSet { defaults.set(experimental, forKey:"experimental") } }
    @Published var clickOutside = true { didSet { defaults.set(clickOutside, forKey:"clickOutside") } }
    @Published var mockMode = false { didSet { defaults.set(mockMode, forKey:"mockMode") } }
    @Published var launchAtLogin = false
    @Published var binding = BindingKind.recent { didSet { defaults.set(binding.rawValue, forKey:"binding") } }
    @Published var selectedThreadID: String? { didSet { defaults.set(selectedThreadID, forKey:"selectedThreadID") } }
    private let defaults: UserDefaults
    var hasOfferedLaunchAtLogin: Bool { defaults.bool(forKey:"didOfferLaunchAtLogin") }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        customCodexPath = defaults.string(forKey:"codexPath")
        experimental = defaults.bool(forKey:"experimental")
        clickOutside = defaults.object(forKey:"clickOutside") as? Bool ?? true
        mockMode = defaults.bool(forKey:"mockMode")
        binding = defaults.string(forKey:"binding").flatMap(BindingKind.init(rawValue:)) ?? .recent
        selectedThreadID = defaults.string(forKey:"selectedThreadID")
    }
    func markLaunchAtLoginOffered() { defaults.set(true,forKey:"didOfferLaunchAtLogin") }
}

struct ScreenGeometry: Equatable, Sendable {
    var screenIdentifier: String; var hasPhysicalNotch: Bool; var detectedNotchFrame: CGRect; var effectiveNotchFrame: CGRect
    var collapsedPanelFrame: CGRect; var expandedPanelFrame: CGRect; var detectionConfidence: Double
}
struct NotchCalibration: Codable, Equatable, Sendable { var width = 0.0, height = 0.0, x = 0.0, y = 0.0 }

struct NotchGeometryService {
    func calculate(screenFrame: CGRect, visibleFrame: CGRect, safeTop: CGFloat, leftTop: CGRect?, rightTop: CGRect?, identifier: String, calibration: NotchCalibration = .init()) -> ScreenGeometry {
        let inferredGap: CGRect? = if let l = leftTop, let r = rightTop, r.minX > l.maxX { CGRect(x:l.maxX, y:min(l.minY,r.minY), width:r.minX-l.maxX, height:max(l.height,r.height)) } else { nil }
        let physical = safeTop > 0 && inferredGap != nil
        let detected = inferredGap ?? CGRect(x:screenFrame.midX-95, y:screenFrame.maxY-32, width:190, height:32)
        let effective = detected.insetBy(dx: -calibration.width/2, dy: -calibration.height/2).offsetBy(dx: calibration.x, dy: calibration.y)
        let collapsedWidth = physical ? effective.width : 220
        let collapsedHeight = physical ? max(32,effective.height)+22 : 30
        let collapsed = CGRect(x:screenFrame.midX-collapsedWidth/2, y:screenFrame.maxY-collapsedHeight, width:collapsedWidth, height:collapsedHeight)
        let expanded = CGRect(x:screenFrame.midX-210, y:screenFrame.maxY-440, width:420, height:440)
        return .init(screenIdentifier:identifier,hasPhysicalNotch:physical,detectedNotchFrame:detected,effectiveNotchFrame:effective,collapsedPanelFrame:collapsed,expandedPanelFrame:expanded,detectionConfidence:physical ? 1 : 0)
    }
}
