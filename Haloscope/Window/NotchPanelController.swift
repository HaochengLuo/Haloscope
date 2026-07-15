import AppKit
import SwiftUI

final class IslandPanel: NSWindow {
    var interactionEnabled = false
    override var canBecomeKey: Bool { interactionEnabled }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class PointerTrackingHostingView: NSHostingView<IslandView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// CodexIsland keeps the hosting view in the AppKit responder chain and
    /// lets an actual NSScrollView own nested gestures. If SwiftUI sends the
    /// event to the host instead of the representable, route it back to that
    /// stable owner so AppKit can latch the complete momentum session.
    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow,from:nil)
        if let scrollView = nestedScrollView(at:point) {
            scrollView.scrollWheel(with:event)
            return
        }
        super.scrollWheel(with:event)
    }

    private func nestedScrollView(at point: NSPoint) -> NSScrollView? {
        var candidate = super.hitTest(point)
        while let view = candidate {
            if let scrollView = view as? IslandOwnedScrollView { return scrollView }
            candidate = view.superview
        }
        return firstOwnedScrollView(in:self)
    }

    private func firstOwnedScrollView(in view: NSView) -> IslandOwnedScrollView? {
        if let scrollView = view as? IslandOwnedScrollView { return scrollView }
        for subview in view.subviews {
            if let scrollView = firstOwnedScrollView(in:subview) { return scrollView }
        }
        return nil
    }
}

struct PanelEventRoutingPolicy {
    static func isInteractive(_ state: PanelState) -> Bool {
        state == .expanded || state == .settingsPresented
    }

    static func shouldCollapse(_ state: PanelState, isPinned: Bool, pointerInside: Bool) -> Bool {
        !isPinned && !pointerInside && (state == .expanded || state == .collapsedHover)
    }
}

@MainActor final class NotchPanelController: NSObject {
    let panel: IslandPanel; let model: IslandViewModel
    private var outsideMonitor: Any?
    private var keyMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var collapseTask: Task<Void,Never>?
    private var pointerTrackingTimer: Timer?
    private weak var targetScreen: NSScreen?
    private var isPointerInside = false
    init(model: IslandViewModel) {
        self.model = model
        panel = IslandPanel(contentRect:NSRect(x:0,y:0,width:220,height:38),styleMask:[.borderless,.fullSizeContentView],backing:.buffered,defer:false)
        super.init(); panel.isOpaque = false; panel.backgroundColor = .clear; panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces,.stationary,.ignoresCycle,.fullScreenAuxiliary]
        panel.hasShadow = true; panel.isMovable = false
        let hosting = PointerTrackingHostingView(rootView:IslandView(model:model))
        panel.contentView = hosting; panel.acceptsMouseMovedEvents = true
        model.onPanelStateChange = { [weak self] in self?.resize() }
        recalculateGeometry(); panel.orderFrontRegardless()
        installMouseTracking()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]) { [weak self] event in
            Task { @MainActor in guard let self, SettingsStore.shared.clickOutside, self.model.panelState == .expanded else { return }; self.model.collapse() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            guard event.keyCode == 53, self?.model.panelState == .expanded else { return event }
            self?.model.collapse(); return nil
        }
        NotificationCenter.default.addObserver(self, selector:#selector(screenParametersChanged), name:NSApplication.didChangeScreenParametersNotification, object:nil)
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
        NSApp.activate(ignoringOtherApps:true)
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
        panel.orderFrontRegardless()
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
    private func installMouseTracking() {
        panel.ignoresMouseEvents = true
        let handler: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pointerTrackingTimer?.invalidate()
                self.pointerTrackingTimer = nil
                self.updateMouseRouting()
            }
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching:.mouseMoved,handler:handler)
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching:.mouseMoved) { event in
            handler(event)
            return event
        }
        pointerTrackingTimer = Timer.scheduledTimer(withTimeInterval:0.1,repeats:true) { [weak self] _ in
            Task { @MainActor in self?.updateMouseRouting() }
        }
    }
    private func updateMouseRouting() {
        let inside = panel.frame.contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        guard inside != isPointerInside else {
            if inside, PanelEventRoutingPolicy.isInteractive(model.panelState),
               (!NSApp.isActive || !panel.isKeyWindow) {
                acquireInteractionFocus()
            }
            return
        }
        if inside { pointerEntered() } else { pointerExited() }
    }
    private func pointerEntered() {
        isPointerInside = true; collapseTask?.cancel(); collapseTask = nil
        if !PanelEventRoutingPolicy.isInteractive(model.panelState) {
            guard model.panelState == .collapsedIdle || model.panelState == .collapsedHover else { return }
            model.isPinnedExpanded = false; model.panelState = .expanded; model.refreshIfStale(); resize()
        }
        acquireInteractionFocus()
    }
    private func pointerExited() {
        isPointerInside = false
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
    private func acquireInteractionFocus() {
        guard PanelEventRoutingPolicy.isInteractive(model.panelState),
              panel.frame.contains(NSEvent.mouseLocation) else { return }
        NSApp.activate(ignoringOtherApps:true)
        panel.makeKey()
    }
    func stop() {
        collapseTask?.cancel()
        pointerTrackingTimer?.invalidate(); pointerTrackingTimer = nil
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor = nil }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor); self.localMouseMonitor = nil }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor); self.globalMouseMonitor = nil }
        NotificationCenter.default.removeObserver(self); panel.orderOut(nil)
    }
}
