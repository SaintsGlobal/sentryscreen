import AppKit
import Combine
import SwiftUI

// Menu bar item + popover.
// One status item per admin session; it renders the glyph table below and
// hosts the popover. Creation and removal are the caller's (main.swift
// syncStatusItem / UIDemoController.apply): this class only exists while an
// icon should exist.

/// The four status glyphs (spec §9.1). One table, two consumers — the
/// menu-bar button (`SentryLanternGlyph`) and the popover header tile — so
/// the bar and the popover can never disagree about the state.
///
/// OWNER 2026-09-28 (app UI redesign plan §2): Lantern's face replaces the
/// shield symbols in the menu bar, and paused and needs attention keep
/// separate icons (session 461068e4 line 4362). This supersedes the
/// 2026-08-26 shield table and its green/red tints: the board carries the
/// state in the face's shape, with a red badge for paused and needs
/// attention.
enum UIGlyph: String {
    case protecting, paused, degraded, starting

    /// The popover header's tile symbol for a state that is not protecting
    /// (Popover-Paused: pause bars; Popover-NeedsPermission: a slashed
    /// shield). Protecting draws Lantern's face instead.
    var headerSymbol: String {
        switch self {
        case .protecting, .starting: return "hourglass"
        case .paused: return UISymbol.pause
        case .degraded: return "shield.slash"
        }
    }
}

final class UIStatusItem: NSObject, NSPopoverDelegate {
    private let item: NSStatusItem
    private let popover = NSPopover()
    private let state: UIState
    /// Mutations + the PIN gate the popover's controls run through
    /// (UISettingsSheet.swift). Held here because the unlock window dies with
    /// the popover (spec §4.2) and this object owns that lifetime.
    private let actions: UIActions
    /// Activity feed; its reads and timer run only between show and close.
    private let activity: UIActivity
    private var observer: AnyCancellable?
    private var shownGlyph: UIGlyph?
    private var shownDescription: String?
    private var shownAllGood: Bool?
    private var appearanceOverride: NSAppearance?
    /// Set by `remove()`. Everything this object shares with the rest of the
    /// UI — `UIRegistry.shared`, the one `UIActivity`, the one `UIActions` —
    /// outlives it and is handed straight to the NEXT status item (the reveal
    /// hotkey rebuilds one), so a delegate callback arriving after removal
    /// must not touch any of them. MEASURED 2026-08-22: `remove()`'s close
    /// still delivers `popoverDidClose` (this object is held one turn past
    /// it), and under full-E2E-suite load that callback landed AFTER the
    /// rebuilt popover had registered its controls — `removeAll()` then wiped
    /// the live generation's registry (`hide-icon.txt` failed 71 with
    /// `registered: []`) and `activity.stop()` killed its feed.
    private var removed = false

    init(state: UIState, actions: UIActions, activity: UIActivity) {
        self.state = state
        self.actions = actions
        self.activity = activity
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = item.button {
            button.target = self
            button.action = #selector(toggle)
            // Left and right click show the same popover (spec §9.1).
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.delegate = self
        // §17.7: a spawned `screencapture` takes focus and would dismiss a
        // transient popover mid-script. Under a UI script the driver owns
        // dismissal (`close`); in production a click elsewhere dismisses.
        popover.behavior = UIDriver.scriptPath == nil ? .transient : .applicationDefined
        // @Published fires BEFORE the value lands, so refresh on the next
        // main-thread turn — a direct call here would paint the previous
        // glyph and the bar would lag one transition behind forever.
        observer = state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        refresh(force: true)
    }

    var isShown: Bool { popover.isShown }

    /// The popover's own window number while shown, else 0. The driver's
    /// screenshot path refuses to run on 0 — there is no other capture form.
    var windowNumber: Int { isShown ? (popover.contentViewController?.view.window?.windowNumber ?? 0) : 0 }
    var contentView: NSView? { popover.contentViewController?.view }

    // MARK: Glyph

    /// The menu-bar image for one glyph: a FRESH NSImage every time (a
    /// mutated shared image kept its previous configuration, which is how a
    /// green shield once survived the flip to paused). `SentryLanternGlyph`
    /// sets `isTemplate` per glyph, in both directions.
    static func glyphImage(_ glyph: UIGlyph, allGood: Bool = false, description: String) -> NSImage {
        let image = SentryLanternGlyph.image(for: glyph, allGood: allGood)
        image.accessibilityDescription = description
        return image
    }

    /// Repaints the button for the current state.
    private func refresh(force: Bool = false) {
        guard let button = item.button else { return }
        let glyph = state.glyph
        let allGood = state.menuBarBadgeOK
        let description = state.statusSummary
        // Keyed on the tooltip TOO, not on the glyph alone: extending a pause
        // 15m → 1h leaves the glyph on `.paused` while
        // `SentryScreen — paused until 3:45 PM` moves, and a glyph-only guard
        // would leave the old deadline in the tooltip and in the
        // accessibility label until some later transition happened to change
        // the glyph.
        guard force || glyph != shownGlyph || description != shownDescription || allGood != shownAllGood
        else { return }
        shownGlyph = glyph
        shownDescription = description
        shownAllGood = allGood
        button.image = Self.glyphImage(glyph, allGood: allGood, description: description)
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }

    // MARK: Popover

    @objc func toggle() {
        if popover.isShown { close() } else { open() }
    }

    /// nil when the popover is shown, else why not. A status item created
    /// this run-loop turn has a zero-height menu-bar window (MEASURED
    /// 2026-08-22: frame (0,0,30,0) on the first turn; NSPopover.show then
    /// silently does nothing and isShown stays false) — so say so, and let
    /// the caller retry.
    @discardableResult
    func open() -> String? {
        guard let button = item.button else { return "status item has no button" }
        if popover.isShown { return nil }
        guard let bar = button.window, bar.frame.height > 0 else {
            return "status item not laid out in the menu bar yet"
        }
        // §9.7: an accessory app's popover does not take keyboard focus by
        // default, which would break PIN entry in slice 5. NSApp.activate
        // does NOT change the activation policy — no Dock icon appears.
        NSApp.activate(ignoringOtherApps: true)
        // A fresh hosting controller per open, dropped in popoverDidClose, so
        // every show is a real SwiftUI appear and every close a real
        // disappear (controls re-register via UIRegistry). MEASURED
        // 2026-08-22: with one long-lived controller neither .onDisappear
        // nor a second .onAppear ever fired.
        // The text scale is read HERE, once per open (UIAccessibility.swift):
        // `UITextScale.current` is `standard` in production, and the
        // `textsize` script action — which refuses to run while the popover is
        // shown — is the only thing that ever changes it.
        let controller = NSHostingController(
            rootView: UIPopoverView(state: state, actions: actions, activity: activity)
                .environment(\.uiTextScale, UITextScale.current))
        // The popover must follow the SwiftUI content when a state change
        // resizes it WHILE it is open (a pause taken, capture lost, a section
        // collapsing). MEASURED 2026-08-22 without this: the window grew but
        // the content kept the old anchor — the header rendered off the top
        // edge with an equal band of dead space at the bottom.
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
        return popover.isShown ? nil : "NSPopover.show did not show"
    }

    func close() {
        popover.performClose(nil)
    }

    /// Test-only appearance override (spec §10.2 `appearance`, --ui-demo
    /// only). MEASURED 2026-08-22 with the system in Dark: setting
    /// `NSApp.appearance = .aqua` left the popover dark — its window inherits
    /// from the status-item (menu bar) window, not from NSApp — so the light
    /// path was never actually rendered. Setting it on the NSPopover is what
    /// re-renders it. nil restores inheritance.
    func setAppearance(_ appearance: NSAppearance?) {
        appearanceOverride = appearance
        popover.appearance = appearance
        popover.contentViewController?.view.window?.appearance = appearance
    }

    func popoverDidShow(_ notification: Notification) {
        // SPEC §8.1(1): a prompt under an overlay is useless. Overlay.swift
        // paints covers at .screenSaver; the popover sits one level above.
        popover.contentViewController?.view.window?.level =
            NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        // The window is created by `show`, so a --ui-demo appearance set
        // before the first open is applied to it here.
        if let appearanceOverride {
            popover.contentViewController?.view.window?.appearance = appearanceOverride
        }
        // §9.7 again: the window exists only now, and a popover shown while
        // another app is frontmost never becomes key on its own.
        popover.contentViewController?.view.window?.makeKey()
        // Spec §7.3: first read on open, then every refreshSecs while open.
        activity.start()
    }

    /// Fires after the (animated) close completes — MEASURED 2026-08-22:
    /// isShown stays true ~570 ms after performClose; UIDriver's `close`
    /// waits for it.
    func popoverDidClose(_ notification: Notification) {
        // `remove()` already did all of this, synchronously, for the close it
        // started — and this object no longer owns any of the shared state.
        guard !removed else { return }
        activity.stop()
        popover.contentViewController = nil
        UIRegistry.shared.removeAll()
        // Spec §4.2: the unlock window dies with the popover, so a walk-away
        // never leaves the parent controls unlocked. Also drops any pending
        // mutation and clears the PIN fields.
        actions.lock()
    }

    /// Tears the item down. The close-side work happens HERE and not only in
    /// `popoverDidClose`, because on this path the delegate does not survive
    /// long enough to be called: `remove()` is reachable synchronously from
    /// inside the popover's own SwiftUI action (Settings → Show menu bar icon
    /// → off → write → UISettingsStore.onChange → syncStatusItem) and from the
    /// other admin session's write on the 1 Hz poll. `performClose` settles
    /// ~570 ms later (see `popoverDidClose`'s receipt), but the caller drops
    /// this object — the popover's weak delegate — the instant this returns,
    /// so `popoverDidClose` is never delivered. Without this the PIN unlock
    /// window outlived the popover it was granted for (spec §4.2 fail-open:
    /// the icon comes back unlocked, Change PIN… included) and the activity
    /// timer kept scanning with no popover open (§7.3).
    ///
    /// The ordinary close path keeps running them in `popoverDidClose` — a
    /// popover dismissed without removal never comes through here. What that
    /// path must NOT do is run them a second time for the close this method
    /// started, hence `removed`. The work lives in `remove()` rather than in
    /// the two call sites
    /// (main.swift `syncStatusItem`, `UIDemoController.apply`) because this is
    /// the only code those two share — a fix in `syncStatusItem` would be
    /// unreachable from `--ui-demo` and therefore untestable.
    func remove() {
        guard !removed else { return }
        removed = true
        observer = nil
        activity.stop()
        // Before removeAll(): `lock()` publishes `layer = .none`, and a
        // re-render on that publish can re-register root-layer controls.
        actions.lock()
        UIRegistry.shared.removeAll()
        // `close()`, not `performClose(nil)`: nothing is waiting on the
        // animation here (the driver's `close` action polls `isShown`, which
        // reads false as soon as the caller drops the item), and the
        // non-animated close leaves no window mid-flight to release.
        popover.close()
        // One main-thread turn later, holding `self` — and with it the popover
        // and its hosting controller — alive across it: this runs inside that
        // hosting controller's own button action, and releasing the view out
        // from under the action still on the stack is an AppKit hazard.
        DispatchQueue.main.async { self.dropItem() }
    }

    private func dropItem() {
        NSStatusBar.system.removeStatusItem(item)
    }
}

extension UIState {
    /// The green check on the menu-bar face (owner 2026-10-20): protecting,
    /// AND the setup checks onboarding itself requires all pass
    /// (`setupHealthy`, from `UIOnboardingRuntime.setupHealthy`). Anything
    /// else falls back to the glyph's own badge or none.
    var menuBarBadgeOK: Bool { Self.menuBarBadgeOK(glyph: glyph, setupHealthy: setupHealthy) }

    static func menuBarBadgeOK(glyph: UIGlyph, setupHealthy: Bool) -> Bool {
        glyph == .protecting && setupHealthy
    }

    /// Glyph for the current state (spec §9.1). Paused wins over health, the
    /// same precedence `headerText` uses: a paused machine is the state the
    /// parent asked for, and saying "protecting" over it would be a lie.
    var glyph: UIGlyph {
        if pauseUntil != nil { return .paused }
        switch protection {
        case .starting: return .starting
        case .protecting: return .protecting
        // 2026-09-11: a dead detector is not a green shield.
        // Both failure kinds share the degraded glyph — the menu bar has one
        // bit to spend, and "not doing what the shield promises" is that bit;
        // WHICH failure it is belongs in the popover, which names it.
        case .detectorFailing, .captureLost: return .degraded
        }
    }

    /// Tooltip and accessibility description (spec §9.1 last column), e.g.
    /// `SentryScreen — paused until 3:45 PM`.
    var statusSummary: String {
        switch glyph {
        case .protecting: return "SentryScreen — protecting"
        // The glyph collapses the two failures; the tooltip has room to
        // separate them, and "interrupted" is the true one for a held-cover
        // detector fault.
        case .degraded:
            return protection.detectorIsFailing
                ? ProtectionCopy.detectorSummary : "SentryScreen — not protecting"
        case .starting: return "SentryScreen — starting"
        case .paused:
            guard let until = pauseUntil else { return "SentryScreen — paused" }
            if until == .distantFuture { return "SentryScreen — paused until this Mac restarts" }
            return "SentryScreen — paused until \(UIState.clockTime.string(from: until))"
        }
    }
}
