import AppKit
import Foundation

// TUNING TOOL — the Detection view's state machine.
// Main thread. Owned by UIActions (so the Developer tab and the popover row
// share one), attached to the running Pipeline by AppDelegate.startPipeline.
//
// Safety rails, all tested by `--ui-selftest` "detection-view":
//   * The detector never sees our labels. The window goes on screen with its
//     layers hidden; capture is asked to exclude it; nothing is drawn until
//     the LATEST exclusion result names our window. A result without it, or a
//     stream rebuild, hides the layers again until capture reconfirms.
//     Unconfirmed after Capture's own retry budget → turned off by name.
//   * A dead id never poisons a later exclusion refresh: turning off drops
//     our id from `Pipeline.exclusionWindowNumbers` and re-requests the
//     exclusion BEFORE the window is ordered out, in the same main turn.
//   * Detections only (mode a) hides covers only while the view is visibly
//     on screen, and turning off always hands painting back to the pipeline.
//   * Off on: TTL, the panic hold (before its administrator prompt), every
//     pause, shutdown, a pipeline rebuild, and the UI. In memory only: every
//     agent start is off.

/// What the controller needs from the pipeline. `Pipeline` conforms below;
/// the self-test uses a fake with a real `CaptureStream`.
protocol DetectionViewHost: AnyObject {
    var detectionTraceBus: DetectionTraceBus { get }
    var detectionViewSuppressesCovers: Bool { get set }
    var detectionView: DetectionViewController? { get set }
    func setDetectionTrace(enabled: Bool) -> Bool
    func setSyntheticDetections(enabled: Bool) -> Bool
    /// "Show weak detections": the detector's NMS floor, nil = off
    /// (`Pipeline.setWeakDetections`).
    func setWeakDetections(floor: Float?) -> Bool
    /// Every cover on screen comes down now — paint only: the
    /// `WindowTracker` the curtain shares is left alone
    /// (`OverlayManager.clearPaint`), so the view never disturbs the
    /// pipeline it is showing.
    func clearCoversForDetectionView()
    /// Synchronously repaints the newest held covers once suppression has
    /// ended: a static screen sends no frame that would.
    func restoreCoversForDetectionView()
    /// `capture.refreshExclusion(windowNumbers: exclusionWindowNumbers)`.
    func refreshDetectionViewExclusion()
    /// `CaptureStream.newestExclusionRequest`: the number of the refresh
    /// just made, so older answers can be told apart.
    var newestExclusionRequest: Int { get }
    func setExclusionHandler(_ handler: ((CaptureStream.ExclusionResult) -> Void)?)
    var coverWindowNumber: Int? { get }
    /// The captured display: AppKit frame, menu bar height, backing scale.
    var detectionViewScreen: (frame: CGRect, topInset: CGFloat, scale: CGFloat)? { get }
    /// Why the view cannot turn on right now (a pause, no capture), in the
    /// words the UI shows; nil when it can.
    var detectionViewUnavailable: String? { get }
}

final class DetectionViewController: ObservableObject {
    /// How long the view stays on before it turns itself off. DERIVED from
    /// SPEC §8.1(3) — every dev run carries `--ttl 300` — and the 300 s panic
    /// pause (§8.1(1)): the same five minutes the family of safety rails
    /// already uses, so a forgotten Detections-only view (protection OFF) is
    /// bounded exactly like a forgotten dev run.
    static let ttlSecs: TimeInterval = 300

    /// Hover poll period while labels are off (10 Hz). DERIVED from hover
    /// responsiveness: ~100 ms is the usual bound for a response to read as
    /// immediate, so a chip appears within one poll of the cursor landing
    /// on a box. The window stays click-through (no tracking areas), so the
    /// cursor is polled: one `NSEvent.mouseLocation` read and one
    /// `DetectionViewLayout.hitTest` per tick — two linear passes (boxes,
    /// then windows) over the layout's items: at most
    /// `DetectionTraceBuilder.maxBoxes` box rects plus one rect per curtain
    /// window in the trace. Windows have no fixed cap: one per window
    /// `Curtain.traceWindows` lists (pending, curtained, leaving, strip-cover
    /// or lingering), a handful on a real desktop; the self-test's stress
    /// trace carries two. A redraw
    /// (`DetectionViewOverlay.renderBudgetMs`) happens only when the hovered
    /// item changes. Runs only while the view is on with labels off.
    static let hoverPollSecs: TimeInterval = 0.1

    enum OffReason: String {
        case user = "turned-off"
        case ttl = "ttl-expired"
        case panicHotkey = "panic-hotkey"
        case panicPause = "panic-pause"
        case parentPause = "parent-pause"
        case shutdown
        case pipelineRebuild = "pipeline-rebuild"
        case exclusionUnconfirmed = "exclusion-unconfirmed"
        case exclusionFailed = "exclusion-failed"
    }

    enum Exclusion: String { case off, awaiting, confirmed }

    @Published private(set) var mode: DetectionViewMode = .off
    @Published private(set) var offAt: Date?
    @Published private(set) var synthetic = false
    @Published private(set) var showNonPolicy = false
    /// "Show box labels": off by default, in memory like the other view
    /// settings. Off draws outlines only; hovering a box shows its chip.
    @Published private(set) var showLabels = false
    /// "Show weak detections": off by default and on every turn-off. The
    /// view only; `--conf` still decides everything protection sees.
    @Published private(set) var showWeak = false
    /// The score the weak boxes start at (the slider), in
    /// [`Pipeline.weakFloorMin`, `weakMax`).
    @Published private(set) var weakFloor: Float = Pipeline.weakFloorMin
    /// The slider's top: the shipped `--conf` default, where weak ends.
    static let weakMax: Float = 0.25
    @Published private(set) var exclusion: Exclusion = .off
    @Published private(set) var refusal: String?
    @Published private(set) var lastSnapshot: (at: Date, boxes: Int)?
    /// Advanced by `tick`, so countdowns redraw once a second.
    @Published private(set) var now: Date

    /// stderr + run.jsonl (AppDelegate's UI log). Every transition lands here.
    var log: (String, String) -> Void = { _, _ in }
    var copyToClipboard: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    /// The self-test builds overlays that never reach the screen.
    var makeOverlay: (_ frame: CGRect, _ scale: CGFloat) -> DetectionViewOverlay = { frame, scale in
        DetectionViewOverlay(size: frame.size, scale: scale, window: DetectionViewOverlay.makeWindow(frame: frame))
    }
    var presentsWindow = true
    /// The cursor in AppKit global points; the self-test injects one.
    var mouseLocation: () -> CGPoint = { NSEvent.mouseLocation }
    let clock: () -> Date

    private(set) weak var host: DetectionViewHost?
    private(set) var overlay: DetectionViewOverlay?
    private var screen: (frame: CGRect, topInset: CGFloat, scale: CGFloat)?
    private var unconfirmedResults = 0
    /// Exclusion answers to requests numbered below this are ignored: they
    /// predate our own newest request or a stream rebuild, so they say
    /// nothing about the filter now in force.
    private var acceptResultsFrom = 0
    private var latestTrace: DetectionTrace?
    private var lastDrawMs: Double?
    /// When the view last started waiting for capture to exclude its window
    /// (turn-on, or a hide until reconfirmed): the `state=visible` record's
    /// `waitedMs`, the live receipt for the exclusion handshake.
    private var awaitingSince: Date?
    private var overBudgetMs: Double?
    private var hoverTimer: Timer?
    /// The item whose chip is shown while labels are off.
    private(set) var hovered: DetectionViewLayout.Item.Kind?
    /// Draws so far: the self-test checks a hover poll redraws only on change.
    private(set) var draws = 0

    init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
        now = clock()
    }

    var isOn: Bool { mode != .off }
    var remaining: TimeInterval { max(0, (offAt ?? now).timeIntervalSince(now)) }

    /// `Pipeline.exclusionWindowNumbers` appends this: our window's number
    /// while the view is on, nil the moment it turns off.
    var excludedWindowNumber: Int? { isOn ? overlay?.windowNumber : nil }

    // MARK: Pipeline attachment

    func attach(_ host: DetectionViewHost) {
        if let old = self.host, old !== host { detach(reason: .pipelineRebuild) }
        self.host = host
        host.detectionView = self
        host.setExclusionHandler { [weak self] result in self?.exclusionResult(result) }
    }

    /// A pipeline going away (rebuild or stop) takes the view with it.
    func detach(reason: OffReason) {
        turnOff(reason: reason)
        guard let host else { return }
        host.setExclusionHandler(nil)
        host.detectionTraceBus.onTrace = nil
        if host.detectionView === self { host.detectionView = nil }
        self.host = nil
    }

    // MARK: On / off

    /// Main thread; the caller has already passed the PIN. Switching between
    /// the two "on" modes keeps the window, the exclusion and the TTL.
    @discardableResult
    func turnOn(_ newMode: DetectionViewMode, reason: String = "developer-tab") -> Bool {
        guard newMode != .off else {
            turnOff(reason: .user)
            return true
        }
        refusal = nil
        guard let host else { return refuse(DetectionViewCopy.refusedNoPipeline) }
        if isOn {
            let from = mode
            mode = newMode
            // Draw first: Detections only may hide covers only once its
            // badge is on screen.
            redraw()
            applyCoverSuppression()
            record("state=on mode=\(newMode.rawValue) from=\(from.rawValue) reason=mode-change")
            return true
        }
        if let why = host.detectionViewUnavailable { return refuse(why) }
        guard let screen = host.detectionViewScreen else { return refuse(DetectionViewCopy.refusedNoScreen) }
        guard host.setDetectionTrace(enabled: true) else { return refuse(DetectionViewCopy.refusedHeadless) }
        self.screen = screen
        let overlay = makeOverlay(screen.frame, screen.scale)
        self.overlay = overlay
        if presentsWindow { overlay.present(above: host.coverWindowNumber) }
        now = clock()
        mode = newMode
        exclusion = .awaiting
        awaitingSince = now
        unconfirmedResults = 0
        overBudgetMs = nil
        offAt = now.addingTimeInterval(Self.ttlSecs)
        host.detectionTraceBus.onTrace = { [weak self] trace in self?.receive(trace) }
        if synthetic, !host.setSyntheticDetections(enabled: true) { refuseSynthetic() }
        if showWeak { _ = host.setWeakDetections(floor: weakFloor) }
        // Our id is in exclusionWindowNumbers from here on.
        host.refreshDetectionViewExclusion()
        acceptResultsFrom = host.newestExclusionRequest
        updateHoverPolling()
        record("state=on mode=\(newMode.rawValue) ttl=\(Int(Self.ttlSecs))s synthetic=\(synthetic ? 1 : 0) "
            + "window=\(overlay.windowNumber ?? -1) reason=\(reason) — drawing waits for capture to exclude "
            + "the window")
        return true
    }

    /// Main thread, synchronous: by return, the view is off, capture has been
    /// asked for a filter without our window, and covers paint again.
    func turnOff(reason: OffReason, refusal: String? = nil) {
        guard isOn else { return }
        let was = mode
        let secsOn = Self.ttlSecs - remaining
        // Covers back first, while the badge is still up.
        if let host, host.detectionViewSuppressesCovers {
            host.detectionViewSuppressesCovers = false
            host.restoreCoversForDetectionView()
        }
        overlay?.setVisible(false)
        mode = .off
        exclusion = .off
        // Id out first (excludedWindowNumber is nil now), then the request,
        // then the window leaves the screen — the order the handshake needs.
        host?.refreshDetectionViewExclusion()
        overlay?.close()
        overlay = nil
        host?.detectionTraceBus.onTrace = nil
        _ = host?.setDetectionTrace(enabled: false)
        if synthetic { _ = host?.setSyntheticDetections(enabled: false) }
        synthetic = false
        if showWeak { _ = host?.setWeakDetections(floor: nil) }
        showWeak = false
        offAt = nil
        latestTrace = nil
        updateHoverPolling()
        self.refusal = refusal
        record("state=off mode=\(was.rawValue) reason=\(reason.rawValue) after=\(Int(secsOn.rounded()))s"
            + (was == .detectionsOnly ? " — covers repainted from the last frame" : ""))
    }

    /// Main thread; behind the PIN. Restarts the TTL.
    func renew() {
        guard isOn else { _ = refuse(DetectionViewCopy.refusedNotOn); return }
        now = clock()
        offAt = now.addingTimeInterval(Self.ttlSecs)
        record("state=renewed mode=\(mode.rawValue) ttl=\(Int(Self.ttlSecs))s")
        redraw()
    }

    /// Main thread; turning ON is behind the PIN (UIActions). Takes effect
    /// while the view is on; turning the view off clears it.
    func setSynthetic(_ on: Bool) {
        guard synthetic != on else { return }
        synthetic = on
        guard isOn, let host else { return }
        guard host.setSyntheticDetections(enabled: on) || !on else {
            refuseSynthetic()
            return
        }
        record("state=on mode=\(mode.rawValue) synthetic=\(on ? 1 : 0)")
        redraw()
    }

    /// The pipeline refused synthetic boxes (a crop writer is attached, and
    /// it logged why): the toggle must not read on.
    private func refuseSynthetic() {
        synthetic = false
        _ = refuse(DetectionViewCopy.refusedSynthetic)
        redraw()
    }

    func setShowNonPolicy(_ on: Bool) {
        showNonPolicy = on
        redraw()
    }

    /// No PIN: weak boxes go to the trace only, never to protection.
    func setShowWeak(_ on: Bool) {
        guard showWeak != on else { return }
        showWeak = on
        if isOn { _ = host?.setWeakDetections(floor: on ? weakFloor : nil) }
        record("weak=\(on ? 1 : 0) floor=\(DetectionViewCopy.f2(weakFloor))")
        redraw()
    }

    func setWeakFloor(_ floor: Float) {
        let f = min(max(floor, Pipeline.weakFloorMin), Self.weakMax - 0.01)
        guard f != weakFloor else { return }
        weakFloor = f
        if isOn, showWeak { _ = host?.setWeakDetections(floor: f) }
    }

    /// No PIN: it changes what the view draws, never protection.
    func setShowLabels(_ on: Bool) {
        guard showLabels != on else { return }
        showLabels = on
        updateHoverPolling()
        redraw()
    }

    // MARK: Hover (labels off)

    var isHoverPolling: Bool { hoverTimer != nil }

    /// Polls only while the view is on with labels off. The window stays
    /// click-through, so this reads the cursor instead of taking events.
    private func updateHoverPolling() {
        let want = isOn && !showLabels
        if !want {
            hoverTimer?.invalidate()
            hoverTimer = nil
            hovered = nil
            return
        }
        guard hoverTimer == nil else { return }
        let timer = Timer(timeInterval: Self.hoverPollSecs, repeats: true) { [weak self] _ in self?.pollHover() }
        // .common: keeps polling while a menu or the Settings sheet tracks events.
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    /// One poll: redraws only when the hovered item changes.
    func pollHover() {
        guard isOn, !showLabels, let overlay, let screen else { return }
        let p = DetectionViewLayout.layoutPoint(mouse: mouseLocation(), screenFrame: screen.frame)
        let hit = DetectionViewLayout.hitTest(overlay.lastLayout.items, at: p)
        guard hit != hovered else { return }
        hovered = hit
        redraw()
    }

    // MARK: Exclusion handshake

    /// Capture's answer to a `refreshExclusion` (main).
    func exclusionResult(_ result: CaptureStream.ExclusionResult) {
        guard isOn, result.request >= acceptResultsFrom, let id = overlay?.windowNumber else { return }
        if result.applied, result.ids.contains(id) {
            unconfirmedResults = 0
            guard exclusion != .confirmed else { return }
            exclusion = .confirmed
            overlay?.setVisible(true)
            redraw()
            applyCoverSuppression()
            let waitedMs = awaitingSince.map { Int((clock().timeIntervalSince($0) * 1000).rounded()) } ?? -1
            record("state=visible mode=\(mode.rawValue) exclusion=confirmed window=\(id) waitedMs=\(waitedMs)")
            return
        }
        hideUntilConfirmed("exclusion result without window \(id)")
        let budget = CaptureStream.exclusionAttemptBudget
        guard result.applied else {
            turnOff(reason: .exclusionFailed, refusal: DetectionViewCopy.refusedExclusion(budget: budget))
            return
        }
        unconfirmedResults += 1
        guard unconfirmedResults < budget else {
            turnOff(reason: .exclusionUnconfirmed, refusal: DetectionViewCopy.refusedExclusion(budget: budget))
            return
        }
        host?.refreshDetectionViewExclusion()
        acceptResultsFrom = host?.newestExclusionRequest ?? acceptResultsFrom
    }

    /// A stream rebuild carries a fresh content filter: hide until the
    /// re-arm's own exclusion refresh — a request made AFTER this — names
    /// our window again. An answer to an older request (applied to the old
    /// stream, landing late) is ignored.
    func streamInvalidated() {
        guard isOn else { return }
        acceptResultsFrom = (host?.newestExclusionRequest ?? 0) + 1
        hideUntilConfirmed("capture stream rebuilt")
    }

    private func hideUntilConfirmed(_ why: String) {
        let wasConfirmed = exclusion == .confirmed
        if wasConfirmed { awaitingSince = clock() }
        exclusion = .awaiting
        overlay?.setVisible(false)
        applyCoverSuppression()
        if wasConfirmed { record("state=hidden mode=\(mode.rawValue) reason=\(why)") }
    }

    /// The overlay's window was created by the pipeline (first cover): keep
    /// ours just above it.
    func coverWindowCreated(_ number: Int?) {
        guard isOn, presentsWindow, let number else { return }
        overlay?.present(above: number)
    }

    /// Detections only hides covers ONLY while its red badge is actually
    /// drawn, so "protection off" is never true without the badge on
    /// screen. Covers come back synchronously when that stops being true.
    private func applyCoverSuppression() {
        guard let host else { return }
        let suppress = mode == .detectionsOnly && exclusion == .confirmed && overlay?.showsDangerBadge == true
        guard host.detectionViewSuppressesCovers != suppress else { return }
        host.detectionViewSuppressesCovers = suppress
        // The paint guard stops NEW paints; covers already up come down
        // here, and come back here.
        if suppress {
            host.clearCoversForDetectionView()
        } else {
            host.restoreCoversForDetectionView()
        }
    }

    // MARK: Drawing

    private func receive(_ trace: DetectionTrace) {
        latestTrace = trace
        guard exclusion == .confirmed else { return }
        redraw()
    }

    func options() -> DetectionViewLayout.Options {
        DetectionViewLayout.Options(
            mode: mode, now: CFAbsoluteTimeGetCurrent(), remaining: remaining, showNonPolicy: showNonPolicy,
            showWeak: showWeak, synthetic: synthetic, showLabels: showLabels, hovered: hovered, drawMs: lastDrawMs,
            overBudgetMs: overBudgetMs,
            // Hidden chips crowd nothing on screen: named only with labels on.
            crowded: showLabels ? overlay?.lastLayout.crowded ?? 0 : 0, topInset: screen?.topInset ?? 28)
    }

    /// Draws the newest trace, or — before the first one — the badge, the
    /// legend and a HUD that says it is waiting for a frame.
    private func redraw() {
        guard isOn, exclusion == .confirmed, let overlay else { return }
        draws += 1
        let ms = overlay.render(latestTrace, options: options())
        lastDrawMs = ms
        noteDrawCost(ms)
    }

    /// Tripwire (`DetectionViewOverlay.renderBudgetMs`): the HUD names it on
    /// the next draw, and one record is written per episode.
    func noteDrawCost(_ ms: Double) {
        if ms > DetectionViewOverlay.renderBudgetMs {
            if overBudgetMs == nil {
                record("state=on mode=\(mode.rawValue) budget DetectionViewOverlay.renderBudgetMs limit "
                    + "\(DetectionViewCopy.f1(DetectionViewOverlay.renderBudgetMs)) ms observed "
                    + "\(DetectionViewCopy.f1(ms)) ms — still drawing (fix: re-measure, "
                    + "DetectionViewOverlay.renderBudgetMs)")
            }
            overBudgetMs = ms
        } else {
            overBudgetMs = nil
        }
    }

    /// The settings store's 1 Hz tick: TTL, countdown, frame age.
    func tick() {
        // Off publishes nothing: an open Settings page must not re-render
        // once a second for a view that is not on.
        guard isOn, let offAt else { return }
        now = clock()
        if now >= offAt {
            turnOff(reason: .ttl)
            return
        }
        redraw()
    }

    // MARK: Snapshot

    /// The newest frame as one compact JSON line: a `detection-snapshot`
    /// record and the clipboard. Text only — no pixels, no image paths.
    @discardableResult
    func snapshot() -> String? {
        guard isOn else { _ = refuse(DetectionViewCopy.refusedNotOn); return nil }
        guard let trace = host?.detectionTraceBus.newest() ?? latestTrace else {
            _ = refuse(DetectionViewCopy.refusedNoFrame)
            return nil
        }
        refusal = nil
        let json = Self.snapshotJSON(trace, mode: mode, synthetic: synthetic, drawMs: lastDrawMs)
        log(DetectionViewEvent.snapshot, json)
        copyToClipboard(json)
        lastSnapshot = (clock(), trace.boxes.count)
        return json
    }

    /// Snapshot fields: per box `rule`
    /// is the setting or check that decided it, and `ruleKind` says what
    /// kind of handle that is — `tuning` (a tuning.json key), `sensitivity`
    /// (Standard/Strict), `flag` (a launch flag such as --roi) or
    /// `constant` (a receipted code constant, e.g. a curtain walk check).
    /// `stats` carries the HUD's cost figures, so a run can be measured from
    /// run.jsonl text instead of from the HUD's pixels.
    static func snapshotJSON(
        _ t: DetectionTrace, mode: DetectionViewMode, synthetic: Bool, drawMs: Double? = nil
    ) -> String {
        // Decimal, not Double: JSONSerialization writes the Double 0.83 as
        // 0.82999999999999996 (seen in the first test Mac snapshot, 2026-09-24).
        func dec(_ x: Double, _ places: Int) -> NSDecimalNumber {
            NSDecimalNumber(string: String(format: "%.\(places)f", x))
        }
        func r3(_ x: CGFloat) -> NSDecimalNumber { dec(Double(x), 3) }
        let boxes: [[String: Any]] = t.boxes.map { b in
            let e = DetectionViewCopy.explain(b, trace: t, mode: mode)
            var o: [String: Any] = [
                "i": b.index, "label": b.label, "conf": dec(Double(b.confidence), 3),
                "rect": [r3(b.rect.minX), r3(b.rect.minY), r3(b.rect.width), r3(b.rect.height)],
                "outcome": e.outcome, "style": e.style.rawValue, "text": e.lines.joined(separator: " | "),
            ]
            if b.rawLabel != b.label { o["rawLabel"] = b.rawLabel }
            if b.synthetic { o["synthetic"] = true }
            if let s = b.sidePt { o["sidePt"] = s.rounded() }
            if let k = e.ruleKey { o["rule"] = k }
            if let k = e.ruleKind { o["ruleKind"] = k.rawValue }
            if let v = e.inForce { o["inForce"] = v }
            if let v = e.observed { o["observed"] = v }
            if let v = e.flipsAt { o["flipsAt"] = v }
            return o
        }
        let windows: [[String: Any]] = t.windows.map { w in
            var o: [String: Any] = ["id": Int(w.id)]
            if let app = w.app { o["app"] = app }
            switch w.state {
            case let .pending(hits, required, bar):
                o["state"] = "pending"; o["hits"] = hits; o["required"] = required; o["bar"] = bar.rawValue
            case let .curtained(hold, clean, needed):
                o["state"] = "curtained"; o["holdLeftSecs"] = dec(hold, 1)
                o["cleanFrames"] = clean; o["cleanNeeded"] = needed
            case let .leaving(kind, secs):
                o["state"] = "leaving"; o["kind"] = kind; o["forSecs"] = dec(secs, 1)
            case .lingering:
                o["state"] = "lingering"
            }
            return o
        }
        func r2(_ x: Double) -> NSDecimalNumber { dec(x, 2) }
        var stats: [String: Any] = [
            "evaluatedFps": r2(t.stats.evaluatedFps), "detectMs": r2(t.stats.detectMs),
            "stepMs": r2(t.stats.stepMs), "traceMs": r2(t.stats.traceMs), "idleSkipped": t.stats.idleSkipped,
        ]
        if let drawMs { stats["drawMs"] = r2(drawMs) }
        let root: [String: Any] = [
            "seq": Int(t.seq), "stats": stats, "mode": mode.rawValue, "synthetic": synthetic, "policy": t.policy.rawValue,
            "cover": t.coverMode, "tuningSource": t.tuningSource, "tuning": t.tuning.jsonObject,
            "screenPt": [Double(t.screenPt.width), Double(t.screenPt.height)],
            "detectorFailed": t.detectorFailed, "boxesOverflow": t.boxesOverflow,
            "walkUnattributed": t.walkUnattributed,
            "walk": DetectionViewCopy.walkText(t.walk), "boxes": boxes, "windows": windows,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
            let s = String(data: data, encoding: .utf8)
        else { return "{\"error\":\"snapshot did not serialize\"}" }
        return s
    }

    // MARK: Records

    private func refuse(_ why: String) -> Bool {
        refusal = why
        record("state=refused mode=\(mode.rawValue) — \(why)")
        return false
    }

    private func record(_ info: String) {
        log(DetectionViewEvent.lifecycle, info)
    }
}

/// Main thread. The newest paint each of the pipeline's two overlay sync
/// sites handed over (a detector frame; a geometry-only curtain tick), held
/// so `Pipeline.restoreCoversForDetectionView` can repaint the moment
/// Detections only ends instead of waiting for a frame a static screen
/// never sends. Two values, replaced in place: no growth.
struct DetectionViewHeldPaint {
    struct Frame {
        let generation: UInt64
        let regions: [TrackedRegion]
        let painted: [CGRect]
        let anchors: [PaintExtrapolator.Anchor]
        let capturedAt: CFAbsoluteTime
        let curtains: [(id: UInt32, rect: CGRect, attr: CGRect)]
        let owners: [Int: UInt32]
    }

    struct Tick {
        let generation: UInt64
        let curtains: [(id: UInt32, rect: CGRect, attr: CGRect)]
        let at: CFAbsoluteTime
    }

    var frame: Frame?
    var tick: Tick?

    /// Repaints the held frame, then a curtain tick newer than it — the
    /// order the sites ran in. A value from a stream that is no longer
    /// current is skipped (its geometry may not match). Returns whether a
    /// sync created the cover window.
    func replay(
        isCurrent: (UInt64) -> Bool, sync: (Frame) -> Bool, syncCurtains: (Tick) -> Bool
    ) -> Bool {
        var created = false
        var replayedAt = -Double.infinity
        if let frame, isCurrent(frame.generation) {
            created = sync(frame)
            replayedAt = frame.capturedAt
        }
        if let tick, isCurrent(tick.generation), tick.at > replayedAt {
            created = syncCurtains(tick) || created
        }
        return created
    }
}

extension Pipeline: DetectionViewHost, TilesPreviewHost {
    func clearCoversForDetectionView() { overlays.clearPaint() }

    func refreshDetectionViewExclusion() {
        capture?.refreshExclusion(windowNumbers: exclusionWindowNumbers)
    }

    var newestExclusionRequest: Int { capture?.newestExclusionRequest ?? 0 }

    func setExclusionHandler(_ handler: ((CaptureStream.ExclusionResult) -> Void)?) {
        detectionViewExclusionHandler = handler
    }

    var detectionViewUnavailable: String? {
        if isPausedForDetectionView { return DetectionViewCopy.refusedPaused }
        if capture == nil { return DetectionViewCopy.refusedNoCapture }
        return nil
    }

    var coverWindowNumber: Int? { overlays.windowNumbers.first }

    // TilesPreviewHost (ZoomTilesView.swift): the same handshake, its own slot.
    func refreshTilesPreviewExclusion() {
        capture?.refreshExclusion(windowNumbers: exclusionWindowNumbers)
    }

    func setTilesPreviewExclusionHandler(_ handler: ((CaptureStream.ExclusionResult) -> Void)?) {
        tilesPreviewExclusionHandler = handler
    }

    var tilesPreviewUnavailable: String? { detectionViewUnavailable }

    var detectionViewScreen: (frame: CGRect, topInset: CGFloat, scale: CGFloat)? {
        guard let s = overlays.targetScreen ?? NSScreen.screens.first else { return nil }
        return (s.frame, s.frame.maxY - s.visibleFrame.maxY, s.backingScaleFactor)
    }
}
