import SwiftUI
import WidgetKit

private let widgetKind = "CodexWeeklyQuotaWidget"

struct CodexQuotaEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetQuotaSnapshot
}

struct CodexQuotaProvider: TimelineProvider {
    private let store = WidgetQuotaSnapshotStore()

    func placeholder(in context: Context) -> CodexQuotaEntry {
        .init(date:.now,snapshot:previewSnapshot)
    }

    private var previewSnapshot: WidgetQuotaSnapshot {
        .init(
            remainingPercent:98,
            windowDurationMins:10080,
            resetsAt:.now.addingTimeInterval(6 * 86_400 + 22 * 3_600),
            availableResetCredits:2,
            planType:"plus",
            updatedAt:.now,
            availability:.available,
            errorMessage:nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (CodexQuotaEntry) -> Void) {
        completion(.init(date:.now,snapshot:loadSnapshot(preview:context.isPreview)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CodexQuotaEntry>) -> Void) {
        let now = Date.now
        let entry = CodexQuotaEntry(date:now,snapshot:loadSnapshot(preview:false))
        completion(Timeline(entries:[entry],policy:.after(now.addingTimeInterval(30 * 60))))
    }

    private func loadSnapshot(preview: Bool) -> WidgetQuotaSnapshot {
        if preview { return previewSnapshot }
        do { return try store.read() ?? .unavailable(localized("widget.open_app")) }
        catch { return .unavailable(localized("widget.signing_required")) }
    }
}

struct CodexQuotaWidgetView: View {
    var entry: CodexQuotaEntry
    private var language: AppLanguage { SharedLanguagePreference.widgetLanguage() }

    var body: some View {
        GeometryReader { proxy in
            if let percent = entry.snapshot.roundedRemainingPercent, entry.snapshot.availability == .available {
                availableContent(percent,size:proxy.size)
            } else {
                unavailableContent(size:proxy.size)
            }
        }
        .foregroundStyle(Color.white)
        .containerBackground(for:.widget) {
            Color.clear
        }
        .environment(\.locale,language.locale)
        .widgetURL(URL(string:"haloscope-widget://open"))
    }

    private var header: some View {
        ZStack {
            Text("Codex")
                .font(.system(size:15,weight:.semibold,design:.rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            HStack {
                Spacer()
                glassPill(
                    Text("7D")
                        .font(.system(size:11,weight:.bold,design:.rounded))
                        .monospacedDigit()
                )
            }
        }
    }

    private func availableContent(_ percent: Int,size: CGSize) -> some View {
        ZStack {
            header
                .frame(width:max(0,size.width - 24))
                .position(x:size.width * 0.5,y:size.height * 0.13)

            HStack(alignment:.lastTextBaseline,spacing:2) {
                Text(percent.formatted())
                    .font(.system(size:48,weight:.semibold,design:.rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.68)
                Text("%")
                    .font(.system(size:24,weight:.medium,design:.rounded))
                    .foregroundStyle(Color.white.opacity(0.72))
            }
            .position(x:size.width * 0.5,y:size.height * 0.415)

            Text(localized("widget.left"))
                .font(.system(size:12.5,weight:.medium,design:.rounded))
                .foregroundStyle(Color.white.opacity(0.80))
                .position(x:size.width * 0.5,y:size.height * 0.625)

            LiquidGlassProgressBar(value:Double(percent) / 100)
                .frame(width:max(0,size.width - 24),height:7.5)
                .position(x:size.width * 0.5,y:size.height * 0.755)

            footer
                .frame(width:max(0,size.width - 20))
                .position(x:size.width * 0.5,y:size.height * 0.89)
        }
        .accessibilityElement(children:.combine)
        .accessibilityLabel("\(percent)% \(localized("widget.left"))")
    }

    private func unavailableContent(size: CGSize) -> some View {
        VStack(spacing:4) {
            header
            Spacer()
            Text("—%")
                .font(.system(size:46,weight:.semibold,design:.rounded))
                .foregroundStyle(Color.white.opacity(0.72))
            Text(localized("widget.open_app"))
                .font(.system(size:11,weight:.medium,design:.rounded))
                .foregroundStyle(Color.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Spacer()
            footer
        }
        .padding(.horizontal,12)
        .padding(.vertical,10)
        .frame(width:size.width,height:size.height)
    }

    private var footer: some View {
        HStack(spacing:5) {
            if entry.snapshot.isStale(at:entry.date,maxAge:90 * 60), entry.snapshot.availability == .available {
                Image(systemName:"exclamationmark.circle.fill")
                    .font(.system(size:9))
                    .foregroundStyle(.orange)
                    .accessibilityLabel(localized("widget.stale"))
            }
            Text(resetText)
                .font(.system(size:11.5,weight:.regular,design:.rounded))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.80))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth:.infinity)
    }

    @ViewBuilder private func glassPill<Content: View>(_ content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .padding(.horizontal,6)
                .padding(.vertical,4)
                .glassEffect(.regular,in:Capsule())
        } else {
            content
                .padding(.horizontal,6)
                .padding(.vertical,4)
                .background(.thinMaterial,in:Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.18),lineWidth:0.7))
        }
    }

    private var resetText: String {
        guard let reset = entry.snapshot.resetsAt else { return localized("widget.reset_unavailable") }
        guard reset > entry.date else { return localized("widget.waiting_refresh") }
        let remaining = remainingDescription(from:entry.date,to:reset)
        return L10n.format("widget.resets_in",language:language,remaining)
    }

    private func remainingDescription(from start: Date,to end: Date) -> String {
        let seconds = max(0,Int(end.timeIntervalSince(start)))
        if seconds >= 86_400 {
            let dayCount = seconds / 86_400
            let hourCount = (seconds % 86_400) / 3_600
            return hourCount > 0
                ? L10n.format("widget.duration.days_hours",language:language,dayCount,hourCount)
                : L10n.format("widget.duration.days",language:language,dayCount)
        }
        let hourCount = seconds / 3_600
        let minuteCount = (seconds % 3_600) / 60
        if hourCount > 0 {
            return minuteCount > 0
                ? L10n.format("widget.duration.hours_minutes",language:language,hourCount,minuteCount)
                : L10n.format("widget.duration.hours",language:language,hourCount)
        }
        return L10n.format("widget.duration.minutes",language:language,minuteCount)
    }

}

struct LiquidGlassProgressBar: View {
    var value: Double

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(1,max(0,value))
            let fillWidth = proxy.size.width * clamped
            ZStack(alignment:.leading) {
                Capsule()
                    .fill(Color.white.opacity(0.13))
                    .overlay(Capsule().stroke(Color.white.opacity(0.20),lineWidth:0.6))
                Capsule()
                    .fill(LinearGradient(
                        colors:[Color.white,Color.white.opacity(0.93)],
                        startPoint:.top,
                        endPoint:.bottom
                    ))
                    .frame(width:fillWidth)
                    .overlay(alignment:.top) {
                        Capsule().fill(Color.white.opacity(0.72)).frame(height:1).padding(.horizontal,3).padding(.top,1)
                    }
                    .shadow(color:Color.white.opacity(0.34),radius:4)
                    .widgetAccentable()
            }
        }
        .frame(height:7.5)
        .accessibilityHidden(true)
    }
}

struct CodexWeeklyQuotaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind:widgetKind,provider:CodexQuotaProvider()) { entry in
            CodexQuotaWidgetView(entry:entry)
        }
        .configurationDisplayName(localized("widget.name"))
        .description(localized("widget.description"))
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
        .containerBackgroundRemovable(true)
    }
}

@main struct HaloscopeWidgetBundle: WidgetBundle {
    var body: some Widget { CodexWeeklyQuotaWidget() }
}

private func localized(_ key: String) -> String {
    L10n.text(key,language:SharedLanguagePreference.widgetLanguage())
}
