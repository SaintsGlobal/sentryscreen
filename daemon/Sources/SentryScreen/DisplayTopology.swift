import AppKit

/// The geometry of the display this process captures and paints on, and the
/// gate that decides when a `didChangeScreenParameters` burst is worth acting
/// on.
///
/// WHY THIS FILE EXISTS (2026-09-11). Display
/// geometry used to be read exactly once, in `Pipeline.init`: `screenSize`, the
/// captured display's CG-global origin, and `WindowTracker.screenFrame` were
/// all `let`s. Every normalized-to-point conversion in the pipeline —
/// `Pipeline.screenRect`, `normalizeCurtains`, `CoverOwnership.onScreen`'s
/// containment test, the extrapolator's clamp and
/// `CaptureContentCrop.apply(displaySize:)` — multiplies by that size. So a
/// resolution change, a display hot-plug, a Sidecar attach or detach, or a
/// "main display" reassignment left every one of them computing against
/// geometry that no longer existed, and covers were painted in the wrong place
/// with no log line. That is the exact event a family Mac sees weekly: a child
/// plugs in a monitor or a TV.
///
/// Everything here is a value or a pure decision, deliberately: the
/// notification itself needs a real hot-plug (which a personal, in-use desktop
/// cannot be asked for on demand), but the parts this repo can actually get
/// wrong — which geometry we read, whether a notification moved anything,
/// coalescing a burst, and the conversions themselves — are all scriptable from
/// `--ui-selftest`.
struct DisplayGeometry: Equatable {
    /// The captured display's size in POINTS — the divisor of every
    /// normalized-to-point conversion in the pipeline.
    let size: CGSize
    /// That display's origin in CG-GLOBAL (top-left) space. `.zero` for the
    /// main display, which is why every conversion written before `--display`
    /// existed could omit the term and still be right on an M1 Mac.
    let origin: CGPoint
    /// WHICH display this geometry describes, so a reconfiguration that swaps
    /// the main display for a DIFFERENT display of the same size still counts as
    /// a change (it is in `Equatable`). Without it the conversions stayed
    /// numerically right while capture and the overlay silently ended up on two
    /// different physical displays. nil only when AppKit exposes no
    /// `NSScreenNumber` for the screen, or when no display resolved at all.
    let displayID: CGDirectDisplayID?

    init(size: CGSize, origin: CGPoint, displayID: CGDirectDisplayID? = nil) {
        self.size = size
        self.origin = origin
        self.displayID = displayID
    }

    /// The display's CG-global rect — what `Curtain` and `CoverOwnership` test
    /// window frames against.
    var bounds: CGRect { CGRect(origin: origin, size: size) }
    /// False when no display could be resolved. Every consumer already guards
    /// on `screenSize.width > 0`, so this degrades to "no curtains, no
    /// ownership" rather than to covers painted against zero.
    var isValid: Bool { size.width > 0 && size.height > 0 }

    /// "No display to normalize against" — a `--display` target that has been
    /// unplugged, or a boot with nothing attached yet.
    static let unknown = DisplayGeometry(size: .zero, origin: .zero)

    /// Normalized bottom-left (detection space) -> screen points, TOP-LEFT
    /// origin: the space CGWindowList reports window frames in.
    ///
    /// The `+ origin` terms are what `--display` needed: normalized space is
    /// relative to the CAPTURED display's own pixels (0...1 over that display
    /// only), but window frames are in CG-GLOBAL coordinates.
    func screenRect(_ r: CGRect) -> CGRect {
        CGRect(
            x: r.minX * size.width + origin.x,
            y: (1 - r.maxY) * size.height + origin.y,
            width: r.width * size.width, height: r.height * size.height)
    }

    /// Inverse of `screenRect`: CGWindowList points (top-left) -> normalized
    /// bottom-left, clamped to the unit square. A rect entirely off the unit
    /// square intersects to `CGRect.null`, whose origin is infinite — callers
    /// drop those rather than paint them (and `JSONEncoder` would throw on
    /// one, silently dropping a whole frame record).
    func normalized(_ f: CGRect) -> CGRect {
        CGRect(
            x: (f.minX - origin.x) / size.width,
            y: 1 - (f.minY - origin.y + f.height) / size.height,
            width: f.width / size.width,
            height: f.height / size.height
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Short `WxH@x,y#id` for the log record. The id is what makes a
    /// same-size main-display reassignment readable as a real change.
    var logText: String {
        String(format: "%.0fx%.0f@%.0f,%.0f", size.width, size.height, origin.x, origin.y)
            + "#" + (displayID.map(String.init) ?? "none")
    }

    /// The geometry the pipeline must normalize against RIGHT NOW.
    ///
    /// MAIN THREAD: `NSScreen` is main-thread state (the reason the old
    /// `screenSize` was captured in `init` in the first place).
    ///
    /// `displayID` nil — the production case, no `--display` — reproduces the
    /// prior expression exactly: `NSScreen.screens.first`'s size with a `.zero`
    /// origin. Given, the geometry follows THAT display across the
    /// reconfiguration, and a display that is gone yields `.unknown` rather
    /// than a silent fall-back to the main display.
    static func current(displayID: CGDirectDisplayID?) -> DisplayGeometry {
        guard let displayID else {
            guard let screen = NSScreen.screens.first else { return .unknown }
            return DisplayGeometry(
                size: screen.frame.size, origin: .zero, displayID: screen.sentryDisplayID)
        }
        guard let screen = screen(displayID: displayID) else { return .unknown }
        return DisplayGeometry(
            size: screen.frame.size, origin: CGDisplayBounds(displayID).origin,
            displayID: displayID)
    }

    /// The `NSScreen` for `displayID`, or nil for "use `NSScreen.screens.first`"
    /// — exactly what `OverlayManager.targetScreen` means. Main thread.
    static func screen(displayID: CGDirectDisplayID?) -> NSScreen? {
        guard let displayID else { return nil }
        return NSScreen.screens.first { $0.sentryDisplayID == displayID }
    }
}

extension NSScreen {
    /// The `CGDirectDisplayID` behind this screen, from the one
    /// device-description key AppKit exposes it under.
    var sentryDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }
}

/// A main-thread snapshot of the displays AppKit currently exposes.
///
/// This is deliberately separate from `DisplayGeometry`: connecting a second
/// display does not necessarily change the selected display's size, origin or
/// identity, but it DOES change the product's coverage claim. Capture remains
/// authoritative for which `SCDisplay` is protected; this snapshot only
/// refreshes the connected count and the local name for that captured id.
struct DisplayInventory: Equatable {
    let displayCount: Int
    let namesByID: [CGDirectDisplayID: String]

    /// Main thread. `NSScreen` is AppKit state.
    static func current() -> DisplayInventory {
        let screens = NSScreen.screens
        return DisplayInventory(
            displayCount: screens.count,
            namesByID: Dictionary(uniqueKeysWithValues: screens.compactMap { screen in
                screen.sentryDisplayID.map { ($0, screen.localizedName) }
            }))
    }

    /// Keep the actual captured `SCDisplay` identity. AppKit supplies only the
    /// current inventory and display name; it never selects a capture target.
    func refreshing(_ captured: DisplayScope) -> DisplayScope {
        DisplayScope(
            displayCount: displayCount,
            protectedDisplayID: captured.protectedDisplayID,
            protectedName: namesByID[captured.protectedDisplayID] ?? captured.protectedName,
            protectedDisplayConnected: namesByID[captured.protectedDisplayID] != nil)
    }
}

/// Coalescer for `didChangeScreenParameters` bursts.
struct DisplayChangeGate {
    /// Budget displayChangeCoalesce: how long a burst of
    /// `didChangeScreenParameters` notifications is absorbed before the
    /// pipeline acts on it.
    ///
    /// DERIVED, not measured — a hot-plug cannot be scripted on the shared
    /// M1 Mac. Bounded on
    /// both sides by numbers that are in the tree:
    ///
    /// (a) One reconfiguration delivers a BURST — AppKit posts the
    /// notification per window-server reconfiguration step, and one hot-plug or
    /// Sidecar attach is several steps. The STREAM cost of acting per
    /// notification is already bounded by `CaptureStream.beginRearm`, which
    /// coalesces by itself (`rearmInFlight` admits at most one attempt, and a
    /// second request becomes one deferred `rearmWanted`), so the cost this
    /// window actually saves is the PIPELINE reset: each decision calls
    /// `Pipeline.resetDetectState()`, which discards the curtain's hit history,
    /// so every extra decision re-pays the curtain entry debounce
    /// (`Curtain.triggerHits` = 3 attributed hits inside `windowSecs` = 1 s)
    /// before a curtain can be re-established.
    ///
    /// (b) Acting LATE costs covers painted against stale geometry for the
    /// whole delay, so the window has to stay below the rebuild it guards.
    /// MEASURED in-process rebuild cost: re-arm to `state=restored after 1
    /// attempt(s)` took ~1 s in both instances of the FUS run.
    /// NOT the 3.4 s figure at
    /// `AppDelegate.captureLossRelaunchSecs` — that is launch to first frame
    /// INCLUDING the CoreML model load (HelperClient.swift), which an
    /// in-process SCStream rebuild does not pay.
    ///
    /// 0.5 s is half that measured rebuild and well above the few tens of ms a
    /// single run-loop burst spans. If a measured hot-plug ever shows
    /// notifications still arriving after 0.5 s, re-measure and raise this with
    /// the new receipt — do not remove the coalescing.
    static let coalesceSecs: TimeInterval = 0.5

    /// True between the first notification of a burst and the moment the
    /// pipeline acts on it.
    private(set) var pending = false
    /// Notifications absorbed into the pending decision, including the one
    /// that armed it.
    private(set) var coalesced = 0

    /// One notification. Returns true when the CALLER must schedule the
    /// decision `coalesceSecs` from now; false when a decision is already
    /// armed and this notification was folded into it.
    ///
    /// The armed deadline is deliberately NOT extended by later notifications:
    /// worst-case reaction latency is therefore fixed at `coalesceSecs`, and a
    /// pathological notification stream produces at most one rebuild per
    /// window instead of deferring the reset forever.
    mutating func note() -> Bool {
        coalesced += 1
        guard !pending else { return false }
        pending = true
        return true
    }

    /// The armed decision fires: hand back how many notifications it covers
    /// and re-open the gate.
    mutating func fire() -> Int {
        defer {
            pending = false
            coalesced = 0
        }
        return coalesced
    }
}

/// One coalesced display-topology decision: the geometry before, the geometry
/// now, and how many notifications it covers.
struct DisplayChangeDecision: Equatable {
    let from: DisplayGeometry
    let to: DisplayGeometry
    let inventory: DisplayInventory
    let coalesced: Int

    /// False for the no-op case. `didChangeScreenParameters` also fires for
    /// menu-bar, Dock and colour-profile changes that move no geometry the
    /// pipeline normalizes against; acting on those would spend a stream
    /// rebuild (~1 s blind, MEASURED — receipt at
    /// `DisplayChangeGate.coalesceSecs`) plus a full detect-state reset for
    /// nothing.
    var changed: Bool { from != to }

    /// The one `"event":"capture"` record a real change emits, or nil for the
    /// no-op case (which is counted, not logged — see
    /// `Pipeline.applyDisplayChange`).
    func logInfo(source: String) -> String? {
        guard changed else { return nil }
        return "state=display-changed source=\(source) coalesced=\(coalesced) "
            + "was=\(from.logText) now=\(to.logText) — resetting curtain, tracker, ownership "
            + "and extrapolator state and rebuilding the capture stream (its width/height are "
            + "display-derived; fix: DisplayChangeGate.coalesceSecs)"
    }
}

/// Watches `NSApplication.didChangeScreenParametersNotification` and turns a
/// burst of them into at most one `DisplayChangeDecision`.
///
/// `read`, `schedule` and `onDecision` are injected for one reason: so
/// `--ui-selftest` can script a geometry change — a resolution change, a
/// hot-plug, a display going away — with no display, no capture stream, no
/// `Pipeline` and no run loop, and assert that a real change decides once and
/// a no-op change decides nothing. Nothing else in the daemon constructs one
/// with non-default arguments.
final class DisplayTopologyWatcher {
    /// The geometry the owner is currently normalizing against.
    private(set) var geometry: DisplayGeometry
    private var gate = DisplayChangeGate()
    private let read: () -> DisplayGeometry
    private let readInventory: () -> DisplayInventory
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let onDecision: (DisplayChangeDecision) -> Void
    private var observer: NSObjectProtocol?
    private var stopped = false

    init(
        geometry: DisplayGeometry,
        read: @escaping () -> DisplayGeometry,
        readInventory: @escaping () -> DisplayInventory = { DisplayInventory.current() },
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void
            = { delay, body in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: body) },
        onDecision: @escaping (DisplayChangeDecision) -> Void
    ) {
        self.geometry = geometry
        self.read = read
        self.readInventory = readInventory
        self.schedule = schedule
        self.onDecision = onDecision
    }

    /// Starts observing. Main thread; idempotent. Live runs only — `--process`
    /// never reaches `Pipeline.start`, so no headless log can move.
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.note() }
    }

    /// Stops observing AND disarms a decision that is already coalescing: the
    /// owner's `shutdown()` has printed its summary and latched `suppressed`, so
    /// a decision landing after it would reset state nobody reads and write one
    /// more record after the close. The injected `schedule` has no cancel, so
    /// the armed closure checks this instead.
    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        stopped = true
    }

    /// One notification (or a scripted one, from the selftest). Main thread.
    func note() {
        guard gate.note() else { return }
        schedule(DisplayChangeGate.coalesceSecs) { [weak self] in self?.fire() }
    }

    /// The coalesced decision. Main thread.
    func fire() {
        guard !stopped else {
            // Armed before `stop()`, landing after it: drop the decision and
            // re-open the gate so nothing is left half-pending.
            _ = gate.fire()
            return
        }
        let coalesced = gate.fire()
        let next = read()
        let decision = DisplayChangeDecision(
            from: geometry, to: next, inventory: readInventory(), coalesced: coalesced)
        if decision.changed { geometry = next }
        onDecision(decision)
    }
}
