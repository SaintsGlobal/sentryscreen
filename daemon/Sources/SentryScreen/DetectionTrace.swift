import CoreGraphics
import Foundation

// DETECTION VIEW (tuning tool, owner 2026-09-24): the shared interface
// between the trace builder (what the detector saw on one frame and why each
// box was covered or dropped) and the overlay that renders it. Types and the
// two small carriers only; the builder lives in DetectionTraceBuilder.swift
// and the overlay in DetectionViewOverlay.swift.
//
// Threading: a trace is built on detectQueue at the end of `Pipeline.step`
// from locals the step already computed (no extra detector work), published
// on `DetectionTraceBus` (latest wins, never blocks the detector), and
// rendered on main. `CurtainTraceRecorder` lives on detectQueue with the
// `Curtain` it is attached to.
//
// It is in the
// algorithm-loop unit list (scripts/build.sh) because Curtain.swift names
// `CurtainTraceRecorder`.

enum DetectionViewMode: String, CaseIterable {
    case off
    /// Covers and curtain are not PAINTED; the full pipeline still runs.
    case detectionsOnly = "detections-only"
    /// Protection stays on; outlines draw over the covers.
    case outlineOverCovers = "outline-over-covers"
}

/// Run-log event names. Never add these to `DiagnosticsAllowlist.runEvents`:
/// a trace names classes and window geometry, and diagnostics must not ship it.
enum DetectionViewEvent {
    static let lifecycle = "detection-view"
    static let snapshot = "detection-snapshot"
}

/// One detector frame, explained. Every box the detector returned (plus any
/// synthetic ones) appears once, in detector order, with the stage that
/// decided it.
struct DetectionTrace {
    let seq: UInt64
    let capturedAt: CFAbsoluteTime
    let builtAt: CFAbsoluteTime
    let screenPt: CGSize
    let policy: PolicyMode
    /// `Options.cover.rawValue` of the run.
    let coverMode: String
    let tuning: TuningPolicy
    /// Where `tuning` came from ("defaults", "config", "tuning.json", ...).
    let tuningSource: String
    /// True for a held frame (`Pipeline.holdCovers`): the detector threw and
    /// the covers on screen were kept; `boxes` is then empty.
    let detectorFailed: Bool
    let boxes: [Box]
    /// Boxes past the builder's cap, counted rather than dropped silently.
    let boxesOverflow: Int
    /// Blocked boxes a ran curtain walk left without an outcome. Every walk
    /// branch notes one, so anything above 0 means the recorder and the
    /// walk's merge disagree; the HUD says so instead of guessing.
    let walkUnattributed: Int
    let walk: CurtainWalk
    let windows: [CurtainWindow]
    let stats: Stats
    /// The zoom tile the detector ran on this frame (normalized, top-left),
    /// outlined by the view; nil with zoomTiles off.
    var zoomTile: CGRect? = nil

    struct Box: Equatable {
        /// Index in the raw detector list (synthetic boxes follow it).
        let index: Int
        let synthetic: Bool
        let rawLabel: String
        /// After covered-beats-exposed demotion; equal to `rawLabel` otherwise.
        let label: String
        let confidence: Float
        /// Normalized 0–1 over the captured display, TOP-LEFT origin (the
        /// builder flips `Detection.box`, which is Vision's bottom-left).
        let rect: CGRect
        /// Short side in screen points; nil when the screen size is unknown.
        let sidePt: Double?
        let demotion: Demotion?
        let policy: PolicyOutcome
        /// nil when the box never reached the region tracker.
        let region: RegionOutcome?
        /// nil when the box never reached the curtain.
        let curtain: CurtainOutcome?
        /// Settle re-check (`Detection.recheckFrom`): the score before the
        /// shifted pass raised it, 0 when only the shifted pass saw it.
        var recheckFrom: Float? = nil

        /// "Show weak detections": under `--conf`, trace-only.
        var isWeak: Bool {
            if case .weak = policy { return true }
            return false
        }
    }

    struct Demotion: Equatable {
        let to: String
        let overlap: Double
        let minOverlap: Double
    }

    enum PolicyOutcome: Equatable {
        case passes(floor: Float, sizeUnmeasured: Bool)
        /// Passed by score hysteresis (`TuningPolicy.keepGap`): under its
        /// start floor, at or above the keep floor, on a box that was
        /// already covered (the same label blocked there last frame). Region
        /// and media covers only; curtain mode never keeps a box.
        case kept(start: Float, keep: Float, sizeUnmeasured: Bool)
        /// Under the detector's `--conf` floor. Drawn only while "Show weak
        /// detections" is on; never reaches the policy, a region or a curtain.
        case weak(conf: Float)
        case belowThreshold(threshold: Float)
        case classOffInPolicy(mode: PolicyMode)
        case minBox(sidePt: Double?, minBoxPt: Double, minBoxFraction: Double)
        case thresholdStep(floor: Float, stepMinPt: Double, base: Float)
        case outsideROI
        case notPolicyClass
    }

    enum RegionOutcome: Equatable {
        case covered(regionID: Int)
        case entryPending(seen: Int, needed: Int)
        case underCurtain
        case notCovered
    }

    enum CurtainOutcome: Equatable {
        case credited(window: CGWindowID)
        case orphan
        case straddle(front: CGWindowID, held: Double, rewoundTo: CGWindowID?)
        case windowBelowFloor(window: CGWindowID)
        case ghostBanned(window: CGWindowID)
        case trailRedirect(from: CGWindowID, to: CGWindowID)
        case notHeldAtCapture(window: CGWindowID, ringYoung: Bool, rewoundTo: CGWindowID?)
        case walkSkipped
    }

    enum CurtainWalk: Equatable {
        case notCurtainMode
        case noBlockedBoxes
        case skipped(every: Int)
        case ran
    }

    struct CurtainWindow: Equatable {
        let id: CGWindowID
        let app: String?
        /// The window frame in `Box.rect`'s space: normalized 0–1 over the
        /// captured display, top-left origin, clamped to the display.
        let frame: CGRect
        let state: State

        /// Which evidence bar a pending window is climbing; raw values are
        /// the `TuningPolicy.CurtainRules` field names.
        enum Bar: String {
            case trigger = "triggerHits"
            case handoff = "handoffHits"
            case parole = "paroleHits"
        }

        enum State: Equatable {
            case pending(hits: Int, required: Int, bar: Bar)
            case curtained(holdLeftSecs: Double, cleanFrames: Int, cleanNeeded: Int)
            case leaving(kind: String, forSecs: Double)
            case lingering
        }
    }

    struct Stats: Equatable {
        let evaluatedFps: Double
        let detectMs: Double
        let stepMs: Double
        let idleSkipped: Int
        /// The PREVIOUS trace's whole cost on detectQueue (a trace cannot
        /// time itself): the curtain recorder's note arguments (rewind
        /// holder, held fraction, attributed merge), `Curtain.traceWindows`,
        /// the app-name lookups and the build. Budget:
        /// `DetectionTraceBuilder.traceBudgetMs`.
        let traceMs: Double
        /// The app-name lookups' share of `traceMs`. The tripwire leaves it
        /// out: a new window's first lookup is cold (MEASURED 4.97 ms on the
        /// test Mac, 2026-09-25) and is governed by `WindowOwner.p95BudgetMs`.
        var lookupMs: Double = 0
        /// What `DetectionTraceBuilder.traceBudgetMs` is compared against.
        var budgetedMs: Double { traceMs - lookupMs }
    }
}

/// detectQueue -> main hand-off for traces. `publish` never blocks on main:
/// it stores the newest trace under a lock and schedules at most one main
/// delivery; a trace replaced before delivery is superseded, not queued (the
/// overlay only ever shows the newest frame). `onTrace` is set and called on
/// main. `newest()` is safe from any thread.
final class DetectionTraceBus {
    var onTrace: ((DetectionTrace) -> Void)?
    private let lock = NSLock()
    private var latest: DetectionTrace?
    private var deliveryScheduled = false

    func publish(_ trace: DetectionTrace) {
        lock.lock()
        latest = trace
        let schedule = !deliveryScheduled
        deliveryScheduled = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [self] in
            lock.lock()
            let trace = latest
            deliveryScheduled = false
            lock.unlock()
            if let trace { onTrace?(trace) }
        }
    }

    func newest() -> DetectionTrace? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// Drops the newest trace; a delivery already scheduled then delivers
    /// nothing.
    func clear() {
        lock.lock()
        latest = nil
        lock.unlock()
    }
}

/// Per-update record of the curtain's decisions, attached to `Curtain` by
/// `Pipeline.setDetectionTrace` and read by the trace builder. detectQueue
/// only, like the `Curtain` that fills it. `begin` starts a detector-
/// evaluated update (a geometry-only tick leaves the last record alone);
/// `note` attributes one merged query's outcome to the indices of the
/// blocked detections it was merged from.
///
/// `queries` + `note(query:)`: the walk merges the blocked boxes before it
/// asks who owns them, and the merged list carries source indices only while
/// a crop writer is attached. Curtain hands the recorder the index lists of
/// the same merge once per walk (`Curtain.mergeAttributed`, whose rects equal
/// `Geometry.merge`'s — `--ui-selftest` "curtain: attributed merge"), so a
/// note site passes only its query index and the walk's own `merged` stays
/// exactly what it was.
final class CurtainTraceRecorder {
    private(set) var walk: DetectionTrace.CurtainWalk = .notCurtainMode
    private(set) var outcomes: [(blockedIndices: [Int], outcome: DetectionTrace.CurtainOutcome)] = []
    /// Blocked indices per merged walk query, in query order.
    private(set) var queries: [[Int]] = []
    /// Milliseconds this update spent evaluating the recorder's arguments
    /// (the attributed merge, rewind holders, held fractions): the trace's
    /// share of `Curtain.update`, counted into `Stats.traceMs`.
    private(set) var costMs = 0.0

    func begin(_ walk: DetectionTrace.CurtainWalk) {
        self.walk = walk
        outcomes.removeAll(keepingCapacity: true)
        queries.removeAll(keepingCapacity: true)
        costMs = 0
    }

    /// `queries` is an autoclosure so the merge it runs is timed here.
    func walk(queries: @autoclosure () -> [[Int]]) {
        let t0 = CFAbsoluteTimeGetCurrent()
        self.queries = queries()
        costMs += (CFAbsoluteTimeGetCurrent() - t0) * 1000
    }

    func note(_ blockedIndices: [Int], _ outcome: DetectionTrace.CurtainOutcome) {
        outcomes.append((blockedIndices: blockedIndices, outcome: outcome))
    }

    /// A query index outside `queries` is recorded against no box rather
    /// than guessed; the builder counts the blocked boxes a ran walk left
    /// without an outcome (`DetectionTrace.walkUnattributed`, a HUD
    /// warning), so a mismatch is visible, never silent. `outcome` is an
    /// autoclosure so its cost (a rewind holder, a held fraction) is timed.
    func note(query: Int, _ outcome: @autoclosure () -> DetectionTrace.CurtainOutcome) {
        let t0 = CFAbsoluteTimeGetCurrent()
        let o = outcome()
        costMs += (CFAbsoluteTimeGetCurrent() - t0) * 1000
        note(queries.indices.contains(query) ? queries[query] : [], o)
    }
}

