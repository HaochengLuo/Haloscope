import AppKit
import SwiftUI

/// A stable AppKit gesture owner for the island's vertical content. Keeping
/// elasticity enabled makes the top and bottom feel native while preventing
/// the scroll chain from being handed to a window in another process.
@MainActor final class IslandOwnedScrollView: NSScrollView {
    var layoutHostedDocument: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame:frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder:coder)
        configure()
    }

    override func layout() {
        super.layout()
        layoutHostedDocument?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func configure() {
        borderType = .noBorder
        drawsBackground = false
        backgroundColor = .clear
        hasVerticalScroller = false
        hasHorizontalScroller = false
        autohidesScrollers = true
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsets(top:0,left:0,bottom:0,right:0)
        scrollerInsets = NSEdgeInsets(top:0,left:0,bottom:0,right:0)
        verticalScrollElasticity = .allowed
        horizontalScrollElasticity = .none
        usesPredominantAxisScrolling = true
        scrollsDynamically = true
        contentView.drawsBackground = false
    }
}

/// SwiftUI still renders the exact same detail tree; only the viewport and
/// gesture ownership move to AppKit. The hosting view is resized to its
/// measured content height without resetting the clip view's scroll offset.
private struct IslandNativeScrollView<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    func makeCoordinator() -> Coordinator { Coordinator(content:content) }

    func makeNSView(context: Context) -> IslandOwnedScrollView {
        let scrollView = IslandOwnedScrollView()
        let hostingController = context.coordinator.hostingController
        let hostingView = hostingController.view
        hostingView.frame = NSRect(x:0,y:0,width:1,height:1)
        hostingView.autoresizingMask = []
        hostingController.sizingOptions = [.intrinsicContentSize]
        scrollView.documentView = hostingView
        scrollView.layoutHostedDocument = { [weak scrollView, weak hostingController] in
            guard let scrollView, let hostingController else { return }
            let hostingView = hostingController.view
            let viewport = scrollView.contentSize
            guard viewport.width > 0, viewport.height > 0 else { return }

            let fitting = hostingController.sizeThatFits(
                in:CGSize(width:viewport.width,height:100_000)
            )
            let documentSize = CGSize(
                width:viewport.width,
                height:max(viewport.height,ceil(fitting.height))
            )
            guard abs(hostingView.frame.width-documentSize.width) > 0.5 ||
                  abs(hostingView.frame.height-documentSize.height) > 0.5 else { return }

            let oldBounds = scrollView.contentView.bounds
            hostingView.frame = NSRect(origin:.zero,size:documentSize)
            let constrained = scrollView.contentView.constrainBoundsRect(oldBounds)
            scrollView.contentView.scroll(to:constrained.origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        scrollView.layoutHostedDocument?()
        return scrollView
    }

    func updateNSView(_ scrollView: IslandOwnedScrollView, context: Context) {
        context.coordinator.hostingController.rootView = content
        DispatchQueue.main.async { [weak scrollView] in
            scrollView?.needsLayout = true
            scrollView?.layoutSubtreeIfNeeded()
        }
    }

    @MainActor final class Coordinator {
        let hostingController: NSHostingController<Content>
        init(content: Content) { hostingController = NSHostingController(rootView:content) }
    }
}

private struct NotchRevealModifier: ViewModifier {
    let visible: Bool
    func body(content: Content) -> some View {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            content.opacity(visible ? 1 : 0)
        } else {
            content
                .opacity(visible ? 1 : 0)
                .blur(radius:visible ? 0 : 7)
                .scaleEffect(x:visible ? 1 : 0.94,y:visible ? 1 : 0.72,anchor:.top)
        }
    }
}

private struct LiquidGlassPanelSurface: View {
    let shape: UnevenRoundedRectangle
    let isExpanded: Bool

    private var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    var body: some View {
        ZStack {
            if reduceTransparency {
                shape.fill(Color(red:0.075,green:0.078,blue:0.082))
            } else {
                systemGlass

                shape.fill(
                    LinearGradient(
                        stops:[
                            .init(color:Color.black.opacity(isExpanded ? 0.34:0.27),location:0),
                            .init(color:Color.black.opacity(isExpanded ? 0.22:0.16),location:0.42),
                            .init(color:Color.black.opacity(isExpanded ? 0.38:0.29),location:1)
                        ],
                        startPoint:.topLeading,
                        endPoint:.bottomTrailing
                    )
                )

                shape.fill(
                    LinearGradient(
                        stops:[
                            .init(color:Color.white.opacity(0.18),location:0),
                            .init(color:Color.white.opacity(0.045),location:0.16),
                            .init(color:Color.clear,location:0.42),
                            .init(color:Color.white.opacity(0.025),location:1)
                        ],
                        startPoint:.top,
                        endPoint:.bottom
                    )
                )
                .blendMode(.screen)
            }
        }
        .overlay {
            shape.stroke(
                LinearGradient(
                    colors:[Color.white.opacity(0.42),Color.white.opacity(0.12),Color.black.opacity(0.24)],
                    startPoint:.topLeading,
                    endPoint:.bottomTrailing
                ),
                lineWidth:0.8
            )
        }
        .overlay(alignment:.top) {
            if !reduceTransparency {
                Capsule()
                    .fill(LinearGradient(colors:[.clear,Color.white.opacity(0.46),.clear],startPoint:.leading,endPoint:.trailing))
                    .frame(width:isExpanded ? 210:118,height:1)
                    .blur(radius:0.25)
                    .padding(.top,1)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private var systemGlass: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular,in:shape)
        } else {
            shape.fill(.ultraThinMaterial)
        }
    }
}

struct IslandView: View {
    @ObservedObject var model: IslandViewModel
    @ObservedObject private var settings = SettingsStore.shared
    private let card = Color.white.opacity(0.065)
    private let border = Color.white.opacity(0.13)
    private let accent = Color(red:0.30,green:0.78,blue:0.48)
    var body: some View {
        VStack(spacing:isExpanded ? 14:8) {
            HStack(spacing:8) {
                Circle().fill(statusColor).frame(width:8,height:8)
                Text(statusText).font(.system(size:11,weight:.medium)).lineLimit(1)
                Spacer()
                Text(model.activeQuotaWindow.map { "7D  \($0.roundedRemainingPercent)%" } ?? "7D  —").monospacedDigit().font(.system(size:11,weight:.semibold))
            }
            .padding(.horizontal,8)
            .frame(width:compactStatusWidth,height:22)
            .background(isExpanded ? card:Color.clear,in:UnevenRoundedRectangle(cornerRadii:.init(bottomLeading:8,bottomTrailing:8),style:.continuous))
            if model.panelState == .expanded {
                details.transition(.modifier(active:NotchRevealModifier(visible:false),identity:NotchRevealModifier(visible:true)))
            }
        }
        .padding(contentInsets)
        .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top)
        .background { LiquidGlassPanelSurface(shape:panelShape,isExpanded:isExpanded) }
        .clipShape(panelShape)
        .foregroundStyle(.white).contentShape(Rectangle())
        .environment(\.locale,settings.language.locale)
        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .linear(duration:0.10) : .spring(response:0.46,dampingFraction:0.72,blendDuration:0.08),value:model.panelState)
        .contextMenu {
            Button(t("context.open_codex"),action:openCodexDesktop)
            Divider()
            Button(t("context.refresh")) { Task { await model.refresh() } }
            Button(t("context.expand")) { model.expandPinned() }
            Button(t("context.settings")) { NotificationCenter.default.post(name:.haloscopeOpenSettings,object:nil) }
            Divider()
            Button(t("context.reconnect")) { model.reconnect() }
            Button(t("context.quit")) { NSApplication.shared.terminate(nil) }
        }
    }
    private var isExpanded: Bool { model.panelState == .expanded }
    private var hasPhysicalNotch: Bool { model.notchGeometry?.hasPhysicalNotch == true }
    private var isPhysicalNotch: Bool { hasPhysicalNotch && !isExpanded }
    private var compactStatusWidth: CGFloat { min(model.notchGeometry?.collapsedPanelFrame.width ?? 190,220) }
    private var notchHeight: CGFloat { model.notchGeometry?.effectiveNotchFrame.height ?? 32 }
    private var contentInsets: EdgeInsets {
        if isExpanded { return .init(top:hasPhysicalNotch ? notchHeight:10,leading:18,bottom:16,trailing:18) }
        return .init(top:hasPhysicalNotch ? notchHeight:4,leading:0,bottom:hasPhysicalNotch ? 0:4,trailing:0)
    }
    private var panelShape: UnevenRoundedRectangle {
        let top: CGFloat = hasPhysicalNotch ? 0 : (isExpanded ? 28 : 0)
        let bottom: CGFloat = isExpanded ? 28 : (isPhysicalNotch ? 12 : 14)
        return UnevenRoundedRectangle(cornerRadii:.init(topLeading:top,bottomLeading:bottom,bottomTrailing:bottom,topTrailing:top),style:.continuous)
    }
    private var details: some View {
        IslandNativeScrollView {
            VStack(alignment:.leading,spacing:10) {
                HStack {
                    VStack(alignment:.leading,spacing:2) {
                        Text("Haloscope").font(.system(size:17,weight:.semibold))
                        Text(model.planType.map { L10n.format("plan.format",language:settings.language,$0) } ?? t("account.status"))
                            .font(.system(size:11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isMockData {
                        pill("MOCK",color:.yellow)
                    } else {
                        pill(model.bindingKind.localizedLabel(language:settings.language),color:accent)
                    }
                }

                section(t("quota.section"),icon:"gauge.with.dots.needle.50percent") {
                    quota(model.activeQuotaWindow,t("quota.unavailable_7d"))
                    HStack {
                        Label(t("quota.available_resets"),systemImage:"arrow.counterclockwise.circle")
                        Spacer()
                        Text(model.availableResetCredits.map(String.init) ?? "—")
                            .monospacedDigit()
                            .fontWeight(.semibold)
                    }
                    .font(.system(size:11))
                    .foregroundStyle(.secondary)
                }

                section(t("task.current"),icon:model.hasRecentThreadActivity ? "clock.arrow.circlepath":"moon") {
                    HStack(spacing:10) {
                        Circle()
                            .fill(statusColor.opacity(0.18))
                            .frame(width:30,height:30)
                            .overlay(
                                Image(systemName:model.hasRecentThreadActivity ? "clock.arrow.circlepath":"moon")
                                    .font(.system(size:12,weight:.bold))
                                    .foregroundStyle(statusColor)
                            )
                        VStack(alignment:.leading,spacing:2) {
                            Text(model.hasRecentThreadActivity ? t("task.recent_activity"):t("task.no_activity"))
                                .font(.system(size:13,weight:.medium))
                            Text(model.monitoredThread.map { threadTitle($0,emptyKey:"task.no_recent_thread") } ?? t("task.no_recent_thread"))
                                .font(.system(size:11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if let cwd=model.monitoredThread?.cwd {
                                Text(cwd).font(.system(size:9).monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                }

                section(t("threads.recent"),icon:"text.bubble") {
                    if model.threads.isEmpty {
                        empty(t("threads.empty"))
                    } else {
                        ForEach(model.threads.prefix(3)) { thread in threadRow(thread) }
                    }
                }

                section(t("usage.section"),icon:"chart.bar.xaxis") {
                    if let usage=model.usageSummary {
                        HStack(spacing:8) {
                            metric(t("usage.latest_day"),usage.buckets.last?.tokens ?? 0,subtitle:usage.buckets.last.map { formattedDate($0.startDate,dateStyle:.short,timeStyle:.none) })
                            metric(t("usage.seven_days"),usage.sum(days:7))
                            metric(t("usage.thirty_days"),usage.sum(days:30))
                        }
                    } else {
                        empty(t("usage.unavailable"))
                    }
                }

                if let usage=model.usageSummary {
                    section(t("stats.section"),icon:"chart.line.uptrend.xyaxis") { codexStatistics(usage) }
                }

                HStack(spacing:6) {
                    Circle().fill(connectionColor).frame(width:6,height:6)
                    Text(connectionLabel).font(.system(size:10))
                    Spacer()
                    if let date=model.threadDataUpdatedAt {
                        Text(formattedDate(date,dateStyle:.none,timeStyle:.short))
                            .font(.system(size:10).monospacedDigit())
                    }
                }
                .foregroundStyle(.tertiary)
                .padding(.horizontal,2)

                if let date=model.lastUpdated {
                    Text(L10n.format("quota.updated",language:settings.language,formattedDate(date,dateStyle:.none,timeStyle:.medium)))
                        .font(.system(size:9))
                        .foregroundStyle(.quaternary)
                }
                if let error=model.errorMessage {
                    Text(error).font(.system(size:10)).foregroundStyle(.red).lineLimit(2)
                }
            }
            .padding(.bottom,4)
            .frame(maxWidth:.infinity,alignment:.topLeading)
        }
        .frame(maxWidth:.infinity,maxHeight:.infinity)
    }

    private func section<Content:View>(_ title:String,icon:String,@ViewBuilder content:()->Content)->some View {
        VStack(alignment:.leading,spacing:9) {
            Label(title,systemImage:icon).font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary)
            content()
        }
        .padding(12)
        .frame(maxWidth:.infinity,alignment:.leading)
        .background(card,in:RoundedRectangle(cornerRadius:14,style:.continuous))
        .overlay(RoundedRectangle(cornerRadius:14,style:.continuous).stroke(border,lineWidth:0.7))
    }

    private func quota(_ value:RateWindow?,_ unavailable:String)->some View {
        Group {
            if let value {
                VStack(spacing:5) {
                    HStack {
                        Text(value.localizedDisplayName(language:settings.language)).font(.system(size:12,weight:.medium))
                        Spacer()
                        Text("\(value.roundedRemainingPercent)%").monospacedDigit().font(.system(size:12,weight:.semibold))
                    }
                    GeometryReader { proxy in
                        ZStack(alignment:.leading) {
                            Capsule().fill(Color.white.opacity(0.08))
                            Capsule().fill(accent).frame(width:proxy.size.width*value.remainingPercent/100)
                        }
                    }
                    .frame(height:4)
                    if let reset=value.resetsAt {
                        HStack {
                            Text(t("quota.reset_time"))
                            Spacer()
                            Text(formattedDate(reset,dateStyle:.medium,timeStyle:.short)).monospacedDigit()
                        }
                        .font(.system(size:9))
                        .foregroundStyle(.tertiary)
                    }
                }
            } else {
                empty(unavailable)
            }
        }
    }

    private func threadRow(_ thread:CodexThread)->some View {
        Button { model.selectThread(thread.id) } label: {
            HStack(spacing:9) {
                Image(systemName:thread.status == .active || thread.status == .waiting ? "circle.fill":"circle")
                    .font(.system(size:7))
                    .foregroundStyle(thread.status == .active || thread.status == .waiting ? accent:.secondary)
                VStack(alignment:.leading,spacing:2) {
                    Text(threadTitle(thread,emptyKey:"threads.untitled")).font(.system(size:12,weight:.medium)).lineLimit(1)
                    Text(formattedDate(thread.updatedAt,dateStyle:.none,timeStyle:.short)).font(.system(size:10)).foregroundStyle(.tertiary)
                }
                Spacer()
                Image(systemName:model.selectedThreadID == thread.id && settings.binding == .manual ? "checkmark":"chevron.right")
                    .font(.system(size:9,weight:.semibold))
                    .foregroundStyle(.quaternary)
            }
            .padding(.vertical,2)
        }
        .buttonStyle(.plain)
    }

    private func metric(_ label:String,_ value:Int,subtitle:String?=nil)->some View {
        VStack(alignment:.leading,spacing:3) {
            HStack(spacing:4) {
                Text(label).font(.system(size:9,weight:.medium))
                if let subtitle { Text(subtitle).font(.system(size:8)) }
            }
            .foregroundStyle(.tertiary)
            Text(compact(value)).font(.system(size:15,weight:.semibold).monospacedDigit())
        }
        .padding(9)
        .frame(maxWidth:.infinity,alignment:.leading)
        .background(Color.black.opacity(0.11),in:RoundedRectangle(cornerRadius:9,style:.continuous))
        .overlay(RoundedRectangle(cornerRadius:9,style:.continuous).stroke(Color.white.opacity(0.07),lineWidth:0.5))
    }

    private func codexStatistics(_ usage:UsageSummary)->some View {
        HStack(spacing:0) {
            statistic(t("stats.lifetime"),usage.lifetimeTokens.map(compact) ?? "—")
            divider
            statistic(t("stats.peak"),usage.peakDailyTokens.map(compact) ?? "—")
            divider
            statistic(t("stats.longest_task"),usage.longestRunningTurnSec.map(duration) ?? "—")
            divider
            statistic(t("stats.current_streak"),usage.currentStreakDays.map(days) ?? "—")
            divider
            statistic(t("stats.longest_streak"),usage.longestStreakDays.map(days) ?? "—")
        }
    }

    private func statistic(_ label:String,_ value:String)->some View {
        VStack(spacing:3) {
            Text(value).font(.system(size:13,weight:.semibold).monospacedDigit()).foregroundStyle(accent)
            Text(label).font(.system(size:8,weight:.medium)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth:.infinity)
    }

    private var divider: some View { Rectangle().fill(border).frame(width:1,height:31) }
    private func t(_ key:String)->String { L10n.text(key,language:settings.language) }
    private func compact(_ value:Int)->String { value.formatted(.number.notation(.compactName).locale(settings.language.locale)) }
    private func days(_ value:Int)->String { L10n.format(value == 1 ? "duration.day":"duration.days",language:settings.language,value) }
    private func duration(_ seconds:Int)->String {
        let hours=seconds/3600, minutes=(seconds%3600)/60
        return hours > 0
            ? L10n.format("duration.hours_minutes",language:settings.language,hours,minutes)
            : L10n.format("duration.minutes",language:settings.language,minutes)
    }
    private func formattedDate(_ date:Date,dateStyle:DateFormatter.Style,timeStyle:DateFormatter.Style)->String {
        let formatter=DateFormatter()
        formatter.locale=settings.language.locale
        formatter.dateStyle=dateStyle
        formatter.timeStyle=timeStyle
        return formatter.string(from:date)
    }
    private func threadTitle(_ thread:CodexThread,emptyKey:String)->String {
        switch thread.id {
        case "mock-running": return t("mock.running")
        case "mock-idle": return t("mock.history")
        default: return thread.preview ?? t(emptyKey)
        }
    }
    private func empty(_ text:String)->some View { Text(text).font(.system(size:11)).foregroundStyle(.tertiary) }
    private func pill(_ text:String,color:Color)->some View { Text(text).font(.system(size:9,weight:.bold)).foregroundStyle(color).padding(.horizontal,7).padding(.vertical,4).background(color.opacity(0.12),in:Capsule()) }
    private var connectionColor:Color { model.connection == .connected ? .green : model.connection == .connecting ? .yellow : model.connection == .error ? .red:.gray }
    private var connectionLabel:String { model.connection == .connected ? t("connection.persistent"):model.connection.localizedLabel(language:settings.language) }
    private var statusColor:Color { switch model.connection { case .error:.red; case .connecting:.yellow; case .connected:model.hasRecentThreadActivity ? .yellow:.gray; case .disconnected:.gray } }
    private var statusText:String { model.connection == .connected ? (model.hasRecentThreadActivity ? t("status.recent_activity"):t("status.no_activity")) : model.connection.localizedLabel(language:settings.language) }
    private func openCodexDesktop() { model.collapse(); if !CodexDesktopApplication.open() { NSSound.beep() } }
}

extension Notification.Name { static let haloscopeOpenSettings = Notification.Name("Haloscope.OpenSettings") }
