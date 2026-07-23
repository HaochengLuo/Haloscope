import XCTest
@testable import Haloscope

final class CoreTests: XCTestCase {
    @MainActor func testCodexDesktopApplicationUsesCanonicalBundleIdentifier() {
        let expected=URL(fileURLWithPath:"/Applications/Codex.app")
        var requestedIdentifier:String?
        let resolved=CodexDesktopApplication.resolve { identifier in requestedIdentifier=identifier; return expected }
        XCTAssertEqual(requestedIdentifier,"com.openai.codex")
        XCTAssertEqual(resolved,expected)
    }
    func testWidgetDeepLinksAcceptCurrentAndLegacySchemes() throws {
        XCTAssertTrue(HaloscopeDeepLink.handles(try XCTUnwrap(URL(string:"haloscope-widget://open"))))
        XCTAssertTrue(HaloscopeDeepLink.handles(try XCTUnwrap(URL(string:"HALOSCOPE://open"))))
        XCTAssertTrue(HaloscopeDeepLink.handles(try XCTUnwrap(URL(string:"codexisland://open"))))
        XCTAssertFalse(HaloscopeDeepLink.handles(try XCTUnwrap(URL(string:"https://example.com"))))
    }
    func testJSONRPCFraming() throws {
        let line = #"{"jsonrpc":"2.0","id":7,"result":{"ok":true}}"#.data(using:.utf8)!
        let value = try JSONDecoder().decode(RPCResponse.self, from:line)
        XCTAssertEqual(value.id, 7); XCTAssertNotNil(value.result)
    }
    func testUnknownEventCompatibility() throws {
        let line = #"{"jsonrpc":"2.0","method":"future/newEvent","params":{"newField":42}}"#.data(using:.utf8)!
        XCTAssertEqual(try JSONDecoder().decode(RPCResponse.self,from:line).method,"future/newEvent")
    }
    func testRealPayloadMapping() throws {
        let data = #"{"rateLimitsByLimitId":{"codex":{"limitId":"codex","planType":"plus","primary":{"usedPercent":2,"windowDurationMins":10080,"resetsAt":1784337015}}},"rateLimitResetCredits":{"availableCount":2,"credits":null}}"#.data(using:.utf8)!
        let snapshot = CodexPayloadDecoder().account(try JSONDecoder().decode(JSONValue.self,from:data))
        XCTAssertEqual(snapshot.planType,"plus"); XCTAssertEqual(snapshot.windows.count,1); XCTAssertEqual(snapshot.primaryWindow?.remainingPercent,98)
        XCTAssertEqual(snapshot.primaryWindow?.role,.primary); XCTAssertEqual(snapshot.primaryWindow?.limitID,"codex"); XCTAssertEqual(snapshot.availableResetCredits,2)
    }
    func testThreadPayloadMappingToleratesUnknownFields() throws {
        let data = #"{"data":[{"id":"t1","name":"Hello","updatedAt":1783750215,"status":{"type":"active","activeFlags":[]},"parentThreadId":null,"future":{"x":1}}]}"#.data(using:.utf8)!
        let threads=CodexPayloadDecoder().threads(try JSONDecoder().decode(JSONValue.self,from:data))
        XCTAssertEqual(threads.first?.id,"t1"); XCTAssertEqual(threads.first?.status,.active)
    }
    func testThreadPayloadMapsWaitingAndSystemErrorStates() throws {
        let data = #"{"data":[{"id":"waiting","updatedAt":1,"status":{"type":"active","activeFlags":["waitingOnApproval"]}},{"id":"error","updatedAt":1,"status":{"type":"systemError"}}]}"#.data(using:.utf8)!
        let threads=CodexPayloadDecoder().threads(try JSONDecoder().decode(JSONValue.self,from:data))
        XCTAssertEqual(threads.first{$0.id == "waiting"}?.status,.waiting)
        XCTAssertEqual(threads.first{$0.id == "error"}?.status,.error)
    }
    func testPartialRateLimitWindowIsPreserved() throws {
        let data = #"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":42,"windowDurationMins":null,"resetsAt":null}}}"#.data(using:.utf8)!
        let snapshot=CodexPayloadDecoder().account(try JSONDecoder().decode(JSONValue.self,from:data))
        XCTAssertEqual(snapshot.windows.first?.usedPercent,42)
        XCTAssertNil(snapshot.windows.first?.windowDurationMins)
        XCTAssertNil(snapshot.windows.first?.resetsAt)
    }
    func testContextNotificationMapping() throws {
        let data = #"{"threadId":"t1","turnId":"turn1","tokenUsage":{"modelContextWindow":200000,"total":{"inputTokens":100,"cachedInputTokens":50,"outputTokens":20,"reasoningOutputTokens":10,"totalTokens":180},"last":{"inputTokens":30,"cachedInputTokens":10,"outputTokens":8,"reasoningOutputTokens":2,"totalTokens":50}}}"#.data(using:.utf8)!
        let value=try JSONDecoder().decode(JSONValue.self,from:data), context=CodexPayloadDecoder().contextNotification(value)
        XCTAssertEqual(context?.threadID,"t1"); XCTAssertEqual(context?.modelContextWindow,200000); XCTAssertEqual(context?.total.total,180); XCTAssertEqual(context?.last.total,50)
    }
    func testRealtimeStatusNotificationMapping() throws {
        let data = #"{"threadId":"t1","status":{"type":"active","activeFlags":["waitingOnApproval"]}}"#.data(using:.utf8)!
        let status=CodexPayloadDecoder().statusNotification(try JSONDecoder().decode(JSONValue.self,from:data))
        XCTAssertEqual(status?.threadID,"t1"); XCTAssertEqual(status?.displayValue,"active · waitingOnApproval")
    }
    func testQuotaWindowRecognitionAndRemaining() {
        let q = RateWindow(id:"codex",usedPercent:37,windowDurationMins:10080,resetsAt:.now)
        XCTAssertEqual(q.localizedDisplayName(language:.simplifiedChinese),"7 天额度")
        XCTAssertEqual(q.localizedDisplayName(language:.english),"7-day quota")
        XCTAssertEqual(q.remainingPercent,63); XCTAssertEqual(q.roundedRemainingPercent,63)
        var over=q; over.usedPercent=120; XCTAssertEqual(over.remainingPercent,0)
        var under=q; under.usedPercent = -10; XCTAssertEqual(under.remainingPercent,100)
    }
    func testRefreshTimeParsing() throws { XCTAssertEqual(Date(timeIntervalSince1970:1783750215).timeIntervalSince1970,1783750215) }
    func testDailyBucketSevenAndThirtyDayAggregation() {
        var cal=Calendar(identifier:.gregorian); cal.timeZone=TimeZone(secondsFromGMT:0)!
        let now=Date(timeIntervalSince1970:1_800_000_000), start=cal.startOfDay(for:now)
        let buckets=(0..<35).map { DailyUsageBucket(startDate:cal.date(byAdding:.day,value:-$0,to:start)!,tokens:10) }
        let summary=UsageSummary(buckets:buckets,lifetimeTokens:nil,peakDailyTokens:nil)
        XCTAssertEqual(summary.sum(days:7,now:now,calendar:cal),70); XCTAssertEqual(summary.sum(days:30,now:now,calendar:cal),300)
    }
    func testThreadStateAggregation() { XCTAssertTrue([CodexThread(id:"a",updatedAt:.now,status:.active)].contains{$0.status == .active}) }
    func testSubagentTreeDedupAndParentTokenAggregation() {
        let u=TokenUsage(input:1,cachedInput:2,output:3,reasoningOutput:4)
        let nodes=[CodexThread(id:"p",updatedAt:.now,status:.active,tokenUsage:u),CodexThread(id:"c",updatedAt:.now,status:.active,parentThreadId:"p",tokenUsage:u),CodexThread(id:"g",updatedAt:.now,status:.idle,parentThreadId:"c",tokenUsage:u)]
        let graph=SubagentGraph(threads:nodes); XCTAssertEqual(Set(graph.descendants(of:"p").map(\.id)),["c","g"])
        XCTAssertEqual(graph.aggregateTokens(of:"p").usage.total,30); XCTAssertTrue(graph.aggregateTokens(of:"p").complete)
    }
    func testPartialTokenAggregation() {
        let nodes=[CodexThread(id:"p",updatedAt:.now,status:.active,tokenUsage:.init(input:1)),CodexThread(id:"c",updatedAt:.now,status:.active,parentThreadId:"p")]
        XCTAssertFalse(SubagentGraph(threads:nodes).aggregateTokens(of:"p").complete)
    }
    func testNotchGeometryAndCalibration() {
        let s=NotchGeometryService(), frame=CGRect(x:0,y:0,width:1512,height:982)
        let g=s.calculate(screenFrame:frame,visibleFrame:frame,safeTop:32,leftTop:CGRect(x:0,y:950,width:650,height:32),rightTop:CGRect(x:862,y:950,width:650,height:32),identifier:"built-in",calibration:.init(width:10,height:4,x:2,y:1))
        XCTAssertTrue(g.hasPhysicalNotch); XCTAssertEqual(g.detectedNotchFrame.width,212); XCTAssertEqual(g.effectiveNotchFrame.width,222)
        XCTAssertEqual(g.collapsedPanelFrame.midX,frame.midX); XCTAssertEqual(g.expandedPanelFrame.midX,frame.midX)
        XCTAssertEqual(g.collapsedPanelFrame.width,g.effectiveNotchFrame.width+12)
        XCTAssertEqual(g.collapsedPanelFrame.width-12,g.effectiveNotchFrame.width)
        XCTAssertEqual(PanelCanvasLayout.compactStatusWidth(for:g),min(g.effectiveNotchFrame.width,220))
        XCTAssertLessThanOrEqual(PanelCanvasLayout.compactStatusWidth(for:g),g.effectiveNotchFrame.width)
        XCTAssertEqual(PanelCanvasLayout.canvasFrame(for:g).maxY,frame.maxY)
        XCTAssertEqual(PanelCanvasLayout.islandFrame(for:g,state:.collapsedIdle).maxY,frame.maxY)
        XCTAssertEqual(PanelCanvasLayout.islandFrame(for:g,state:.expanded),g.expandedPanelFrame)
        XCTAssertEqual(g.collapsedPanelFrame.height,g.effectiveNotchFrame.height+22)
    }
    func testFixedCanvasContainsBothIslandStates() {
        let frame=CGRect(x:0,y:0,width:1512,height:982)
        let geometry=NotchGeometryService().calculate(screenFrame:frame,visibleFrame:frame,safeTop:32,leftTop:CGRect(x:0,y:950,width:650,height:32),rightTop:CGRect(x:862,y:950,width:650,height:32),identifier:"built-in")
        let canvas=PanelCanvasLayout.canvasFrame(for:geometry)
        XCTAssertTrue(canvas.contains(PanelCanvasLayout.islandFrame(for:geometry,state:.collapsedIdle)))
        XCTAssertTrue(canvas.contains(PanelCanvasLayout.islandFrame(for:geometry,state:.expanded)))
        XCTAssertGreaterThan(canvas.width,geometry.expandedPanelFrame.width)
        XCTAssertGreaterThan(canvas.height,geometry.expandedPanelFrame.height)
    }
    func testDetachedIslandKeepsTopGap() {
        let frame=CGRect(x:0,y:0,width:1920,height:1080)
        let geometry=NotchGeometryService().calculate(screenFrame:frame,visibleFrame:frame,safeTop:0,leftTop:nil,rightTop:nil,identifier:"external")
        let island=PanelCanvasLayout.islandFrame(for:geometry,state:.expanded)
        XCTAssertEqual(frame.maxY-island.maxY,PanelCanvasLayout.detachedTopGap)
    }
    func testIslandShellShapeUsesTransparentShouldersOnlyOnNotchDisplays() {
        let rect=CGRect(x:0,y:0,width:120,height:80)
        let attached=IslandShellShape(topRadius:18,bottomRadius:24,isDetached:false).path(in:rect)
        let detached=IslandShellShape(topRadius:18,bottomRadius:24,isDetached:true).path(in:rect)
        XCTAssertFalse(attached.contains(CGPoint(x:2,y:30)))
        XCTAssertTrue(attached.contains(CGPoint(x:22,y:30)))
        XCTAssertFalse(detached.contains(CGPoint(x:2,y:2)))
        XCTAssertTrue(detached.contains(CGPoint(x:60,y:2)))
    }
    func testNoNotchFallbackAndScreenSwitch() {
        let s=NotchGeometryService(), f=CGRect(x:0,y:0,width:1920,height:1080)
        let a=s.calculate(screenFrame:f,visibleFrame:f,safeTop:0,leftTop:nil,rightTop:nil,identifier:"a")
        let b=s.calculate(screenFrame:f.offsetBy(dx:1920,dy:0),visibleFrame:f,safeTop:0,leftTop:nil,rightTop:nil,identifier:"b")
        XCTAssertFalse(a.hasPhysicalNotch); XCTAssertNotEqual(a.screenIdentifier,b.screenIdentifier); XCTAssertNotEqual(a.collapsedPanelFrame.minX,b.collapsedPanelFrame.minX)
        XCTAssertEqual(PanelCanvasLayout.compactStatusWidth(for:a),220)
    }
    @MainActor func testPanelEventRoutingRequiresExpandedStateAndPointerPresence() {
        XCTAssertFalse(PanelEventRoutingPolicy.isInteractive(.collapsedIdle))
        XCTAssertTrue(PanelEventRoutingPolicy.isInteractive(.expanded))
        XCTAssertTrue(PanelEventRoutingPolicy.isInteractive(.settingsPresented))
        XCTAssertTrue(PanelEventRoutingPolicy.shouldCollapse(.expanded,isPinned:false,pointerInside:false))
        XCTAssertFalse(PanelEventRoutingPolicy.shouldCollapse(.expanded,isPinned:true,pointerInside:false))
        XCTAssertFalse(PanelEventRoutingPolicy.shouldCollapse(.expanded,isPinned:false,pointerInside:true))
    }
    @MainActor func testExpandedPanelClickRoutingIgnoresDragsAndCollapsedState() {
        let start=NSPoint(x:20,y:20)
        XCTAssertTrue(PanelPrimaryClickRoutingPolicy.shouldOpenCodex(state:.expanded,start:start,end:NSPoint(x:23,y:24)))
        XCTAssertFalse(PanelPrimaryClickRoutingPolicy.shouldOpenCodex(state:.expanded,start:start,end:NSPoint(x:40,y:20)))
        XCTAssertFalse(PanelPrimaryClickRoutingPolicy.shouldOpenCodex(state:.collapsedIdle,start:start,end:start))
        XCTAssertFalse(PanelPrimaryClickRoutingPolicy.shouldOpenCodex(state:.expanded,start:nil,end:start))
    }
    func testConnectionTransitionsPreserveInteractivePanelPresentation() {
        XCTAssertEqual(PanelPresentationPolicy.connectedState(from:.expanded),.expanded)
        XCTAssertEqual(PanelPresentationPolicy.failedState(from:.expanded),.expanded)
        XCTAssertEqual(PanelPresentationPolicy.connectedState(from:.settingsPresented),.settingsPresented)
        XCTAssertEqual(PanelPresentationPolicy.failedState(from:.settingsPresented),.settingsPresented)
        XCTAssertEqual(PanelPresentationPolicy.connectedState(from:.error),.collapsedIdle)
        XCTAssertEqual(PanelPresentationPolicy.failedState(from:.collapsedIdle),.error)
    }
    func testWidgetSnapshotCoordinatorPersistsSnapshots() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store = WidgetQuotaSnapshotStore(directoryURL:directory)
        let coordinator = WidgetSnapshotCoordinator(store:store,reloadTimelines:{})
        let snapshot = WidgetQuotaSnapshot(remainingPercent:64,windowDurationMins:10080,resetsAt:nil,availableResetCredits:2,planType:"plus",updatedAt:Date(timeIntervalSince1970:1_750_000_000),availability:.available,errorMessage:nil)
        await coordinator.publish(snapshot)
        XCTAssertEqual(try store.read(),snapshot)
    }
    func testWidgetTimelineReloadPolicyRefreshesInitiallyAndOnVisibleChanges() {
        let policy=WidgetTimelineReloadPolicy()
        let now=Date(timeIntervalSince1970:1_800_000_000)
        let snapshot=WidgetQuotaSnapshot(remainingPercent:64,windowDurationMins:10080,resetsAt:now.addingTimeInterval(3600),availableResetCredits:2,planType:"plus",updatedAt:now,availability:.available,errorMessage:nil)
        XCTAssertTrue(policy.shouldReload(snapshot:snapshot,previous:nil,hasRequestedReload:false))
        XCTAssertFalse(policy.shouldReload(snapshot:snapshot,previous:snapshot,hasRequestedReload:true))
        var changed=snapshot; changed.remainingPercent=63
        XCTAssertTrue(policy.shouldReload(snapshot:changed,previous:snapshot,hasRequestedReload:true))
        changed=snapshot; changed.remainingPercent=63.9
        XCTAssertFalse(policy.shouldReload(snapshot:changed,previous:snapshot,hasRequestedReload:true))
    }
    func testWidgetTimelineSchedulePrecomputesCountdownWithoutFrequentReloads() throws {
        let now=Date(timeIntervalSince1970:1_800_000_000)
        let reset=now.addingTimeInterval(7 * 24 * 60 * 60)
        let dates=WidgetTimelineSchedule.entryDates(now:now,resetAt:reset)
        XCTAssertEqual(dates.first,now)
        XCTAssertEqual(dates.last,reset)
        XCTAssertLessThanOrEqual(dates.count,WidgetTimelineSchedule.maximumEntryCount)
        XCTAssertTrue(zip(dates,dates.dropFirst()).allSatisfy { $0.0 < $0.1 })
        let finalDayDates=dates.filter { reset.timeIntervalSince($0) <= WidgetTimelineSchedule.fineWindow }
        let finalDayIntervals=zip(finalDayDates,finalDayDates.dropFirst()).map { $1.timeIntervalSince($0) }
        XCTAssertTrue(finalDayIntervals.allSatisfy { $0 <= WidgetTimelineSchedule.fineInterval })
        XCTAssertEqual(WidgetTimelineSchedule.entryDates(now:now,resetAt:nil),[now])
        XCTAssertEqual(WidgetTimelineSchedule.entryDates(now:now,resetAt:now),[now])
    }
    @MainActor func testInteractiveOverlayWindowPreservesRequestedTopEdge() {
        let panel=IslandPanel(contentRect:NSRect(x:0,y:0,width:220,height:38),styleMask:[.borderless,.fullSizeContentView],backing:.buffered,defer:false)
        let requested=NSRect(x:700,y:1052,width:220,height:55)
        XCTAssertFalse(panel.canBecomeKey)
        panel.interactionEnabled=true
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertEqual(panel.constrainFrameRect(requested,to:NSScreen.main),requested)
    }
    @MainActor func testIslandScrollViewOwnsNativeElasticMomentum() {
        let scrollView=IslandOwnedScrollView()
        XCTAssertEqual(scrollView.verticalScrollElasticity,.allowed)
        XCTAssertEqual(scrollView.horizontalScrollElasticity,.none)
        XCTAssertTrue(scrollView.usesPredominantAxisScrolling)
        XCTAssertFalse(scrollView.hasVerticalScroller)
        XCTAssertFalse(scrollView.drawsBackground)
    }
    func testCodexPathResolutionOrder() { XCTAssertEqual(CodexProcessResolver().resolve(custom:"/custom",home:"/home",executable:{$0 == "/custom"}),"/custom") }
    func testReconnectBackoff() { let b=Backoff(base:1,maximum:8); XCTAssertEqual(b.delay(attempt:0),1); XCTAssertEqual(b.delay(attempt:8),8) }
    func testOnlyTransportErrorsTriggerReconnect() {
        XCTAssertTrue(RPCError.timeout.shouldReconnect)
        XCTAssertTrue(RPCError.disconnected.shouldReconnect)
        XCTAssertFalse(RPCError.malformed.shouldReconnect)
        XCTAssertFalse(RPCError.server(.object(["code":.number(-1)])).shouldReconnect)
        XCTAssertTrue(RPCError.server(.object(["code":.number(-32603)])).shouldRetryWithoutReconnect)
        XCTAssertFalse(RPCError.server(.object(["code":.number(-32601)])).shouldRetryWithoutReconnect)
    }
    func testInternalServerErrorRetryPolicyUsesBoundedBackoff() {
        let policy=RPCRequestRetryPolicy()
        let transient=RPCError.server(.object(["code":.number(-32603)]))
        XCTAssertEqual(policy.delay(afterFailure:0,error:transient),0.75)
        XCTAssertEqual(policy.delay(afterFailure:1,error:transient),2)
        XCTAssertEqual(policy.delay(afterFailure:2,error:transient),5)
        XCTAssertNil(policy.delay(afterFailure:3,error:transient))
        XCTAssertNil(policy.delay(afterFailure:0,error:RPCError.server(.object(["code":.number(-32601)]))))
        XCTAssertNil(policy.delay(afterFailure:0,error:RPCError.timeout))
    }
    @MainActor func testSettingsPersistence() {
        let suite="HaloscopeTests-\(UUID())", widgetSuite="HaloscopeWidgetTests-\(UUID())"
        let d=UserDefaults(suiteName:suite)!, widgetDefaults=UserDefaults(suiteName:widgetSuite)!
        defer { d.removePersistentDomain(forName:suite); widgetDefaults.removePersistentDomain(forName:widgetSuite) }
        let s=SettingsStore(defaults:d,widgetDefaults:widgetDefaults); s.experimental=true; s.binding = .running; s.selectedThreadID = "thread-1"; s.language = .english; s.islandAppearance = .liquidGlass; s.liquidGlassCardOpacity = 0.21; s.liquidGlassTextColor = .black
        let restored=SettingsStore(defaults:UserDefaults(suiteName:suite)!,widgetDefaults:widgetDefaults)
        XCTAssertTrue(UserDefaults(suiteName:suite)!.bool(forKey:"experimental")); XCTAssertEqual(restored.binding,.running); XCTAssertEqual(restored.selectedThreadID,"thread-1"); XCTAssertEqual(restored.language,.english); XCTAssertEqual(restored.islandAppearance,.liquidGlass); XCTAssertEqual(restored.liquidGlassCardOpacity,0.20); XCTAssertEqual(restored.liquidGlassTextColor,.black)
        XCTAssertEqual(SharedLanguagePreference.read(from:widgetDefaults),.english)
    }
    func testLiquidGlassCardOpacityUsesFivePercentStepsThroughSeventyPercent() {
        XCTAssertEqual(IslandAppearance.liquidGlassCardOpacityRange,0.0...0.70)
        XCTAssertEqual(IslandAppearance.liquidGlassCardOpacityStep,0.05)
        XCTAssertEqual(IslandAppearance.normalizedLiquidGlassCardOpacity(-0.2),0)
        XCTAssertEqual(IslandAppearance.normalizedLiquidGlassCardOpacity(0.21),0.20)
        XCTAssertEqual(IslandAppearance.normalizedLiquidGlassCardOpacity(0.68),0.70)
        XCTAssertEqual(IslandAppearance.normalizedLiquidGlassCardOpacity(1.2),0.70)
    }
    func testLanguageResolutionAndTranslations() {
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages:["zh-Hans-CN"]),.simplifiedChinese)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages:["en-US"]),.english)
        XCTAssertEqual(AppLanguage.english.displayName(in:.simplifiedChinese),"English")
        XCTAssertEqual(L10n.text("quota.section",language:.english),"Account Quota")
        XCTAssertEqual(L10n.text("quota.section",language:.simplifiedChinese),"账户额度")
        XCTAssertEqual(L10n.format("rate.minutes",language:.english,300),"300-minute quota")
        XCTAssertEqual(L10n.text("settings.tab.codex",language:.english),"Codex")
        XCTAssertEqual(L10n.text("settings.tab.display",language:.english),"Displays")
        XCTAssertEqual(IslandAppearance.liquidGlass.localizedLabel(language:.simplifiedChinese),"Liquid Glass · 全透明")
        XCTAssertEqual(LiquidGlassTextColor.black.localizedLabel(language:.simplifiedChinese),"黑色")
    }
    func testWidgetQuotaSnapshotStoreRoundTripAndStaleness() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("HaloscopeTests-\(UUID())",isDirectory:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store=WidgetQuotaSnapshotStore(directoryURL:directory)
        let now=Date(timeIntervalSince1970:1_800_000_000)
        let snapshot=WidgetQuotaSnapshot(remainingPercent:98.4,windowDurationMins:10080,resetsAt:now.addingTimeInterval(3600),availableResetCredits:2,planType:"plus",updatedAt:now,availability:.available,errorMessage:nil)
        XCTAssertNil(try store.read())
        try store.write(snapshot)
        let restored=try XCTUnwrap(store.read())
        XCTAssertEqual(restored,snapshot); XCTAssertEqual(restored.roundedRemainingPercent,98)
        XCTAssertFalse(restored.isStale(at:now.addingTimeInterval(599))); XCTAssertTrue(restored.isStale(at:now.addingTimeInterval(601)))
        var timestampOnly=restored; timestampOnly.updatedAt=now.addingTimeInterval(60)
        XCTAssertFalse(timestampOnly.materiallyDiffers(from:restored))
        var changed=restored; changed.availableResetCredits=1
        XCTAssertTrue(changed.materiallyDiffers(from:restored))
    }
}
