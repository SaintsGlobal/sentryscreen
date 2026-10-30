import SwiftUI

// Accessibility-id registry for the parent UI.
// Every interactive control registers itself under a stable id so the
// scripted driver (UIDriver) can tap/read/assert it with no CGEvent
// synthesis and no Accessibility grant. Main thread only.

struct UIControl {
    enum Kind { case button, text, field, toggle, picker }
    let id: String
    let kind: Kind
    /// Current visible value: label text, field contents, picker selection.
    let read: () -> String
    let activate: (() -> Void)?
    let setText: ((String) -> Void)?
    let enabled: () -> Bool
    /// Identity of the registering view instance (one per `.uiControl`, held
    /// in the modifier's `@State`), so an unregister can prove it is dropping
    /// its OWN registration. Ids are stable strings shared across popover
    /// generations — see `unregister(_:token:)`.
    var token = UUID()
}

final class UIRegistry {
    static let shared = UIRegistry()
    /// Every LIVE registration for an id, oldest first — not one entry per id.
    /// MEASURED 2026-08-22: SwiftUI evaluates a control's modifier twice on
    /// some layer swaps (two instances, two tokens), and the duplicate then
    /// disappears — with one entry per id the duplicate's registration had
    /// already overwritten the on-screen one, and its `.onDisappear` deleted
    /// it, leaving the id unregistered while the control was visibly there
    /// (`hide-icon.txt` flaked 2 runs in 6 with
    /// `registered: ["ui.status.detail", "ui.status.header"]`). `control()`
    /// answers with the newest, so a genuine replacement still wins.
    private var controls: [String: [UIControl]] = [:]

    func register(_ c: UIControl) {
        var list = controls[c.id] ?? []
        list.removeAll { $0.token == c.token }
        list.append(c)
        controls[c.id] = list
    }
    /// Drops `id` only if the live entry is still the one `token` registered.
    ///
    /// MEASURED 2026-08-22: SwiftUI runs the outgoing tree's `.onDisappear`
    /// arbitrarily late — a turn or more after the incoming branch's
    /// `.onAppear` within one popover, and (hide the icon, bring it back)
    /// after a WHOLE new popover has registered the same ids. Unregistering by
    /// id alone let a dead tree delete the live tree's controls:
    /// `hide-icon.txt` failed 71 with `registered: []` under full-suite load,
    /// and the per-script 400 ms waits were papering over the same race at
    /// layer swaps.
    func unregister(_ id: String, token: UUID) {
        guard var list = controls[id] else { return }
        list.removeAll { $0.token == token }
        controls[id] = list.isEmpty ? nil : list
    }
    /// Popover close. MEASURED 2026-08-22: SwiftUI `.onDisappear` does NOT
    /// fire when a long-lived NSPopover.contentViewController is closed, so
    /// without this every id stayed registered and a script could assert or
    /// tap a hidden control and pass. The popover is the only host of
    /// registered controls, so clearing all is exact.
    func removeAll() {
        controls.removeAll()
        // The frames belong to the tree that just went away; leaving them
        // would let `assertfits` measure a popover that is no longer there.
        UILayoutProbe.shared.clear()
    }
    func control(_ id: String) -> UIControl? { controls[id]?.last }
    var ids: Set<String> { Set(controls.keys) }

    /// Ids that must be registered once the popover is open in `state`
    /// (spec Addendum 3: most ids exist only in one state). Grows with each
    /// UI slice; the selftest checks a fixed matrix of states against this,
    /// the E2E scripts `waitfor` the ids their own state requires.
    static func requiredIDs(for state: DemoState) -> Set<String> {
        var ids: Set<String> = ["ui.status.header", "ui.status.detail"]
        // Fix… is keyed on capture health ALONE, exactly as the view is
        // (UIState.isDegraded): a paused-and-lost machine still needs the
        // way back, so gating it on the paused-wins header precedence would
        // demand an id the view does not render.
        if state.health == .lost {
            // OWNER 2026-08-26: degraded shows ONLY the way back — Fix…
            // plus the resume row if paused. Nothing below it exists.
            // The persistent capture row sits above Fix… in the same
            // card (2026-09-07): while capture is
            // down it always exists, whatever the cause — only its
            // sentence changes with `screenRecordingOff`.
            ids.formUnion(["ui.status.capture", "ui.status.fix"])
            if state.paused != .none { ids.insert("ui.pause.resume") }
            return ids
        }
        // 2026-09-11: both rows live in the healthy
        // branch, above everything else (UIPopoverView.sections). Reached only
        // past the degraded early return — a lost capture owns the surface, and
        // its own card says so.
        // `.protecting`, not just "not lost" (review 2026-09-11): the view draws
        // this row on `protection.detectorIsFailing`, which `ProtectionHealth`
        // only composes while capture is PROTECTING — `starting` outranks the
        // detector. `health=starting detector=failing` is an expressible demo
        // state, and registering the id there would fail a future E2E script
        // with a missing-id error that is this table's bug, not the view's.
        if state.detectorFailing, state.health == .protecting { ids.insert("ui.status.detector") }
        if state.displayScopeValue.hasUnprotectedDisplays { ids.insert("ui.status.displays") }
        if state.devstate { ids.insert("ui.status.devstate") }
        // §4.3: the amber row exists exactly while no PIN is set.
        if state.pin == .unset { ids.insert("ui.status.nopin") }
        // §9.2: the pause section collapses to one row while paused. Reached
        // only when health != .lost — the degraded branch above returns —
        // so the presets here are the healthy machine's, never a disabled
        // set. (Before owner 2026-08-26 the presets stayed registered and
        // disabled while degraded; they are now absent, and
        // `status-degraded.txt` asserts `assertmissing ui.pause.15m`.)
        // App UI redesign: one "Pause protection…" button; the presets sit
        // behind it in the "Pause for…" chooser (scripts tap ui.pause.open).
        if state.paused == .none {
            ids.insert("ui.pause.open")
        } else {
            ids.insert("ui.pause.resume")
        }
        // Sensitivity and recent activity are settings-only operational
        // detail. A DemoState cannot express the open Settings layer, so the
        // E2E scripts wait for those ids after `ui.settings.open`.
        // §9.2 footer: Settings… exists in every state ("Turn off
        // protection…" left it 2026-09-28; the chooser's "Until this Mac
        // restarts" is its one path). The settings panel's own ids live only while that layer
        // is up, which a DemoState cannot express, so the E2E scripts
        // `waitfor` them instead (Addendum 3).
        ids.formUnion(["ui.settings.open"])
        return ids
    }
}

// MARK: - Layout probe (`assertfits`, spec §10.2)

/// Every registered control's frame in the popover's own coordinate space,
/// merged on the way up the tree.
struct UIControlFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// The popover surface's own size, published by the same pass.
struct UISurfaceSizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// The Settings scroll document's laid-out size (the whole page, including
/// whatever is below the fold).
struct UIScrollDocumentSizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// The Settings scroll viewport's size (`UIMetrics.settingsViewportMaxHeight`
/// after scaling, or less when the page is short enough not to need it).
struct UIScrollViewportSizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// What `assertfits` reads. Exists ONLY for the UI E2E driver — nothing in the
/// product consults it — so that "the larger text sizes do not clip a control"
/// is a scripted assertion instead of a screenshot someone has to eyeball.
/// Main thread only, like the registry it sits beside.
final class UILayoutProbe {
    static let shared = UILayoutProbe()
    var surface = CGSize.zero
    var frames: [String: CGRect] = [:]
    /// Settings viewport and the page laid out inside it. Both zero when no
    /// scroll viewport is on screen. `assertfits` reports the difference so
    /// a page that outgrew its viewport is a measured number in the run log
    /// instead of a fold nobody sees (2026-09-11: the owner read a
    /// page that ended at "Version" as work that had not shipped).
    var scrollViewport = CGSize.zero
    var scrollDocument = CGSize.zero

    /// How far the Settings page reaches past its viewport, in points. Zero
    /// when the whole page is on screen.
    var scrollOverflow: CGFloat {
        guard scrollViewport.height > 0, scrollDocument.height > 0 else { return 0 }
        return max(0, scrollDocument.height - scrollViewport.height)
    }

    func clear() {
        surface = .zero
        frames = [:]
        scrollViewport = .zero
        scrollDocument = .zero
    }
}

private struct UIControlModifier: ViewModifier {
    let control: UIControl
    /// This view instance's identity, stable across re-renders and fresh for
    /// every new popover — the whole point of `unregister(_:token:)`.
    @State private var token = UUID()

    func body(content: Content) -> some View {
        var registered = control
        registered.token = token
        return content
            .accessibilityIdentifier(control.id)
            // Background, so publishing a frame cannot change one: a
            // `GeometryReader` in a background reads its parent's size and
            // proposes nothing back.
            .background(GeometryReader { proxy in
                Color.clear.preference(
                    key: UIControlFrameKey.self,
                    value: [control.id: proxy.frame(in: .named(UIPopoverView.rootSpace))])
            })
            .onAppear { UIRegistry.shared.register(registered) }
            .onDisappear { UIRegistry.shared.unregister(control.id, token: token) }
    }
}

extension View {
    /// Registers this view as a scriptable control. The closures must read
    /// the live source of truth (an ObservableObject or a @Binding), not a
    /// captured value: registration happens once, on appear.
    func uiControl(
        _ id: String, kind: UIControl.Kind, read: @escaping () -> String,
        activate: (() -> Void)? = nil, setText: ((String) -> Void)? = nil,
        enabled: @escaping () -> Bool = { true }
    ) -> some View {
        modifier(UIControlModifier(control: UIControl(
            id: id, kind: kind, read: read, activate: activate, setText: setText,
            enabled: enabled)))
    }
}

// MARK: - Scroll anchors (`scrollto`, spec §10.2)

/// The one `ScrollViewProxy` a popover can have, plus the anchor ids the
/// views inside it publish. Exists ONLY so the UI E2E driver can capture the
/// bottom of a panel taller than its viewport — nothing in the product reads
/// it, and a build with no scrollable panel on screen has no proxy, which is
/// why `scroll(to:)` returns a Bool the driver fails loudly on rather than a
/// silent no-op.
final class UIScrollAnchors {
    static let shared = UIScrollAnchors()
    private(set) var anchors: Set<String> = []
    var proxy: ScrollViewProxy?
    /// Anchors inside a scroll view NESTED in the page (2026-10-20: Recent
    /// activity's 3-row list): the inner proxy, and the page anchor of the
    /// nested view itself. `scroll(to:)` brings the nested view into the
    /// page first, then the row into the nested view.
    private var nested: [String: (proxy: ScrollViewProxy, container: String)] = [:]

    func register(_ id: String) { anchors.insert(id) }
    func unregister(_ id: String) { anchors.remove(id); nested[id] = nil }
    func register(_ id: String, in proxy: ScrollViewProxy, container: String) {
        anchors.insert(id)
        nested[id] = (proxy, container)
    }

    func scroll(to id: String) -> Bool {
        guard let proxy, anchors.contains(id) else { return false }
        if let inner = nested[id] {
            guard anchors.contains(inner.container) else { return false }
            proxy.scrollTo(inner.container, anchor: .bottom)
            inner.proxy.scrollTo(id, anchor: .bottom)
            return true
        }
        proxy.scrollTo(id, anchor: .bottom)
        return true
    }
}

extension View {
    /// Marks this view as a `scrollto` target under the id it already uses as
    /// a control id — one name, so a script cannot scroll to something it
    /// cannot then assert.
    func uiScrollAnchor(_ id: String) -> some View {
        self.id(id)
            .onAppear { UIScrollAnchors.shared.register(id) }
            .onDisappear { UIScrollAnchors.shared.unregister(id) }
    }

    /// A `scrollto` target inside a nested scroll view (`proxy`), which is
    /// itself the page anchor `container`.
    func uiScrollAnchor(_ id: String, in proxy: ScrollViewProxy, container: String) -> some View {
        self.id(id)
            .onAppear { UIScrollAnchors.shared.register(id, in: proxy, container: container) }
            .onDisappear { UIScrollAnchors.shared.unregister(id) }
    }
}
