import AppKit
import SwiftUI

final class IslandPanel: NSPanel {
    var interactionEnabled = false
    override var canBecomeKey: Bool { interactionEnabled }
    override var canBecomeMain: Bool { false }
}

final class PointerTrackingHostingView: NSHostingView<IslandView> {
    var onEnter: (() -> Void)?; var onExit: (() -> Void)?
    private var area: NSTrackingArea?
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect:bounds,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(next); area = next
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

struct PanelEventRoutingPolicy {
    static func isInteractive(_ state: PanelState) -> Bool {
        state == .expanded || state == .settingsPresented
    }

    static func shouldOwnKey(_ state: PanelState, pointerInside: Bool) -> Bool {
        pointerInside && isInteractive(state)
    }

    static func shouldCollapse(_ state: PanelState, isPinned: Bool, pointerInside: Bool) -> Bool {
        !isPinned && !pointerInside && (state == .expanded || state == .collapsedHover)
    }
}

@MainActor final class NotchPanelController: NSObject {
    let panel: IslandPanel; let model: IslandViewModel
    private var outsideMonitor: Any?
    private var keyMonitor: Any?
    private var collapseTask: Task<Void,Never>?
    private var keyRecoveryTask: Task<Void,Never>?
    private weak var targetScreen: NSScreen?
    private var isPointerInside = false
    init(model: IslandViewModel) {
        self.model = model
        panel = IslandPanel(contentRect:NSRect(x:0,y:0,width:220,height:38),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        super.init(); panel.isOpaque = false; panel.backgroundColor = .clear; panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]; panel.hasShadow = true
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = true
        let hosting = PointerTrackingHostingView(rootView:IslandView(model:model))
        hosting.onEnter = { [weak self] in Task { @MainActor in self?.pointerEntered() } }
        hosting.onExit = { [weak self] in Task { @MainActor in self?.pointerExited() } }
        panel.contentView = hosting; panel.acceptsMouseMovedEvents = true
        model.onPanelStateChange = { [weak self] in self?.resize() }
        recalculateGeometry(); panel.orderFrontRegardless()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]) { [weak self] event in
            Task { @MainActor in guard let self, SettingsStore.shared.clickOutside, self.model.panelState == .expanded else { return }; self.model.collapse() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            guard event.keyCode == 53, self?.model.panelState == .expanded else { return event }
            self?.model.collapse(); return nil
        }
        NotificationCenter.default.addObserver(self, selector:#selector(screenParametersChanged), name:NSApplication.didChangeScreenParametersNotification, object:nil)
        NotificationCenter.default.addObserver(self, selector:#selector(panelDidResignKey), name:NSWindow.didResignKeyNotification, object:panel)
    }
    @objc private func screenParametersChanged() { recalculateGeometry() }
    func recalculateGeometry() {
        guard let screen = targetScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        targetScreen = screen
        let identifier = (screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.stringValue ?? screen.localizedName
        model.notchGeometry = NotchGeometryService().calculate(screenFrame:screen.frame, visibleFrame:screen.visibleFrame, safeTop:screen.safeAreaInsets.top, leftTop:screen.auxiliaryTopLeftArea, rightTop:screen.auxiliaryTopRightArea, identifier:identifier)
        resize(animated:false)
    }
    func position() { resize(animated:false) }
    func showFromWidget() {
        collapseTask?.cancel()
        collapseTask = nil
        model.expandPinned()
        panel.orderFrontRegardless()
    }
    func resize(animated: Bool = true) {
        guard let geometry = model.notchGeometry else { return }
        if model.isPinnedExpanded { collapseTask?.cancel(); collapseTask = nil }
        var frame = model.panelState == .expanded ? geometry.expandedPanelFrame : geometry.collapsedPanelFrame
        if model.panelState == .collapsedHover { frame = frame.insetBy(dx:-8,dy:0) }
        panel.interactionEnabled = PanelEventRoutingPolicy.isInteractive(model.panelState)
        if animated {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { animateReducedMotion(to:frame) }
            else if model.panelState == .expanded { animateExpansion(to:frame) }
            else { animateCollapse(to:frame) }
        } else { panel.setFrame(frame,display:true) }
        synchronizeEventRouting()
    }
    private func animateExpansion(to frame: CGRect) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.42
            context.timingFunction = CAMediaTimingFunction(controlPoints:0.18,0.88,0.22,1.06)
            panel.animator().setFrame(frame,display:true)
        }
    }
    private func animateReducedMotion(to frame: CGRect) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            context.timingFunction = CAMediaTimingFunction(name:.linear)
            panel.animator().setFrame(frame,display:true)
        }
    }
    private func animateCollapse(to frame: CGRect) {
        let recoilWidth = max(40,frame.width-10), recoilHeight = max(24,frame.height-4)
        let recoil = CGRect(x:frame.midX-recoilWidth/2,y:frame.maxY-recoilHeight,width:recoilWidth,height:recoilHeight)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.26
            context.timingFunction = CAMediaTimingFunction(controlPoints:0.36,0.02,0.20,1)
            panel.animator().setFrame(recoil,display:true)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.model.panelState != .expanded else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(controlPoints:0.18,0.82,0.22,1.12)
                    self.panel.animator().setFrame(frame,display:true)
                }
            }
        }
    }
    private func pointerEntered() {
        isPointerInside = true; collapseTask?.cancel(); collapseTask = nil
        if PanelEventRoutingPolicy.isInteractive(model.panelState) {
            synchronizeEventRouting()
            return
        }
        guard model.panelState == .collapsedIdle || model.panelState == .collapsedHover else { return }
        model.isPinnedExpanded = false; model.panelState = .expanded; model.refreshIfStale(); resize()
    }
    private func pointerExited() {
        isPointerInside = false; keyRecoveryTask?.cancel(); keyRecoveryTask = nil
        synchronizeEventRouting()
        guard model.panelState == .expanded || model.panelState == .collapsedHover else { return }
        guard !model.isPinnedExpanded else { return }
        collapseTask?.cancel(); collapseTask = Task { [weak self] in
            try? await Task.sleep(for:.milliseconds(180)); guard !Task.isCancelled else { return }
            guard let self,
                  PanelEventRoutingPolicy.shouldCollapse(
                    self.model.panelState,
                    isPinned:self.model.isPinnedExpanded,
                    pointerInside:self.isPointerInside
                  ) else { return }
            self.model.panelState = .collapsedIdle; self.resize()
        }
    }
    private func synchronizeEventRouting() {
        keyRecoveryTask?.cancel(); keyRecoveryTask = nil
        guard PanelEventRoutingPolicy.shouldOwnKey(model.panelState,pointerInside:isPointerInside) else {
            if panel.isKeyWindow { panel.resignKey() }
            panel.orderFrontRegardless()
            return
        }
        panel.makeKeyAndOrderFront(nil)
        if let contentView = panel.contentView { panel.makeFirstResponder(contentView) }
    }
    @objc private func panelDidResignKey() {
        guard PanelEventRoutingPolicy.shouldOwnKey(model.panelState,pointerInside:isPointerInside) else { return }
        keyRecoveryTask?.cancel()
        keyRecoveryTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self,
                  PanelEventRoutingPolicy.shouldOwnKey(self.model.panelState,pointerInside:self.isPointerInside) else { return }
            self.panel.makeKeyAndOrderFront(nil)
            if let contentView = self.panel.contentView { self.panel.makeFirstResponder(contentView) }
        }
    }
    func stop() {
        collapseTask?.cancel(); keyRecoveryTask?.cancel()
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor = nil }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        NotificationCenter.default.removeObserver(self); panel.orderOut(nil)
    }
}
