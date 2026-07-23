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

struct PanelPrimaryClickRoutingPolicy {
    static let maximumClickTravel: CGFloat = 5

    static func shouldOpenCodex(state: PanelState, start: NSPoint?, end: NSPoint) -> Bool {
        guard state == .expanded, let start else { return false }
        return hypot(end.x-start.x,end.y-start.y) <= maximumClickTravel
    }
}

struct PanelCanvasLayout {
    static let horizontalShadowInset: CGFloat = 20
    static let bottomShadowInset: CGFloat = 28
    static let detachedTopGap: CGFloat = 10

    static func compactStatusWidth(for geometry: ScreenGeometry?) -> CGFloat {
        guard let geometry else { return 190 }
        let availableWidth = geometry.hasPhysicalNotch
            ? geometry.effectiveNotchFrame.width
            : geometry.collapsedPanelFrame.width
        return min(availableWidth,220)
    }

    static func canvasFrame(for geometry: ScreenGeometry) -> CGRect {
        let expanded=geometry.expandedPanelFrame
        let topGap=geometry.hasPhysicalNotch ? 0:detachedTopGap
        let size=CGSize(
            width:expanded.width+horizontalShadowInset*2,
            height:expanded.height+topGap+bottomShadowInset
        )
        return CGRect(
            x:expanded.midX-size.width/2,
            y:expanded.maxY-size.height,
            width:size.width,
            height:size.height
        )
    }

    static func islandFrame(for geometry: ScreenGeometry, state: PanelState) -> CGRect {
        let expanded=state == .expanded || state == .settingsPresented
        var size=expanded ? geometry.expandedPanelFrame.size:geometry.collapsedPanelFrame.size
        if state == .collapsedHover { size.width += 16 }
        let topGap=geometry.hasPhysicalNotch ? 0:detachedTopGap
        return CGRect(
            x:geometry.expandedPanelFrame.midX-size.width/2,
            y:geometry.expandedPanelFrame.maxY-topGap-size.height,
            width:size.width,
            height:size.height
        )
    }
}

@MainActor final class NotchPanelController: NSObject {
    let panel: IslandPanel; let model: IslandViewModel
    private var outsideMonitor: Any?
    private var keyMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var primaryClickMonitor: Any?
    private var collapseTask: Task<Void,Never>?
    private var pointerTrackingTimer: Timer?
    private weak var targetScreen: NSScreen?
    private var isPointerInside = false
    private var primaryClickStart: NSPoint?
    init(model: IslandViewModel) {
        self.model = model
        panel = IslandPanel(contentRect:NSRect(x:0,y:0,width:220,height:38),styleMask:[.borderless,.fullSizeContentView],backing:.buffered,defer:false)
        super.init(); panel.isOpaque = false; panel.backgroundColor = .clear; panel.level = .popUpMenu; panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces,.stationary,.ignoresCycle,.fullScreenAuxiliary]
        panel.hasShadow = false; panel.isMovable = false
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
        primaryClickMonitor = NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.leftMouseDragged,.leftMouseUp]) { [weak self] event in
            self?.handlePrimaryMouseEvent(event)
            return event
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
        panel.interactionEnabled = PanelEventRoutingPolicy.isInteractive(model.panelState)
        let frame=PanelCanvasLayout.canvasFrame(for:geometry)
        if panel.frame != frame { panel.setFrame(frame,display:true) }
        panel.orderFrontRegardless()
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
        guard let geometry=model.notchGeometry else { return }
        let inside=PanelCanvasLayout.islandFrame(for:geometry,state:model.panelState).contains(NSEvent.mouseLocation)
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
        guard let geometry=model.notchGeometry,
              PanelEventRoutingPolicy.isInteractive(model.panelState),
              PanelCanvasLayout.islandFrame(for:geometry,state:model.panelState).contains(NSEvent.mouseLocation) else { return }
        NSApp.activate(ignoringOtherApps:true)
        panel.makeKey()
    }
    private func handlePrimaryMouseEvent(_ event: NSEvent) {
        guard event.window === panel else { primaryClickStart = nil; return }
        switch event.type {
        case .leftMouseDown:
            primaryClickStart = model.panelState == .expanded ? event.locationInWindow:nil
        case .leftMouseDragged:
            guard PanelPrimaryClickRoutingPolicy.shouldOpenCodex(state:.expanded,start:primaryClickStart,end:event.locationInWindow) else {
                primaryClickStart = nil
                return
            }
        case .leftMouseUp:
            let shouldOpen = PanelPrimaryClickRoutingPolicy.shouldOpenCodex(state:model.panelState,start:primaryClickStart,end:event.locationInWindow)
            primaryClickStart = nil
            guard shouldOpen else { return }
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                self.model.collapse()
                if !CodexDesktopApplication.open() { NSSound.beep() }
            }
        default:
            break
        }
    }
    func stop() {
        collapseTask?.cancel()
        pointerTrackingTimer?.invalidate(); pointerTrackingTimer = nil
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor = nil }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor); self.localMouseMonitor = nil }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor); self.globalMouseMonitor = nil }
        if let primaryClickMonitor { NSEvent.removeMonitor(primaryClickMonitor); self.primaryClickMonitor = nil }
        NotificationCenter.default.removeObserver(self); panel.orderOut(nil)
    }
}
