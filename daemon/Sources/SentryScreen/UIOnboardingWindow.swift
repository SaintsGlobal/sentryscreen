import AppKit
import Combine
import SwiftUI

/// Owns the single dedicated parent-onboarding window. The caller retains one
/// controller for the application session; calling `present()` again reuses
/// this window instead of creating competing setup surfaces.
@MainActor
final class UIOnboardingWindowController: NSWindowController, NSWindowDelegate {
    private static let setupWindowTitle = "SentryScreen Setup"
    private static let completionWindowTitle = "SentryScreen Setup Complete"
    /// MEASURED Receipt: the 25-scenario visual acceptance renders use a
    /// 560-by-520-point window with no clipped control or text.
    private static let intendedContentSize = NSSize(width: 560, height: 520)
    /// ASSUMED Receipt: 460 by 420 keeps the window resizable without allowing
    /// a size below the current content hierarchy. Native scaling remains in
    /// the owner-attended accessibility matrix.
    private static let minimumContentSize = NSSize(width: 460, height: 420)

    let presentation: UIOnboardingPresentation
    private let onCompletionPresented: @MainActor () -> Void
    /// Whether the menu-bar icon exists right now (AppDelegate: the status
    /// item is constructed only once onboarding is complete and
    /// `showMenuBarIcon` is on). The window may be closed ONLY while it is:
    /// the popover's own action is the way back, and a window closed with
    /// no icon strands the parent (owner 2026-09-07, INVARIANT enforced in
    /// `closable`). Defaults to false: no icon, no close.
    var menuBarIconVisible: () -> Bool = { false }
    private var programmaticClose = false
    private var completionPresentationReported = false
    private var surfaceObserver: AnyCancellable?

    init(
        presentation: UIOnboardingPresentation,
        onCompletionPresented: @escaping @MainActor () -> Void = {}
    ) {
        self.presentation = presentation
        self.onCompletionPresented = onCompletionPresented

        let hostingController = NSHostingController(
            rootView: UIOnboardingRootView(presentation: presentation))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.intendedContentSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = Self.setupWindowTitle
        window.contentViewController = hostingController
        window.contentMinSize = Self.minimumContentSize
        // On macOS 26, attaching a scroll-based NSHostingController can
        // replace the initializer's content size with its zero-height fitting
        // size. Reapply the intended size after the controller is attached.
        window.setContentSize(Self.intendedContentSize)
        window.backgroundColor = SentryColor.NS.paper
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        // Keep the setup window at the normal app level. It must remain open
        // when the parent moves to System Settings, but it must not cover or
        // compete with that system-owned permission surface.
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        super.init(window: window)
        window.delegate = self
        presentation.requestClose = { [weak self] in self?.window?.performClose(nil) }
        surfaceObserver = presentation.$surface.sink { [weak self] _ in
            DispatchQueue.main.async { self?.syncWindowState() }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp)
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Presents or refocuses the one setup window. SentryScreen is an
    /// accessory app, so explicit activation is required for keyboard input.
    func present() {
        guard let window else { return }
        syncWindowState()
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        reportCompletionPresentationIfNeeded()
    }

    /// Applies one authoritative coordinator step. A success confirmation is
    /// shown once; a completed installation whose confirmation was already
    /// recorded does not reopen setup after an update or normal launch.
    func present(_ step: UIOnboardingStep) {
        guard presentation.apply(step) else {
            dismiss()
            return
        }
        present()
    }

    func dismiss() {
        programmaticClose = true
        close()
        programmaticClose = false
        completionPresentationReported = false
    }

    /// Used by the window-only UI harness. nil restores system appearance.
    func setAppearance(_ appearance: NSAppearance?) {
        window?.appearance = appearance
    }

    /// Used by the window-only UI harness (`textsize`, UIAccessibility.swift).
    /// nil on success, else why. Publishing on the presentation re-renders the
    /// one long-lived window; the window's own content size is unchanged, so
    /// the wizard's ScrollView is what absorbs the taller content.
    func setTextSize(_ name: String) -> String? {
        guard let scale = UITextScale.named[name] else {
            return "textsize wants \(UITextScale.acceptedValues), got '\(name)'"
        }
        presentation.textScale = scale
        return nil
    }

    var visibleWindowNumber: Int? {
        guard let window, window.isVisible else { return nil }
        return window.windowNumber
    }

    func windowWillClose(_ notification: Notification) {
        presentation.send(.dismissWindow)
    }

    /// Pure. A hold or repair surface may be closed (red button, Cmd-W,
    /// Escape, the card's Close) only while the menu-bar icon is shown —
    /// the popover reopens it (Quit is no way out: launchd KeepAlive
    /// relaunches the agent). Never closable:
    /// the completion card (Done records the acknowledgment) and any
    /// in-flight operation. Recovery surfaces keep their own mapping
    /// (`windowShouldClose`) and are not decided here. With the icon
    /// hidden — every first-run step, since the item is constructed only
    /// once onboarding completes — nothing is closable.
    nonisolated static func closable(_ surface: UIOnboardingSurface, menuBarIconVisible: Bool) -> Bool {
        guard menuBarIconVisible else { return false }
        switch surface {
        case .protectionOn(showConfirmation: true),
            .createPIN(isSaving: true, error: _),
            .recoveryAuthentication(isAuthenticating: true, error: _),
            .recoveryNewPIN(isSaving: true, error: _),
            .preparing, .verifying:
            return false
        default:
            return true
        }
    }

    private var closable: Bool {
        Self.closable(presentation.surface, menuBarIconVisible: menuBarIconVisible())
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if programmaticClose { return true }
        switch presentation.surface {
        case .protectionOn(showConfirmation: true):
            // Only the visible Done action records the parent's acknowledgment.
            // Refuse alternate close requests so Cmd-W cannot skip that action.
            NSSound.beep()
        case .recoveryAuthentication(isAuthenticating: false, error: _),
            .recoveryNewPIN(isSaving: false, error: _):
            presentation.send(.cancelPINRecovery)
        case .recoveryComplete:
            presentation.send(.finishPINRecovery)
        default:
            // Close = hide; windowWillClose sends .dismissWindow and the
            // popover's action presents the window again.
            if closable { return true }
            NSSound.beep()
        }
        return false
    }

    /// Escape (the responder chain's `cancelOperation:` ends here for an
    /// NSWindow → its controller) is the same close request as the button.
    override func cancelOperation(_ sender: Any?) {
        window?.performClose(sender)
    }

    /// The title-bar close control is enabled where `closable` says so and
    /// on the recovery surfaces, whose red button maps to the same safe
    /// action as their visible button. `presentation.closable` mirrors it
    /// for the card's own Close button.
    private func syncWindowState() {
        let isCompletion: Bool
        let enabled: Bool
        switch presentation.surface {
        case .recoveryAuthentication(isAuthenticating: false, error: _),
            .recoveryNewPIN(isSaving: false, error: _), .recoveryComplete:
            enabled = true
        default:
            enabled = closable
        }
        if presentation.closable != closable { presentation.closable = closable }
        if case .protectionOn(showConfirmation: true) = presentation.surface {
            isCompletion = true
        } else {
            isCompletion = false
            completionPresentationReported = false
        }
        window?.title = isCompletion
            ? Self.completionWindowTitle
            : Self.setupWindowTitle
        window?.standardWindowButton(.closeButton)?.isEnabled = enabled
        reportCompletionPresentationIfNeeded()
    }

    /// Reports only a visible completion surface. This is an integration seam
    /// for a durable log Receipt; it does not change onboarding state.
    private func reportCompletionPresentationIfNeeded() {
        guard !completionPresentationReported,
            window?.isVisible == true,
            case .protectionOn(showConfirmation: true) = presentation.surface
        else { return }
        completionPresentationReported = true
        onCompletionPresented()
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        presentation.applicationDidReturnFromExternalSettings()
    }
}
