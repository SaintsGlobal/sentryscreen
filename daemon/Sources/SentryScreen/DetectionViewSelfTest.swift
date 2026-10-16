import AppKit
import Foundation

// `--ui-selftest` group "detection-view" (SENTRY_UI_SELFTEST_CASE=
// detection-view runs it alone): the Detection view's controller, overlay
// and UI (workstream B). Headless: no window is ever ordered on screen and
// nothing is installed; the overlay renders into a bare layer tree. Set
// SENTRY_DETECTION_VIEW_PNG=/abs/path/prefix to also write the fixed
// synthetic trace to <prefix>-detections-only.png and
// <prefix>-outline-over-covers.png.
//
// The flavor half runs in BOTH builds: a production binary must carry none of
// the view's markers (the needles are assembled at runtime from pieces too
// short to be stored as literals, so this file cannot plant them itself).
extension UISelfTest {
    static func caseOverlayFlavor(_ dir: String) {
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        guard let bytes = FileManager.default.contents(atPath: path) else {
            check("overlay-flavor: the self-test can read its own binary", false, path)
            return
        }
        let needles = [
            ["detection", "-snapshot"].joined(),
            ["exclusion-", "unconfirmed"].joined(),
            ["ui.status", ".detection", "view"].joined(),
            ["Protection off", " · Detection view"].joined(),
        ]
        let camel = [["Detection", "View"].joined(), ["Detection", "Trace"].joined()]
        for n in needles {
            check("overlay-flavor: the binary carries the marker \"\(n)\"", bytes.range(of: Data(n.utf8)) != nil)
        }
        _ = camel
    }
}

/// The pipeline side, faked around a REAL `CaptureStream` (never started):
/// `refreshExclusion` updates the stream's re-arm set synchronously and its
/// Task returns at once for want of a stream, so the test drives every
/// exclusion result by hand.
private final class FakeDetectionViewHost: DetectionViewHost {
    let detectionTraceBus = DetectionTraceBus()
    var detectionViewSuppressesCovers = false
    weak var detectionView: DetectionViewController?
    let capture = CaptureStream(onFrame: { _ in })
    var coverWindowNumber: Int? = 900_001
    var traceAllowed = true
    var syntheticAllowed = true
    var traceOn = false
    var syntheticOn = false
    var clears = 0
    /// `restoreCoversForDetectionView` calls, and whether suppression was
    /// already off at each (it must be: the pipeline's guard needs it).
    var restores: [Bool] = []
    var detectionViewUnavailable: String?
    /// When set, clears go through the REAL paint-only clear, as Pipeline's.
    var overlays: OverlayManager?
    /// Every exclusion request: the ids, and whether the view's window was
    /// still on screen (not yet ordered out) when it was made.
    var refreshes: [(ids: [Int], windowStillUp: Bool)] = []
    var detectionViewScreen: (frame: CGRect, topInset: CGFloat, scale: CGFloat)? =
        (CGRect(x: 0, y: 0, width: 1440, height: 900), 25, 2)

    var exclusionWindowNumbers: [Int] {
        Pipeline.exclusionWindowNumbers(
            covers: coverWindowNumber.map { [$0] } ?? [], detectionView: detectionView?.excludedWindowNumber)
    }

    func setDetectionTrace(enabled: Bool) -> Bool {
        guard traceAllowed else { return false }
        traceOn = enabled
        return true
    }

    func setSyntheticDetections(enabled: Bool) -> Bool {
        guard syntheticAllowed || !enabled else { return false }
        syntheticOn = enabled
        return true
    }

    /// Every floor the controller asked for, nil = off.
    var weakFloors: [Float?] = []
    func setWeakDetections(floor: Float?) -> Bool {
        weakFloors.append(floor)
        return true
    }

    func clearCoversForDetectionView() {
        clears += 1
        overlays?.clearPaint()
    }

    func restoreCoversForDetectionView() { restores.append(!detectionViewSuppressesCovers) }

    var newestExclusionRequest: Int { capture.newestExclusionRequest }

    /// An answer to the newest request (what Capture reports).
    func result(_ ids: Set<Int>, applied: Bool = true) -> CaptureStream.ExclusionResult {
        .init(applied: applied, ids: ids, request: newestExclusionRequest)
    }

    func refreshDetectionViewExclusion() {
        let ids = exclusionWindowNumbers
        refreshes.append((ids, detectionView?.overlay != nil))
        capture.refreshExclusion(windowNumbers: ids)
    }

    func setExclusionHandler(_ handler: ((CaptureStream.ExclusionResult) -> Void)?) {
        capture.onExclusionResult = handler
    }
}

extension UISelfTest {
    static func caseDetectionView(_ dir: String) {
        caseOverlayFlavor(dir)
        check("detection-view: modes are off / detections-only / outline-over-covers",
            DetectionViewMode.allCases.map(\.rawValue)
                == ["off", "detections-only", "outline-over-covers"])
        check("detection-view: the run-log events never ship in a diagnostics report",
            !DiagnosticsAllowlist.runEvents.contains(DetectionViewEvent.lifecycle)
                && !DiagnosticsAllowlist.runEvents.contains(DetectionViewEvent.snapshot))
        detectionViewWindowRules()
        detectionViewHandshake()
        detectionViewTurnOff()
        detectionViewCoverSuppression()
        detectionViewPaintOnlyClear()
        detectionViewCopyAndLayout(dir)
        detectionViewSnapshot()
        detectionViewLabels()
        detectionViewWeak()
        detectionViewHUDTripwires()
        detectionViewUI(dir)
    }

    /// The HUD's trace warning uses the tripwire's own figure (lookups out),
    /// and crowded chips are named, not silent.
    private static func detectionViewHUDTripwires() {
        func trace(traceMs: Double, lookupMs: Double) -> DetectionTrace {
            let t = fixedTrace()
            return DetectionTrace(
                seq: t.seq, capturedAt: t.capturedAt, builtAt: t.builtAt, screenPt: t.screenPt, policy: t.policy,
                coverMode: t.coverMode, tuning: t.tuning, tuningSource: t.tuningSource,
                detectorFailed: false, boxes: t.boxes, boxesOverflow: 0, walkUnattributed: 0, walk: t.walk,
                windows: t.windows,
                stats: .init(evaluatedFps: 20, detectMs: 10, stepMs: 12, idleSkipped: 0, traceMs: traceMs,
                    lookupMs: lookupMs))
        }
        func warnings(_ t: DetectionTrace, crowded: Int = 0) -> [String] {
            DetectionViewCopy.hud(t, now: t.builtAt, drawMs: 3, overBudgetMs: nil, hiddenNonPolicy: 0,
                synthetic: false, crowded: crowded).filter(\.warning).map(\.text)
        }
        check("hud: a cold app-name lookup (4.97 ms, a test Mac's) does not trip the trace warning",
            !warnings(trace(traceMs: 5.0, lookupMs: 4.97)).contains { $0.contains("traceBudgetMs") })
        check("hud: trace work over budget without lookups is named",
            warnings(trace(traceMs: 3.0, lookupMs: 0.5)).contains { $0.contains("2.5 ms") && $0.contains("traceBudgetMs") })
        check("hud: crowded chips are named with DetectionViewLayout.scanSteps",
            warnings(trace(traceMs: 0, lookupMs: 0), crowded: 2).contains { $0.hasPrefix("2 label(s)") && $0.contains("scanSteps") }
                && !warnings(trace(traceMs: 0, lookupMs: 0)).contains { $0.contains("scanSteps") })
    }

    // MARK: Window rules (SPEC §8)

    private static func detectionViewWindowRules() {
        let win = DetectionViewOverlay.makeWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        defer { win.close() }
        check("detection-view window: click-through by the one overlay rule (UIOverlayWindow)",
            win.ignoresMouseEvents && win.ignoresMouseEvents == UIOverlayWindow.ignoresMouseEvents(hasControls: false))
        let popover = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        check("detection-view window: the cover window's level (.screenSaver), below the popover's, never 1001",
            win.level == .screenSaver && win.level < popover && win.level.rawValue != 1001, "\(win.level.rawValue)")
        check("detection-view window: every Space, stationary, over fullscreen (the cover window's behavior)",
            win.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]))
        check("detection-view window: transparent, no shadow, sharingType untouched (exclusion does the hiding)",
            !win.isOpaque && !win.hasShadow && win.backgroundColor == .clear && win.sharingType == .readOnly)
        check("detection-view window: built but never ordered on screen by the self-test", !win.isVisible)
    }

    // MARK: B1 exclusion handshake

    /// "Show weak detections": off by default, sets the host's NMS floor
    /// only while the view is on, clamps the slider, clears on turn-off.
    private static func detectionViewWeak() {
        let host = FakeDetectionViewHost()
        let c = makeController(host)
        check("weak: off by default, floor at Pipeline.weakFloorMin",
            !c.showWeak && c.weakFloor == Pipeline.weakFloorMin && host.weakFloors.isEmpty)
        c.setShowWeak(true)
        check("weak: toggling while the view is off asks the host nothing", host.weakFloors.isEmpty)
        _ = c.turnOn(.outlineOverCovers)
        check("weak: turning the view on applies the toggle's floor",
            host.weakFloors.last.flatMap { $0 } == Pipeline.weakFloorMin, "\(host.weakFloors)")
        c.setWeakFloor(0.9)
        check("weak: the slider clamps under the 0.25 detector floor",
            c.weakFloor < DetectionViewController.weakMax && host.weakFloors.last.flatMap { $0 } == c.weakFloor)
        c.setWeakFloor(0.01)
        check("weak: the slider clamps at the model floor", c.weakFloor == Pipeline.weakFloorMin)
        let options = c.options()
        check("weak: the overlay options carry the toggle", options.showWeak)
        c.turnOff(reason: .user)
        check("weak: turning the view off clears the floor and the toggle",
            !c.showWeak && host.weakFloors.last.map { $0 == nil } == true, "\(host.weakFloors)")
        // The overlay hides weak boxes when the toggle is off, shows them and
        // their legend line when on.
        let weakBox = DetectionTrace.Box(index: 0, synthetic: false, rawLabel: "FACE_FEMALE", label: "FACE_FEMALE",
            confidence: 0.1, rect: CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1), sidePt: 100, demotion: nil,
            policy: .weak(conf: 0.25), region: nil, curtain: nil)
        let t = DetectionTrace(
            seq: 1, capturedAt: 0, builtAt: 0, screenPt: CGSize(width: 1440, height: 900),
            policy: .standard, coverMode: "region", tuning: .defaults, tuningSource: "defaults",
            detectorFailed: false, boxes: [weakBox], boxesOverflow: 0, walkUnattributed: 0, walk: .notCurtainMode,
            windows: [], stats: .init(evaluatedFps: 0, detectMs: 0, stepMs: 0, idleSkipped: 0, traceMs: 0))
        var o = DetectionViewLayout.Options(mode: .outlineOverCovers, now: 0, remaining: 60, showNonPolicy: false,
            synthetic: false)
        let hidden = DetectionViewLayout.make(t, size: CGSize(width: 1440, height: 900), options: o)
        o.showWeak = true
        let shown = DetectionViewLayout.make(t, size: CGSize(width: 1440, height: 900), options: o)
        let legendLine = DetectionViewCopy.legendText(.weak, mode: .outlineOverCovers)
        check("weak: overlay draws weak boxes and their legend line only with the toggle on",
            hidden.items.isEmpty && !hidden.legend.lines.contains(legendLine)
                && shown.items.count == 1 && shown.legend.lines.contains(legendLine)
                && shown.items[0].ink == DetectionViewInk.of(.weak))
    }

    private static func makeController(_ host: FakeDetectionViewHost, clock: @escaping () -> Date = Date.init,
        log: @escaping (String, String) -> Void = { _, _ in }) -> DetectionViewController
    {
        let c = DetectionViewController(clock: clock)
        c.presentsWindow = false
        c.log = log
        c.copyToClipboard = { _ in }
        c.attach(host)
        return c
    }

    private static func detectionViewHandshake() {
        check("exclusion order: only the newest refresh request may apply or report", {
            let o = ExclusionRequestOrder()
            let a = o.next(), b = o.next()
            return !o.isNewest(a) && o.isNewest(b)
        }())
        check("exclusion rule: covers + the view's window while on; exactly the covers otherwise",
            Pipeline.exclusionWindowNumbers(covers: [7], detectionView: 9) == [7, 9]
                && Pipeline.exclusionWindowNumbers(covers: [7], detectionView: nil) == [7]
                && Pipeline.exclusionWindowNumbers(covers: [], detectionView: nil) == [])

        let host = FakeDetectionViewHost()
        var t = Date(timeIntervalSinceReferenceDate: 1_000)
        var records: [String] = []
        let c = makeController(host, clock: { t }, log: { records.append($1) })
        check("handshake: attach wires the host back to the controller and the capture result hook",
            host.detectionView === c && host.capture.onExclusionResult != nil)
        let on = c.turnOn(.outlineOverCovers)
        guard on, let overlay = c.overlay, let id = overlay.windowNumber, let cover = host.coverWindowNumber else {
            check("handshake: turns on with a window number", false, "on=\(on) refusal=\(c.refusal ?? "-")")
            return
        }
        check("handshake: on ⇒ one exclusion request carrying the cover window AND ours",
            host.refreshes.last?.ids == [cover, id] && host.capture.excludedWindowNumbers == [cover, id],
            "\(host.refreshes.map(\.ids))")
        check("handshake: nothing is drawn before capture confirms (layers hidden, awaiting)",
            !overlay.isVisible && c.exclusion == .awaiting)
        host.detectionTraceBus.publish(fixedTrace())
        spinMain()
        check("handshake: a trace that arrives unconfirmed is not drawn",
            !overlay.isVisible && overlay.lastLayout.items.isEmpty)

        let before = host.refreshes.count
        c.exclusionResult(host.result([cover]))
        check("handshake: a result WITHOUT our id keeps the layers hidden and asks again",
            !overlay.isVisible && c.exclusion == .awaiting && host.refreshes.count == before + 1
                && host.refreshes.last?.ids == [cover, id])
        t += 0.25
        c.exclusionResult(host.result([cover, id]))
        check("handshake: the latest result names our window ⇒ visible, and the waiting trace is drawn",
            overlay.isVisible && c.exclusion == .confirmed && !overlay.lastLayout.items.isEmpty)
        check("handshake: the visible record carries the wait since turn-on (waitedMs)",
            records.last?.hasPrefix("state=visible") == true && records.last?.hasSuffix("waitedMs=250") == true,
            records.last ?? "-")
        c.exclusionResult(host.result([cover]))
        check("handshake: a LATER result without our id hides the layers again at once",
            !overlay.isVisible && c.exclusion == .awaiting)
        c.exclusionResult(host.result([cover, id]))
        // Ordering 1: the old stream's answer lands AFTER the rebuild.
        let beforeRebuild = host.result([cover, id])
        c.streamInvalidated()
        check("handshake: a stream rebuild hides until the re-arm's refresh reconfirms",
            !overlay.isVisible && c.exclusion == .awaiting)
        c.exclusionResult(beforeRebuild)
        check("handshake: an answer to a request made BEFORE the rebuild (the old stream's filter) is ignored",
            !overlay.isVisible && c.exclusion == .awaiting)
        host.refreshDetectionViewExclusion()  // the re-arm's own refresh (Capture.finishRearm)
        c.exclusionResult(host.result([cover, id]))
        check("handshake: reconfirmed by the re-arm's refresh ⇒ visible again", overlay.isVisible)

        // Capture's own retry budget bounds unconfirmed results.
        let budget = CaptureStream.exclusionAttemptBudget
        for _ in 0..<budget { c.exclusionResult(host.result([cover])) }
        check("handshake: \(budget) unconfirmed results in a row (Capture's budget) ⇒ off, refused by name",
            !c.isOn && c.refusal?.contains("Capture.refreshExclusion") == true
                && !host.capture.excludedWindowNumbers.contains(id),
            "on=\(c.isOn) refusal=\(c.refusal ?? "-")")

        c.turnOn(.outlineOverCovers)
        let id2 = c.overlay?.windowNumber ?? -1
        c.exclusionResult(host.result([], applied: false))
        check("handshake: capture's final failure ⇒ off at once, refused by name, no dead id left behind",
            !c.isOn && c.refusal == DetectionViewCopy.refusedExclusion(budget: budget)
                && !host.capture.excludedWindowNumbers.contains(id2))

        // Ordering 2: quick off → on. The first session's answers land
        // after the second session's request and must decide nothing.
        c.turnOn(.outlineOverCovers)
        let firstSession = host.result([cover, c.overlay?.windowNumber ?? -1])
        let firstFailure = host.result([], applied: false)
        c.turnOff(reason: .user)
        c.turnOn(.outlineOverCovers)
        let refreshesBefore = host.refreshes.count
        c.exclusionResult(firstFailure)
        c.exclusionResult(firstSession)
        check("handshake: quick off → on — the first session's failure and answer are ignored "
            + "(still on, still awaiting, no extra request)",
            c.isOn && c.exclusion == .awaiting && host.refreshes.count == refreshesBefore)
        c.exclusionResult(host.result(Set(host.exclusionWindowNumbers)))
        check("handshake: quick off → on — the second session confirms on its own answer",
            c.exclusion == .confirmed)
        c.turnOff(reason: .user)

        let headless = FakeDetectionViewHost()
        headless.traceAllowed = false
        let h = makeController(headless)
        check("handshake: refused under --process/--replay ⇒ no window, no exclusion request, named",
            !h.turnOn(.detectionsOnly) && h.overlay == nil && headless.refreshes.isEmpty
                && h.refusal == DetectionViewCopy.refusedHeadless)
        let orphan = DetectionViewController()
        orphan.log = { _, _ in }
        check("handshake: no pipeline attached ⇒ refused by name",
            !orphan.turnOn(.outlineOverCovers) && orphan.refusal == DetectionViewCopy.refusedNoPipeline)
        for why in [DetectionViewCopy.refusedPaused, DetectionViewCopy.refusedNoCapture] {
            let blocked = FakeDetectionViewHost()
            blocked.detectionViewUnavailable = why
            let b = makeController(blocked)
            check("handshake: refused by name while \(why.hasPrefix("Protection is paused") ? "paused" : "capture is nil") "
                + "— never \"on\" with nothing drawn",
                !b.turnOn(.detectionsOnly) && !b.isOn && b.overlay == nil && blocked.refreshes.isEmpty
                    && b.refusal == why)
        }
    }

    // MARK: B2 turning off

    private static func detectionViewTurnOff() {
        var t = Date(timeIntervalSince1970: 1_000_000)
        var records: [(String, String)] = []
        let host = FakeDetectionViewHost()
        let c = makeController(host, clock: { t }, log: { records.append(($0, $1)) })

        func onConfirmed(_ mode: DetectionViewMode) -> Int {
            c.turnOn(mode)
            let id = c.overlay?.windowNumber ?? -1
            c.exclusionResult(host.result(Set(host.exclusionWindowNumbers)))
            return id
        }
        func lastOff() -> String { records.last { $0.1.hasPrefix("state=off") }?.1 ?? "-" }

        let id = onConfirmed(.detectionsOnly)
        c.turnOff(reason: .user)
        let offRefresh = host.refreshes.last
        check("off: our id leaves the exclusion set in a request made BEFORE the window is ordered out",
            offRefresh?.ids == [900_001] && offRefresh?.windowStillUp == true,
            "\(String(describing: offRefresh))")
        check("off: capture's re-arm set holds no dead id", host.capture.excludedWindowNumbers == [900_001])
        host.refreshDetectionViewExclusion()  // the next cover-window refresh
        check("off: no later refresh carries the dead id",
            host.refreshes.last?.ids == [900_001] && !host.refreshes.last!.ids.contains(id))
        check("off: trace, synthetic and cover suppression all released; overlay gone",
            !host.traceOn && !host.syntheticOn && !host.detectionViewSuppressesCovers && c.overlay == nil
                && host.detectionTraceBus.onTrace == nil)
        check("off: the record names the reason and that covers were repainted",
            lastOff().contains("reason=turned-off") && lastOff().contains("covers repainted"), lastOff())

        host.coverWindowNumber = nil
        _ = onConfirmed(.outlineOverCovers)
        c.turnOff(reason: .user)
        check("off: with no cover window yet the request is EMPTY (no dead id, nothing to retry)",
            host.refreshes.last?.ids == [] && host.capture.excludedWindowNumbers == [])
        host.coverWindowNumber = 900_001

        // TTL on an injected clock.
        _ = onConfirmed(.detectionsOnly)
        t += DetectionViewController.ttlSecs - 1
        c.tick()
        check("ttl: still on one second before \(Int(DetectionViewController.ttlSecs)) s", c.isOn)
        t += 1
        c.tick()
        check("ttl: off at \(Int(DetectionViewController.ttlSecs)) s, reason logged",
            !c.isOn && lastOff().contains("reason=ttl-expired") && lastOff().contains("after=300s"), lastOff())

        _ = onConfirmed(.outlineOverCovers)
        t += 200
        c.renew()
        t += 200
        c.tick()
        check("ttl: Renew restarts the five minutes", c.isOn && c.remaining == 100)
        c.turnOff(reason: .user)

        // Each safety-rail reason turns it off and is on the record. The
        // pipeline hooks (panic hold before its prompt, enterPause,
        // shutdown) are one call each in main.swift.
        for reason: DetectionViewController.OffReason in [.panicHotkey, .panicPause, .parentPause, .shutdown] {
            _ = onConfirmed(.detectionsOnly)
            c.turnOff(reason: reason)
            check("off: \(reason.rawValue) turns it off, restores covers, logs the reason",
                !c.isOn && !host.detectionViewSuppressesCovers && lastOff().contains("reason=\(reason.rawValue)"),
                lastOff())
        }

        // A pipeline rebuild: attaching a new host detaches the old one.
        _ = onConfirmed(.detectionsOnly)
        let next = FakeDetectionViewHost()
        c.attach(next)
        check("rebuild: attaching a new pipeline turns the view off on the old one and unhooks it",
            !c.isOn && lastOff().contains("reason=pipeline-rebuild") && host.detectionView == nil
                && host.capture.onExclusionResult == nil && !host.detectionViewSuppressesCovers
                && next.detectionView === c)
        check("in memory only: a fresh controller (every agent start) is off",
            DetectionViewController().mode == .off)
    }

    // MARK: Detections only ⇄ covers

    private static func detectionViewCoverSuppression() {
        let host = FakeDetectionViewHost()
        let c = makeController(host)
        c.turnOn(.detectionsOnly)
        check("mode a: covers stay up until the view is visibly on screen",
            !host.detectionViewSuppressesCovers && host.clears == 0)
        c.exclusionResult(host.result(Set(host.exclusionWindowNumbers)))
        check("mode a: confirmed ⇒ suppress new paints AND clear the covers already up",
            host.detectionViewSuppressesCovers && host.clears == 1)
        let L = c.overlay?.lastLayout
        check("mode a: before the first detector frame the red badge, legend and a waiting HUD are drawn",
            c.overlay?.showsDangerBadge == true && L?.hud.lines == [DetectionViewCopy.hudWaiting]
                && L?.badge.lines.first?.hasPrefix(DetectionViewCopy.protectionOffHeader) == true
                && L?.legend.lines.isEmpty == false && L?.items.isEmpty == true,
            "\(L?.hud.lines ?? []) \(L?.badge.lines ?? [])")
        c.streamInvalidated()
        check("mode a: hidden (stream rebuild) ⇒ covers repainted at once; protection is never off without the badge",
            !host.detectionViewSuppressesCovers && host.restores == [true] && c.overlay?.showsDangerBadge == false)
        host.refreshDetectionViewExclusion()
        c.exclusionResult(host.result(Set(host.exclusionWindowNumbers)))
        check("mode a: reconfirmed ⇒ suppressed again, covers painted meanwhile cleared",
            host.detectionViewSuppressesCovers && host.clears == 2)
        c.turnOn(.outlineOverCovers)
        check("mode a → b: covers repainted synchronously (no frame needed), the window and TTL stay",
            !host.detectionViewSuppressesCovers && host.restores == [true, true] && c.isOn && c.overlay != nil)
        c.turnOn(.detectionsOnly)
        check("mode b → a: covers cleared again, only once the red badge is drawn",
            host.detectionViewSuppressesCovers && host.clears == 3 && c.overlay?.showsDangerBadge == true)
        c.turnOff(reason: .user)
        check("mode a off: with no new frame, covers are repainted before turnOff returns",
            !host.detectionViewSuppressesCovers && host.restores == [true, true, true])
        c.setSynthetic(true)
        check("synthetic: off-state preference only; nothing reaches the pipeline", !host.syntheticOn)
        c.turnOn(.outlineOverCovers)
        check("synthetic: applied when the view turns on", host.syntheticOn)
        c.turnOff(reason: .user)
        check("synthetic: turning the view off clears it", !host.syntheticOn && !c.synthetic)

        // The pipeline refuses synthetic boxes while a crop writer is attached.
        host.syntheticAllowed = false
        c.setSynthetic(true)
        c.turnOn(.outlineOverCovers)
        check("synthetic refused at turn-on ⇒ the toggle reads off and the refusal names it",
            c.isOn && !c.synthetic && !host.syntheticOn && c.refusal == DetectionViewCopy.refusedSynthetic)
        c.setSynthetic(true)
        check("synthetic refused while on ⇒ the toggle reads off", !c.synthetic && !host.syntheticOn)
        c.turnOff(reason: .user)

        // DetectionViewHeldPaint: what the pipeline repaints on restore.
        typealias H = DetectionViewHeldPaint
        func frame(_ g: UInt64, at t: CFAbsoluteTime) -> H.Frame {
            .init(generation: g, regions: [], painted: [], anchors: [], capturedAt: t, curtains: [], owners: [:])
        }
        func replay(_ h: H) -> [String] {
            var calls: [String] = []
            _ = h.replay(isCurrent: { $0 == 2 }, sync: { calls.append("frame@\($0.capturedAt)"); return false },
                syncCurtains: { calls.append("tick@\($0.at)"); return false })
            return calls
        }
        var held = H()
        check("held paint: nothing held ⇒ nothing repainted", replay(held).isEmpty)
        held.frame = frame(2, at: 10)
        held.tick = .init(generation: 2, curtains: [], at: 11)
        check("held paint: the held frame, then a NEWER curtain tick, in that order",
            replay(held) == ["frame@10.0", "tick@11.0"], "\(replay(held))")
        held.tick = .init(generation: 2, curtains: [], at: 9)
        check("held paint: a tick older than the frame is not replayed over it", replay(held) == ["frame@10.0"])
        held.frame = frame(1, at: 10)
        check("held paint: a frame from a rebuilt (stale) stream is skipped", replay(held) == ["tick@9.0"])
    }

    /// Detections only clears PAINT only: the WindowTracker the curtain
    /// shares keeps its state across a mode (a) on/off. The fake host's
    /// clear is the pipeline's (`OverlayManager.clearPaint`) on a real
    /// overlay manager and a real, polling tracker.
    private static func detectionViewPaintOnlyClear() {
        let id: CGWindowID = 7301
        let wt = WindowTracker()
        wt.windowSource = {
            [[
                "kCGWindowNumber": id, "kCGWindowOwnerName": "Preview", "kCGWindowLayer": 0,
                "kCGWindowAlpha": 1.0, "kCGWindowOwnerPID": pid_t(1),
                "kCGWindowBounds": ["X": 100.0, "Y": 120.0, "Width": 600.0, "Height": 400.0],
            ] as [String: Any]]
        }
        wt.screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        wt.onReceipt = { _ in }
        wt.start()
        defer { wt.stop() }
        wt.setTracked([id])
        let deadline = Date(timeIntervalSinceNow: 2)
        while wt.latestFrame(of: id) == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let overlays = OverlayManager()
        overlays.windowTracker = wt
        let host = FakeDetectionViewHost()
        host.overlays = overlays
        let c = makeController(host)
        let before = wt.latestFrame(of: id)
        c.turnOn(.detectionsOnly)
        c.exclusionResult(host.result(Set(host.exclusionWindowNumbers)))
        c.turnOff(reason: .user)
        check("paint-only clear: mode (a) on/off cleared covers but left the curtain's WindowTracker "
            + "state alone (tracked window still sampled)",
            before != nil && host.clears == 1 && wt.latestFrame(of: id) != nil,
            "before=\(String(describing: before)) after=\(String(describing: wt.latestFrame(of: id)))")
        overlays.clearAll()
        check("paint-only clear: the panic path's clearAll still resets the tracker",
            wt.latestFrame(of: id) == nil)
    }

    // MARK: B3 copy, styles, layout

    static func fixedTrace(overflow: Int = 0) -> DetectionTrace {
        typealias B = DetectionTrace.Box
        func box(_ i: Int, _ label: String, _ conf: Float, _ r: CGRect, _ policy: DetectionTrace.PolicyOutcome,
            raw: String? = nil, demotion: DetectionTrace.Demotion? = nil, region: DetectionTrace.RegionOutcome? = nil,
            curtain: DetectionTrace.CurtainOutcome? = nil, synthetic: Bool = false) -> B
        {
            B(index: i, synthetic: synthetic, rawLabel: raw ?? label, label: label, confidence: conf, rect: r,
                sidePt: Double(min(r.width * 1440, r.height * 900)), demotion: demotion, policy: policy,
                region: region, curtain: curtain)
        }
        var tuning = TuningPolicy.defaults
        tuning.standard["ANUS_EXPOSED"]?.minBoxPt = 24
        tuning.standard["MALE_GENITALIA_EXPOSED"]?.thresholdSteps = [.init(minPt: 64, threshold: 0.9)]
        let boxes: [B] = [
            box(0, "FEMALE_BREAST_EXPOSED", 0.83, CGRect(x: 0.10, y: 0.38, width: 0.10, height: 0.16),
                .passes(floor: 0.5, sizeUnmeasured: false), region: .underCurtain, curtain: .credited(window: 4312),
                synthetic: true),
            box(1, "MALE_GENITALIA_EXPOSED", 0.41, CGRect(x: 0.30, y: 0.66, width: 0.06, height: 0.09),
                .belowThreshold(threshold: 0.5)),
            box(2, "FEMALE_BREAST_COVERED", 0.88, CGRect(x: 0.47, y: 0.36, width: 0.05, height: 0.07),
                .classOffInPolicy(mode: .standard), raw: "FEMALE_BREAST_EXPOSED",
                demotion: .init(to: "FEMALE_BREAST_COVERED", overlap: 1.0, minOverlap: 0.9)),
            box(3, "FEMALE_BREAST_COVERED", 0.72, CGRect(x: 0.45, y: 0.33, width: 0.10, height: 0.14),
                .classOffInPolicy(mode: .standard)),
            box(4, "BUTTOCKS_EXPOSED", 0.77, CGRect(x: 0.72, y: 0.36, width: 0.12, height: 0.14),
                .passes(floor: 0.5, sizeUnmeasured: false), region: .entryPending(seen: 1, needed: 2),
                curtain: .credited(window: 5120)),
            box(5, "ANUS_EXPOSED", 0.90, CGRect(x: 0.36, y: 0.20, width: 0.011, height: 0.018),
                .minBox(sidePt: 16, minBoxPt: 24, minBoxFraction: 0)),
            box(6, "FACE_FEMALE", 0.93, CGRect(x: 0.60, y: 0.66, width: 0.07, height: 0.11), .notPolicyClass),
            box(7, "FEMALE_GENITALIA_EXPOSED", 0.81, CGRect(x: 0.86, y: 0.74, width: 0.06, height: 0.08),
                .passes(floor: 0.5, sizeUnmeasured: false), region: .entryPending(seen: 1, needed: 2),
                curtain: .orphan),
            box(8, "MALE_GENITALIA_EXPOSED", 0.79, CGRect(x: 0.14, y: 0.70, width: 0.07, height: 0.11),
                .thresholdStep(floor: 0.9, stepMinPt: 64, base: 0.5)),
            box(9, "BUTTOCKS_EXPOSED", 0.66, CGRect(x: 0.63, y: 0.52, width: 0.09, height: 0.10),
                .passes(floor: 0.5, sizeUnmeasured: false), region: .covered(regionID: 3),
                curtain: .straddle(front: 5120, held: 0.42, rewoundTo: nil)),
            box(10, "MALE_GENITALIA_EXPOSED", 0.68, CGRect(x: 0.22, y: 0.18, width: 0.06, height: 0.08),
                .passes(floor: 0.5, sizeUnmeasured: false), region: .entryPending(seen: 1, needed: 2)),
        ]
        return DetectionTrace(
            seq: 1234, capturedAt: CFAbsoluteTimeGetCurrent() - 0.2, builtAt: CFAbsoluteTimeGetCurrent() - 0.2,
            screenPt: CGSize(width: 1440, height: 900), policy: .standard, coverMode: "curtain", tuning: tuning,
            tuningSource: "tuning.json", detectorFailed: false, boxes: boxes, boxesOverflow: overflow,
            walkUnattributed: 0, walk: .ran,
            windows: [
                .init(id: 4312, app: "Safari", frame: CGRect(x: 90.0 / 1440, y: 250.0 / 900, width: 440.0 / 1440, height: 330.0 / 900),
                    state: .curtained(holdLeftSecs: 3.4, cleanFrames: 2, cleanNeeded: 20)),
                .init(id: 5120, app: "Preview", frame: CGRect(x: 980.0 / 1440, y: 250.0 / 900, width: 380.0 / 1440, height: 300.0 / 900),
                    state: .pending(hits: 2, required: 3, bar: .trigger)),
            ],
            stats: .init(evaluatedFps: 11.8, detectMs: 21.4, stepMs: 27.9, idleSkipped: 3, traceMs: 0.6))
    }

    /// Synthetic region-mode trace for the steadiness render: one kept box, one
    /// box a settle re-check raised, two weak boxes.
    static func steadinessTrace() -> DetectionTrace {
        func box(_ i: Int, _ label: String, _ conf: Float, _ r: CGRect, _ policy: DetectionTrace.PolicyOutcome,
            region: DetectionTrace.RegionOutcome? = nil, recheckFrom: Float? = nil) -> DetectionTrace.Box
        {
            DetectionTrace.Box(index: i, synthetic: true, rawLabel: label, label: label, confidence: conf, rect: r,
                sidePt: Double(min(r.width * 1440, r.height * 900)), demotion: nil, policy: policy,
                region: region, curtain: nil, recheckFrom: recheckFrom)
        }
        let boxes = [
            box(0, "BUTTOCKS_EXPOSED", 0.43, CGRect(x: 0.18, y: 0.30, width: 0.12, height: 0.16),
                .kept(start: 0.5, keep: 0.35, sizeUnmeasured: false), region: .covered(regionID: 7)),
            box(1, "FEMALE_BREAST_EXPOSED", 0.58, CGRect(x: 0.46, y: 0.34, width: 0.09, height: 0.12),
                .passes(floor: 0.5, sizeUnmeasured: false), region: .covered(regionID: 8), recheckFrom: 0.44),
            box(2, "MALE_GENITALIA_EXPOSED", 0.19, CGRect(x: 0.70, y: 0.30, width: 0.07, height: 0.10),
                .weak(conf: 0.25)),
            box(3, "ANUS_EXPOSED", 0.08, CGRect(x: 0.30, y: 0.62, width: 0.05, height: 0.07), .weak(conf: 0.25)),
        ]
        return DetectionTrace(
            seq: 88, capturedAt: CFAbsoluteTimeGetCurrent() - 0.1, builtAt: CFAbsoluteTimeGetCurrent() - 0.1,
            screenPt: CGSize(width: 1440, height: 900), policy: .standard, coverMode: "region", tuning: .defaults,
            tuningSource: "defaults", detectorFailed: false, boxes: boxes, boxesOverflow: 0, walkUnattributed: 0,
            walk: .notCurtainMode, windows: [],
            stats: .init(evaluatedFps: 10, detectMs: 19.8, stepMs: 23.1, idleSkipped: 2, traceMs: 0.4))
    }

    private static func options(_ mode: DetectionViewMode, showNonPolicy: Bool = false,
        overBudgetMs: Double? = nil) -> DetectionViewLayout.Options
    {
        DetectionViewLayout.Options(mode: mode, now: CFAbsoluteTimeGetCurrent(), remaining: 252,
            showNonPolicy: showNonPolicy, synthetic: true, drawMs: 1.2, overBudgetMs: overBudgetMs,
            topInset: 25)
    }

    private static func detectionViewCopyAndLayout(_ dir: String) {
        let trace = fixedTrace(overflow: 5)
        func explain(_ i: Int, _ mode: DetectionViewMode = .outlineOverCovers) -> DetectionViewExplanation {
            DetectionViewCopy.explain(trace.boxes[i], trace: trace, mode: mode)
        }
        let classOff = "covered-class boxes block only in Strict (now Standard)"
        let expected: [(Int, DetectionViewStyle, String)] = [
            (0, .covered, "walk: credited to window 4312"),
            (1, .belowThreshold, "below threshold 0.41 < 0.50"),
            (2, .dropped, classOff),
            (3, .dropped, classOff),
            (4, .pending, "window 5120 · 2/3 hits (triggerHits)"),
            (5, .dropped, "min box 16 < 24 pt (minBoxPt)"),
            (6, .nonPolicy, "not a policy class — never covered"),
            (7, .pending, "no window under it (orphan)"),
            (8, .dropped, "size step 0.79 < 0.90 from 64 pt (thresholdSteps)"),
            (9, .covered, "straddles window 5120: 0.42 inside < 0.75"),
            (10, .pending, "entry 1/2 frames (entryFrames)"),
        ]
        for (i, style, line) in expected {
            let e = explain(i)
            check("copy: box \(i) ⇒ \(style.rawValue): \"\(line)\"", e.style == style && e.lines.last == line,
                "\(e.style.rawValue) \(e.lines)")
        }
        check("copy: a demotion names the covered label and the overlap rule on its own line",
            explain(2).lines.first == "demoted → FEMALE_BREAST_COVERED (overlap 1.00 ≥ 0.90)"
                && explain(2).ruleKey == "coveredOverlap")
        check("copy: under a painted curtain ⇒ covered by the curtain, the walk's result a secondary line",
            explain(0).lines == ["covered by a curtain (window 4312)", "walk: credited to window 4312"]
                && explain(0).outcome == "under-curtain")
        check("copy: Detections only says WOULD be covered — covers are hidden",
            explain(0, .detectionsOnly).lines.first == "would be covered by a curtain (window 4312)")
        func variant(_ i: Int, region: DetectionTrace.RegionOutcome?, curtain: DetectionTrace.CurtainOutcome?)
            -> DetectionViewExplanation
        {
            let b = trace.boxes[i]
            let v = DetectionTrace.Box(index: b.index, synthetic: b.synthetic, rawLabel: b.rawLabel, label: b.label,
                confidence: b.confidence, rect: b.rect, sidePt: b.sidePt, demotion: b.demotion, policy: b.policy,
                region: region, curtain: curtain)
            return DetectionViewCopy.explain(v, trace: trace, mode: .outlineOverCovers)
        }
        let skipped = variant(0, region: .underCurtain, curtain: .walkSkipped)
        check("copy: a skipped walk never makes a painted box pending (under a curtain stays covered)",
            skipped.style == .covered && skipped.lines.first == "covered by a curtain (window 4312)",
            "\(skipped.style.rawValue) \(skipped.lines)")
        let held = variant(9, region: nil, curtain: .straddle(front: 5120, held: 0.42, rewoundTo: 4312))
        check("copy: a straddle whose holder's content holds the box says it was credited there",
            held.lines == ["straddles window 5120: 0.42 inside < 0.75",
                "credited to window 4312 (its content holds the box)", "covered · window 4312 curtained"],
            "\(held.lines)")
        let orphan = variant(7, region: nil, curtain: .orphan)
        check("copy: curtain walk checks are dropped with ruleKind constant; sensitivity and --roi say so",
            orphan.style == .dropped && orphan.ruleKind == .constant
                && explain(3).ruleKind == .sensitivity && explain(2).ruleKind == .tuning
                && explain(5).ruleKind == .tuning && explain(9).ruleKind == nil
                && variant(1, region: nil, curtain: nil).ruleKind == .tuning)
        check("copy: every decision names its rule key and the value that would flip it (min box)",
            explain(5).ruleKey == "classes.ANUS_EXPOSED.minBoxPt" && explain(5).flipsAt == "minBoxPt ≤ 16")
        check("copy: curtain windows say hits vs bar, or hold left",
            DetectionViewCopy.windowState(trace.windows[1], mode: .outlineOverCovers)
                == "2/3 hits (triggerHits) · no curtain yet"
                && DetectionViewCopy.windowState(trace.windows[0], mode: .outlineOverCovers)
                == "curtained · lifts in 3.4 s (holdSecs) · clean 2/20 (holdCleanFrames)")
        check("copy: countdown reads m:ss", DetectionViewCopy.countdown(252) == "4:12"
            && DetectionViewCopy.countdown(0) == "0:00" && DetectionViewCopy.countdown(59.2) == "1:00")

        let overlay = DetectionViewOverlay(size: CGSize(width: 1440, height: 900), scale: 2, window: nil)
        overlay.render(trace, options: options(.detectionsOnly, overBudgetMs: 21.3))
        let L = overlay.lastLayout
        check("layout: non-policy classes hidden by default and counted in the HUD",
            L.hiddenNonPolicy == 1 && !L.items.contains { $0.kind == .box(index: 6) }
                && L.hud.lines.contains { $0.contains("1 non-policy hidden") })
        let shown = DetectionViewLayout.make(trace, size: overlay.size, options: options(.detectionsOnly, showNonPolicy: true))
        check("layout: \"Show non-policy classes\" draws them, faint", shown.hiddenNonPolicy == 0
            && shown.items.first { $0.kind == .box(index: 6) }?.ink.faint == true)
        check("layout: every visible box and window has an outline and a chip",
            L.items.count == trace.boxes.count - 1 + trace.windows.count)
        let safari = L.items.first { $0.kind == .window(id: 4312) }?.outline ?? .null
        let covered = L.items.first { $0.kind == .box(index: 0) }?.outline ?? .null
        func near(_ r: CGRect, _ e: CGRect) -> Bool {
            abs(r.minX - e.minX) < 0.01 && abs(r.minY - e.minY) < 0.01 && abs(r.width - e.width) < 0.01
                && abs(r.height - e.height) < 0.01
        }
        check("layout: box rects and window frames are normalized top-left, scaled to display points",
            near(safari, CGRect(x: 90, y: 250, width: 440, height: 330))
                && near(covered, CGRect(x: 144, y: 342, width: 144, height: 144)), "\(safari) \(covered)")
        let styles = Set(L.items.compactMap(\.explanation?.style))
        check("layout: the fixed trace shows every drawn style",
            styles == [.covered, .pending, .dropped, .belowThreshold], "\(styles)")
        check("layout: colour AND line style differ for each decision",
            Set(DetectionViewStyle.allCases.map { DetectionViewInk.of($0).dash }).count >= 3
                && Set(DetectionViewStyle.allCases.map { DetectionViewInk.of($0).color }).count
                    == DetectionViewStyle.allCases.count)
        let chips = L.items.map(\.chip.frame)
        var overlaps = 0
        for i in chips.indices { for j in chips.indices where j > i && chips[i].intersects(chips[j].insetBy(dx: 1, dy: 1)) { overlaps += 1 } }
        check("layout: no two labels overlap on the fixed trace (crowded \(L.crowded))", overlaps == 0 && L.crowded == 0,
            "overlaps=\(overlaps)")
        let boxRects = L.items.compactMap { item -> (Int, CGRect)? in
            if case let .box(i) = item.kind { return (i, item.outline) }
            return nil
        }
        let onOtherBoxes = L.items.filter { item in
            boxRects.contains { idx, r in item.kind != .box(index: idx) && r.intersects(item.chip.frame.insetBy(dx: 1, dy: 1)) }
        }.map(\.kind)
        check("layout: on the fixed trace no label sits on another box's outline or inside it",
            onOtherBoxes.isEmpty, "\(onOtherBoxes)")
        let chrome = [L.badge.frame, L.hud.frame, L.legend.frame]
        check("layout: labels keep clear of the badge, HUD and legend",
            !chips.contains { c in chrome.contains { $0.intersects(c.insetBy(dx: 1, dy: 1)) } })
        let screen = CGRect(origin: .zero, size: overlay.size)
        check("layout: every label is on screen and below the menu bar",
            chips.allSatisfy { screen.contains($0) && $0.minY >= 25 })
        check("layout: legend bottom-left names each style and the window outline",
            L.legend.frame.minX == DetectionViewLayout.margin && L.legend.frame.maxY == overlay.size.height - DetectionViewLayout.margin
                && L.legend.lines.first == DetectionViewCopy.legendTitle
                && L.legend.lines.contains(DetectionViewCopy.legendText(.covered, mode: .detectionsOnly))
                && L.legend.lines.contains(DetectionViewCopy.legendWindow))
        check("badge: Detections only is the red 'Protection off' badge with the time left",
            L.badgeDanger && L.badge.lines.first == "Protection off · Detection view · 4:12"
                && L.badge.lines.last == DetectionViewCopy.badgeOffSubtitle)
        let b = DetectionViewLayout.make(trace, size: overlay.size, options: options(.outlineOverCovers))
        check("badge: Outline over covers is the calm badge",
            !b.badgeDanger && b.badge.lines == ["Detection view · outlines over covers · 4:12"])
        check("hud: overflow and draw budget are named with their budget keys",
            L.hud.lines.contains("+5 not drawn (DetectionTraceBuilder.maxBoxes \(DetectionTraceBuilder.maxBoxes))")
                && L.hud.lines.contains { $0.contains("(DetectionViewOverlay.renderBudgetMs)") }
                && L.hudWarnings.count == 3)
        check("hud: tuning changes, entry frames and curtain bars are listed",
            L.hud.lines.contains { $0.hasPrefix("changed: ANUS_EXPOSED.minBoxPt 24, MALE_GENITALIA_EXPOSED.thresholdSteps") }
                && L.hud.lines.contains("entryFrames 2 · triggerHits 3 · handoffHits 2 · paroleHits 2 · holdSecs 5.0")
                && L.hud.lines.contains("curtain walk: ran"))

        // A crowded frame: 30 boxes stacked on one spot still produce
        // readable labels (moved, with leaders) and count what could not fit.
        var crowdedBoxes: [DetectionTrace.Box] = []
        for i in 0..<30 {
            crowdedBoxes.append(.init(index: i, synthetic: true, rawLabel: "BUTTOCKS_EXPOSED", label: "BUTTOCKS_EXPOSED",
                confidence: 0.6, rect: CGRect(x: 0.5, y: 0.5, width: 0.05, height: 0.05), sidePt: 45, demotion: nil,
                policy: .belowThreshold(threshold: 0.7), region: nil, curtain: nil))
        }
        let crowded = DetectionTrace(seq: 1, capturedAt: 0, builtAt: 0, screenPt: CGSize(width: 1440, height: 900),
            policy: .standard, coverMode: "region", tuning: .defaults, tuningSource: "defaults", detectorFailed: false,
            boxes: crowdedBoxes, boxesOverflow: 0, walkUnattributed: 0, walk: .notCurtainMode, windows: [],
            stats: trace.stats)
        let C = DetectionViewLayout.make(crowded, size: overlay.size, options: options(.outlineOverCovers))
        let cc = C.items.map(\.chip.frame)
        var coOverlaps = 0
        for i in cc.indices { for j in cc.indices where j > i && cc[i].intersects(cc[j].insetBy(dx: 1, dy: 1)) { coOverlaps += 1 } }
        check("layout: 30 labels on one spot are spread out with leader lines; any that cannot fit are counted",
            C.items.filter { $0.chip.leader != nil }.count > 0 && (coOverlaps == 0 || C.crowded > 0),
            "overlaps=\(coOverlaps) crowded=\(C.crowded)")

        // Render cost (the renderBudgetMs receipt's measurement).
        var stress: [DetectionTrace.Box] = []
        for i in 0..<69 {
            let base = trace.boxes[i % trace.boxes.count]
            let x = 0.05 + Double(i % 10) * 0.09, y = 0.12 + Double(i / 10) * 0.11
            stress.append(.init(index: i, synthetic: true, rawLabel: base.rawLabel, label: base.label,
                confidence: base.confidence, rect: CGRect(x: x, y: y, width: 0.06, height: 0.07), sidePt: 60,
                demotion: base.demotion, policy: base.policy, region: base.region, curtain: base.curtain))
        }
        let stressTrace = DetectionTrace(seq: 2, capturedAt: 0, builtAt: 0, screenPt: CGSize(width: 1440, height: 900),
            policy: .standard, coverMode: "curtain", tuning: trace.tuning, tuningSource: "tuning.json",
            detectorFailed: false, boxes: stress, boxesOverflow: 5, walkUnattributed: 0, walk: .ran,
            windows: trace.windows, stats: trace.stats)
        let costOverlay = DetectionViewOverlay(size: CGSize(width: 1440, height: 900), scale: 2, window: nil)
        costOverlay.setVisible(true)
        var ms: [Double] = []
        for _ in 0..<30 { ms.append(costOverlay.render(stressTrace, options: options(.outlineOverCovers, showNonPolicy: true))) }
        ms.sort()
        print(String(format: "# measure: detection-view render, 69-box stress trace, 30 runs: first %.2f ms, "
            + "median %.2f ms, p90 %.2f ms, max %.2f ms (budget %.1f ms)",
            ms.first ?? 0, ms[ms.count / 2], ms[ms.count * 9 / 10], ms.last ?? 0, DetectionViewOverlay.renderBudgetMs))
        check("render cost: the stress trace's median draw is inside renderBudgetMs",
            ms[ms.count / 2] < DetectionViewOverlay.renderBudgetMs)
        let c = DetectionViewController()
        var budgetRecords = 0
        c.log = { _, info in if info.contains("budget DetectionViewOverlay.renderBudgetMs") { budgetRecords += 1 } }
        c.noteDrawCost(DetectionViewOverlay.renderBudgetMs + 5)
        c.noteDrawCost(DetectionViewOverlay.renderBudgetMs + 9)
        c.noteDrawCost(1)
        c.noteDrawCost(DetectionViewOverlay.renderBudgetMs + 1)
        check("render cost: over budget ⇒ one named record per episode, not per frame", budgetRecords == 2)

        // Optional PNGs of the fixed synthetic trace (visual iteration).
        if let prefix = ProcessInfo.processInfo.environment["SENTRY_DETECTION_VIEW_PNG"], prefix.hasPrefix("/") {
            for mode in [DetectionViewMode.detectionsOnly, .outlineOverCovers] {
                let o = DetectionViewOverlay(size: CGSize(width: 1440, height: 900), scale: 2, window: nil)
                o.render(fixedTrace(overflow: 5), options: options(mode, overBudgetMs: nil))
                let png = o.pngData { ctx, size in syntheticBackdrop(ctx, size, mode: mode, trace: trace) }
                let path = "\(prefix)-\(mode.rawValue).png"
                let ok = png.map { FileManager.default.createFile(atPath: path, contents: $0) } ?? false
                check("png: wrote \(path)", ok)
            }
            // Labels off, the cursor on box 0: outlines, plus that one chip.
            let o = DetectionViewOverlay(size: CGSize(width: 1440, height: 900), scale: 2, window: nil)
            var opts = options(.detectionsOnly)
            opts.showLabels = false
            opts.hovered = .box(index: 0)
            o.render(fixedTrace(overflow: 5), options: opts)
            let png = o.pngData { ctx, size in syntheticBackdrop(ctx, size, mode: .detectionsOnly, trace: trace) }
            let path = "\(prefix)-labels-off-hover.png"
            check("png: wrote \(path)", png.map { FileManager.default.createFile(atPath: path, contents: $0) } ?? false)
            // Steadiness: a kept box, a settle re-check raise and weak boxes
            // (synthetic), with "Show weak detections" on.
            let w = DetectionViewOverlay(size: CGSize(width: 1440, height: 900), scale: 2, window: nil)
            var weakOpts = options(.outlineOverCovers)
            weakOpts.showWeak = true
            weakOpts.showLabels = true
            let steady = steadinessTrace()
            w.render(steady, options: weakOpts)
            let wpng = w.pngData { ctx, size in syntheticBackdrop(ctx, size, mode: .outlineOverCovers, trace: steady) }
            let wpath = "\(prefix)-weak-kept.png"
            check("png: wrote \(wpath)", wpng.map { FileManager.default.createFile(atPath: wpath, contents: $0) } ?? false)
        }
    }

    // MARK: Label toggle and hover

    private static func detectionViewLabels() {
        // Pure hit test and coordinate mapping.
        func item(_ kind: DetectionViewLayout.Item.Kind, _ r: CGRect) -> DetectionViewLayout.Item {
            let ink = DetectionViewInk.of(.covered)
            return .init(kind: kind, outline: r, ink: ink,
                chip: .init(frame: .zero, lines: [], ink: ink, leader: nil), explanation: nil)
        }
        let items = [
            item(.window(id: 9), CGRect(x: 0, y: 0, width: 500, height: 500)),
            item(.box(index: 0), CGRect(x: 0, y: 0, width: 100, height: 100)),
            item(.box(index: 1), CGRect(x: 10, y: 10, width: 20, height: 20)),
        ]
        func hit(_ x: CGFloat, _ y: CGFloat) -> DetectionViewLayout.Item.Kind? {
            DetectionViewLayout.hitTest(items, at: CGPoint(x: x, y: y))
        }
        check("hover hit test: nested boxes ⇒ the smallest containing the cursor", hit(15, 15) == .box(index: 1)
            && hit(50, 50) == .box(index: 0))
        check("hover hit test: no box under the cursor ⇒ the curtain window is the fallback", hit(300, 300) == .window(id: 9))
        check("hover hit test: empty space ⇒ nothing", hit(600, 600) == nil
            && DetectionViewLayout.hitTest([], at: .zero) == nil)
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let side = CGRect(x: 1440, y: -300, width: 1280, height: 800)
        check("hover mapping: AppKit bottom-left points ⇒ top-left layout points (flipped)",
            DetectionViewLayout.layoutPoint(mouse: CGPoint(x: 216, y: 486), screenFrame: main) == CGPoint(x: 216, y: 414)
                && DetectionViewLayout.layoutPoint(mouse: CGPoint(x: 0, y: 900), screenFrame: main) == .zero)
        check("hover mapping: a second display offset in the global space maps to its own origin",
            DetectionViewLayout.layoutPoint(mouse: CGPoint(x: 1540, y: 450), screenFrame: side) == CGPoint(x: 100, y: 50))

        // Layout: labels off keeps the chrome, hides chips, shows the hovered one.
        let trace = fixedTrace()
        let size = CGSize(width: 1440, height: 900)
        var off = options(.detectionsOnly)
        off.showLabels = false
        let on = DetectionViewLayout.make(trace, size: size, options: options(.detectionsOnly))
        let L = DetectionViewLayout.make(trace, size: size, options: off)
        check("labels off: outlines only — every item still drawn, no chip shown, windows' headers included",
            L.items.count == on.items.count && !L.items.contains(where: \.chipShown)
                && L.items.contains { if case .window = $0.kind { return true }; return false })
        check("labels off: the badge, HUD and legend stay; the legend says labels are hidden",
            L.badge == on.badge && L.badgeDanger && !L.hud.lines.isEmpty && L.hud.frame == on.hud.frame
                && L.legend.lines.last == DetectionViewCopy.legendLabelsHidden
                && !on.legend.lines.contains(DetectionViewCopy.legendLabelsHidden))
        off.hovered = .box(index: 0)
        let H = DetectionViewLayout.make(trace, size: size, options: off)
        let hoverChip = H.items.first { $0.chipShown }
        check("labels off + hover: only the hovered chip, same text and place as labels on",
            H.items.filter(\.chipShown).count == 1 && hoverChip?.kind == .box(index: 0)
                && hoverChip?.chip == on.items.first { $0.kind == .box(index: 0) }?.chip)

        // Controller: default off, toggling, polling, redraw only on change.
        check("labels: off by default (every agent start)", !DetectionViewController().showLabels)
        let host = FakeDetectionViewHost()
        var cursor = CGPoint(x: 700, y: 900 - 150)  // AppKit points; empty space
        let c = makeController(host)
        c.mouseLocation = { cursor }
        check("hover poll: not running while the view is off", !c.isHoverPolling)
        c.turnOn(.detectionsOnly)
        c.exclusionResult(host.result(Set(host.exclusionWindowNumbers)))
        host.detectionTraceBus.publish(trace)
        spinMain()
        guard let overlay = c.overlay else {
            check("labels: the view turned on", false)
            return
        }
        check("labels off on screen: outlines drawn, zero chip layers shown",
            !overlay.lastLayout.items.isEmpty && overlay.drawnChipCount == 0)
        check("labels off on screen: the red safety badge and the HUD are drawn",
            overlay.showsDangerBadge && !overlay.lastLayout.hud.lines.isEmpty)
        check("hover poll: running while on with labels off", c.isHoverPolling)
        check("hover poll: the window stays click-through while polling",
            overlay.window?.ignoresMouseEvents == true)
        let before = c.draws
        c.pollHover()
        check("hover poll: nothing under the cursor ⇒ no redraw", c.draws == before && c.hovered == nil)
        cursor = CGPoint(x: 216, y: 900 - 414)  // centre of box 0, inside window 4312
        c.pollHover()
        c.pollHover()
        check("hover poll: over a box ⇒ its chip alone, one redraw for two polls",
            c.hovered == .box(index: 0) && overlay.drawnChipCount == 1 && c.draws == before + 1)
        cursor = CGPoint(x: 100, y: 900 - 560)  // in window 4312, on no box
        c.pollHover()
        check("hover poll: in a curtain window off every box ⇒ the window's header chip",
            c.hovered == .window(id: 4312) && overlay.drawnChipCount == 1)
        c.setShowLabels(true)
        check("labels on: every chip drawn, polling stopped, no hover kept",
            overlay.drawnChipCount == overlay.lastLayout.items.count && !c.isHoverPolling && c.hovered == nil
                && !overlay.lastLayout.legend.lines.contains(DetectionViewCopy.legendLabelsHidden))
        c.setShowLabels(false)
        check("labels off again: chips hidden, polling back",
            overlay.drawnChipCount == 0 && c.isHoverPolling)
        c.turnOff(reason: .user)
        check("hover poll: stops when the view turns off", !c.isHoverPolling)
    }

    /// A plain synthetic desktop for the PNG: grey backdrop, two flat
    /// window rectangles, and (Outline over covers) black cover rects where
    /// covers would be. No real content of any kind.
    private static func syntheticBackdrop(_ ctx: CGContext, _ size: CGSize, mode: DetectionViewMode, trace: DetectionTrace) {
        ctx.setFillColor(CGColor(srgbRed: 0.33, green: 0.37, blue: 0.43, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height) }
        func pt(_ n: CGRect) -> CGRect { DetectionViewLayout.points(n, size) }
        ctx.setFillColor(CGColor(gray: 0.93, alpha: 1))
        ctx.fill(CGRect(x: 0, y: size.height - 25, width: size.width, height: 25))
        for w in trace.windows {
            ctx.setFillColor(CGColor(gray: 0.97, alpha: 1))
            let f = pt(w.frame)
            ctx.fill(flip(f))
            ctx.setFillColor(CGColor(gray: 0.85, alpha: 1))
            ctx.fill(flip(CGRect(x: f.minX, y: f.minY, width: f.width, height: 28)))
        }
        if mode == .outlineOverCovers, let w = trace.windows.first {
            ctx.setFillColor(CGColor(gray: 0.02, alpha: 1))
            ctx.fill(flip(pt(w.frame)))
        }
    }

    // MARK: Snapshot

    private static func detectionViewSnapshot() {
        let host = FakeDetectionViewHost()
        var records: [(String, String)] = []
        var clipboard: String?
        let c = makeController(host, log: { records.append(($0, $1)) })
        c.copyToClipboard = { clipboard = $0 }
        check("snapshot: refused by name while off", c.snapshot() == nil && c.refusal == DetectionViewCopy.refusedNotOn)
        c.turnOn(.outlineOverCovers)
        check("snapshot: refused by name before any frame", c.snapshot() == nil && c.refusal == DetectionViewCopy.refusedNoFrame)
        host.detectionTraceBus.publish(fixedTrace())
        guard let json = c.snapshot(),
            let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
            let boxes = obj["boxes"] as? [[String: Any]]
        else {
            check("snapshot: parses as JSON with boxes", false)
            return
        }
        check("snapshot: one detection-snapshot record and the same text on the clipboard",
            records.filter { $0.0 == DetectionViewEvent.snapshot }.count == 1 && clipboard == json
                && !json.contains("\n"))
        check("snapshot: every box carries outcome, style and text; ruled boxes carry rule, value and flip point",
            boxes.count == 11 && boxes.allSatisfy { $0["outcome"] != nil && $0["style"] != nil && $0["text"] != nil }
                && boxes[5]["rule"] as? String == "classes.ANUS_EXPOSED.minBoxPt"
                && boxes[5]["inForce"] as? String == "24" && boxes[5]["observed"] as? String == "16"
                && boxes[5]["flipsAt"] as? String == "minBoxPt ≤ 16" && boxes[5]["ruleKind"] as? String == "tuning"
                && boxes[3]["rule"] as? String == "policy" && boxes[3]["ruleKind"] as? String == "sensitivity")
        check("snapshot: windows carry hits vs bar and hold left; tuning, source and mode ride along",
            (obj["windows"] as? [[String: Any]])?.contains { $0["bar"] as? String == "triggerHits" && $0["hits"] as? Int == 2 } == true
                && (obj["windows"] as? [[String: Any]])?.contains { $0["holdLeftSecs"] as? Double == 3.4 } == true
                && obj["tuning"] is [String: Any] && obj["tuningSource"] as? String == "tuning.json"
                && obj["mode"] as? String == "outline-over-covers")
        // Keys are sorted: everything before "tuning" is the snapshot's own
        // (boxes, stats, …); the tuning object is TuningPolicy's own dump.
        let own = json.components(separatedBy: "\"tuning\":").first ?? json
        check("snapshot: its own numbers are decimals, never binary-float noise (0.83, not 0.8299…)",
            !own.contains("9999999") && !own.contains("0000001"), String(own.prefix(160)))
        check("snapshot: stats carry the HUD's cost figures (fps, detect, step, trace)",
            (obj["stats"] as? [String: Any]).map { s in
                ["evaluatedFps", "detectMs", "stepMs", "traceMs", "idleSkipped"].allSatisfy { s[$0] != nil }
            } == true)
        let forbidden = ["image", "pixel", "png", "jpg", "crop", "path", "base64"]
        check("snapshot: text only — no image, pixel or file field anywhere",
            !forbidden.contains { json.lowercased().contains("\"\($0)") })
        check("snapshot: the stamp says when and how many",
            c.lastSnapshot?.boxes == 11
                && DetectionViewCopy.snapshotStamp(at: Date(), boxes: 11).hasSuffix("11 boxes · also in run.jsonl"))
        c.turnOff(reason: .user)
    }

    // MARK: B4 UI

    private static func detectionViewUI(_ dir: String) {
        // The popover header in Detections only (D4).
        let host = FakeDetectionViewHost()
        let c = makeController(host)
        let state = UIState(settings: .defaults, devStateRoot: false, isAdmin: true)
        state.captureHealth = .protecting
        check("popover: header is the normal one while the view is off",
            UIDetectionViewHeader.header(state: state, view: c) == state.headerText)
        c.turnOn(.detectionsOnly)
        check("popover: Detections only ⇒ header says protection is off, detail says until when, glyph degraded",
            UIDetectionViewHeader.header(state: state, view: c) == "Protection off · Detection view"
                && UIDetectionViewHeader.detail(state: state, view: c).hasPrefix(DetectionViewCopy.protectionOffDetailPrefix)
                && UIDetectionViewHeader.overridesGlyph(state: state, view: c))
        c.turnOn(.outlineOverCovers)
        check("popover: Outline over covers keeps the real header (protection is on)",
            UIDetectionViewHeader.header(state: state, view: c) == state.headerText)
        check("popover: the row reads mode and time left",
            DetectionViewCopy.rowText(mode: c.mode, remaining: 252) == "Detection view · Outline over covers · 4:12 left")
        c.turnOff(reason: .user)

        // PIN: turning on (either mode), Renew and synthetic ask; off never does.
        let storeRoot = dir + "/store"
        try? FileManager.default.createDirectory(atPath: storeRoot, withIntermediateDirectories: true)
        let store = UISettingsStore(root: storeRoot, log: { _, _ in })
        let actions = UIActions(store: store, log: { _, _ in })
        actions.detectionView.presentsWindow = false
        actions.detectionView.log = { _, _ in }
        let pinHost = FakeDetectionViewHost()
        actions.detectionView.attach(pinHost)
        actions.openSettings()
        actions.selectDetectionViewMode(.detectionsOnly, returnTo: .settings)
        check("pin: turning on with no PIN set ⇒ set-PIN layer first, still off",
            actions.layer == .setPin && !actions.detectionView.isOn, "\(actions.layer)")
        actions.newPin = "4821"
        actions.confirmPin = "4821"
        actions.saveNewPin()
        spin(until: { !actions.busy })
        check("pin: PIN saved ⇒ on in the chosen mode, back on the sheet",
            actions.detectionView.mode == .detectionsOnly && actions.layer == .settings, "\(actions.layer)")
        actions.lock()
        actions.openSettings()
        actions.renewDetectionView(returnTo: .settings)
        check("pin: Renew behind the PIN when locked, the prompt names it",
            actions.layer == .pin && actions.pendingConfirmation == DetectionViewCopy.pinRenew)
        actions.closeSettings()
        actions.lock()
        actions.openSettings()
        actions.selectDetectionViewMode(.outlineOverCovers, returnTo: .settings)
        check("pin: Detections only → Outline over covers (covers come back) never asks",
            actions.detectionView.mode == .outlineOverCovers && actions.layer == .settings, "\(actions.layer)")
        actions.closeSettings()
        actions.lock()
        actions.turnOffDetectionView()
        check("pin: turning off never asks", !actions.detectionView.isOn && actions.layer == .none)
        actions.selectDetectionViewMode(.outlineOverCovers, returnTo: .settings)
        check("pin: Outline over covers also asks (D5: either mode)",
            actions.layer == .pin && actions.pendingConfirmation == DetectionViewCopy.pinTurnOn(.outlineOverCovers)
                && !actions.detectionView.isOn)
        actions.lock()
        actions.detectionView.detach(reason: .shutdown)
    }

    private static func spinMain() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
}
