import AppKit
import Foundation
import SwiftUI

/// A separate LaunchServices app owns both macOS authorization and the final
/// result. It reuses the signed agent executable, but never starts protection.
/// No persistent service, credentials, network client, or test bypass is added.
///
/// One window (boards Uninstall-App, 2026-09 redesign): it waits for the
/// administrator password, then shows the result in the same window. It still
/// cannot be closed or quit until the result is known.
enum UninstallWorker {
    static func run() {
        var choice = Uninstall.Choice()
        let arguments = Array(CommandLine.arguments.dropFirst())
        let valid = arguments == ["--keep-settings", "--reset-permissions"]
            || arguments == ["--delete-settings", "--reset-permissions"]
        if valid { choice.keepSettings = arguments.first == "--keep-settings" }
        let selected = choice
        let model = UninstallerModel()
        launch(model: model, operation: {
            valid ? Uninstall.execute(Uninstall.appleScript(selected))
                : .failed(code: 64, message: "Invalid removal arguments. Open removal from SentryScreen Settings.")
        }, handle: { outcome, retry, finish in
            let retryAllowed: Bool
            switch outcome {
            case .failed, .cancelled: retryAllowed = valid && FileManager.default.isExecutableFile(atPath: Uninstall.scriptPath)
            default: retryAllowed = false
            }
            let result = UninstallerResult.make(outcome, choice: selected, retryAllowed: retryAllowed)
            model.screen = .result(result)
            model.act = { action in
                switch action {
                case .tryAgain: retry()
                case .done, .close: finish()
                }
            }
        })
    }

    /// Window, quit guard and the run-again loop, shared by `run()` and the
    /// fixture. `handle` receives the outcome with `retry` (back to the
    /// waiting screen and run `operation` again) and `finish` (close and quit).
    private static func launch(
        model: UninstallerModel, operation: @escaping () -> Uninstall.Outcome,
        handle: @escaping (Uninstall.Outcome, @escaping () -> Void, @escaping () -> Void) -> Void
    ) {
        let app = NSApplication.shared
        let session = UninstallerSession()
        app.delegate = session
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentViewController: NSHostingController(rootView: UninstallerView(model: model)))
        window.styleMask = [.titled, .closable]
        window.title = "SentryScreen Uninstaller"
        window.isRestorable = false
        window.delegate = session
        session.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        func start() {
            model.screen = .waiting
            session.setBusy(true)
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = operation()
                DispatchQueue.main.async {
                    session.setBusy(false)
                    handle(outcome, { start() }, { window.close(); app.terminate(nil) })
                }
            }
        }
        start()
        withExtendedLifetime(session) { app.run() }
    }

}

// MARK: - Window state

/// Quit and close guard: while the removal runs the window cannot be closed
/// and the app cannot be quit (the board dims the close button "Can't close
/// yet"). Behaviour carried over unchanged from the previous window.
private final class UninstallerSession: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var window: NSWindow?
    private var busy = true

    func setBusy(_ value: Bool) {
        busy = value
        window?.standardWindowButton(.closeButton)?.isEnabled = !value
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        busy ? .terminateCancel : .terminateNow
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !busy }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
}

final class UninstallerModel: ObservableObject {
    enum Screen { case waiting, result(UninstallerResult) }
    @Published var screen: Screen = .waiting
    var act: (UninstallerResult.Action) -> Void = { _ in }
}

/// Everything the result screen says, decided without any view so the
/// contract test can assert it. Boards Uninstall-App 2 to 5.
struct UninstallerResult: Equatable {
    enum Action: Equatable {
        case done, close, tryAgain
        var title: String {
            switch self {
            case .done: return "Done"
            case .close: return "Close"
            case .tryAgain: return "Try again"
            }
        }
    }
    enum Mark: Equatable { case ok, warning }
    struct Row: Equatable {
        let mark: Mark
        let text: String
        var note: String? = nil
        var emphasised = false
    }

    static let waitingTitle = "Enter the admin password"
    static let waitingBody = "macOS is asking now. Works offline."
    static let waitingNote = "This window stays open until it\u{2019}s done."
    /// uninstall.sh's preflight-refusal exit code (EX_USAGE); see `make`.
    static let refusedBeforeRemovalCode: Int32 = 64

    let headline: String
    var subline: String? = nil
    var rows: [Row] = []
    var footnote: String? = nil
    /// Exit code, script output, server receipt, installation reference:
    /// selectable text behind the Details disclosure. Empty hides it.
    var details = ""
    var detailsExpanded = false
    var failed = false
    /// The one mustard button of the screen.
    let primary: Action
    let secondary: Action?

    static func make(_ outcome: Uninstall.Outcome, choice: Uninstall.Choice, retryAllowed: Bool) -> UninstallerResult {
        switch outcome {
        case .removed:
            let rows = [
                Row(mark: .ok, text: "Gone for every user on this Mac", note: "Startup items and permissions too."),
                Row(mark: .ok, text: choice.keepSettings ? "Settings and PIN kept for a reinstall"
                                                         : "Settings and PIN deleted"),
            ]
            return UninstallerResult(
                headline: "SentryScreen is removed", rows: rows, primary: .done, secondary: nil)
        case .cancelled:
            return UninstallerResult(
                headline: "Removal cancelled", subline: "Nothing was changed.",
                primary: retryAllowed ? .tryAgain : .close, secondary: retryAllowed ? .close : nil)
        case let .failed(code, message):
            let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
            // Exit 64 is a refusal before anything is touched: every `exit 64`
            // in packaging/uninstall.sh precedes the first bootout or rm, and
            // `run()` uses 64 for invalid arguments. Only then is it safe to
            // say protection is untouched; every other failure fails closed.
            let refused = code == refusedBeforeRemovalCode
            return UninstallerResult(
                headline: refused ? "Removal didn\u{2019}t start" : "Removal failed",
                subline: refused ? "Nothing was changed. Protection is still on."
                                 : "It isn\u{2019}t confirmed, so don\u{2019}t count on protection.",
                details: "Exit code \(code)" + (text.isEmpty ? "" : "\n" + text),
                detailsExpanded: true, failed: true,
                primary: retryAllowed ? .tryAgain : .close, secondary: retryAllowed ? .close : nil)
        case .handedOff:
            preconditionFailure("The uninstaller executes removal; it cannot hand it off again.")
        }
    }
}

// MARK: - Palette

/// Receipt: the paper-and-ink values are copied from `SentryColor.NS`
/// (`SentryBrand.swift`, source DESIGN.md and the Uninstall-App board). They
/// are repeated here because the uninstall-contract target compiles only the
/// two uninstall files (`scripts/build.sh` `uninstall-contract`), so this
/// window cannot import the brand file. If `SentryColor.NS` changes, change
/// these in the same commit; a self-test that pins the two together is an
/// open item (UISelfTest is outside this slice).
private enum UninstallerPalette {
    static func room(_ day: UInt32, _ night: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            rgb(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? night : day)
        })
    }
    static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
    static let paper = room(0xf6ecd5, 0x1f1712)
    static let paper2 = room(0xecdcbb, 0x261c16)
    static let slip = room(0xfbf5e6, 0xe9dcc0)
    static let ink = room(0x2b1d16, 0xf3e6cc)
    static let ink2 = room(0x4a3326, 0xdccbaa)
    static let muted = room(0x6b5140, 0xb8a384)
    static let line = room(0xd1bf9c, 0x4a3d30)
    static let accent = room(0x8e3b22, 0xe9b949)
    static let accentSoft = room(0xf1dcb4, 0x3a2b1c)
    static let primary = room(0xd6a53a, 0xe2ae45)
    static let primaryInk = room(0x2b1d16, 0x2b1d16)
    static let edge = room(0x2b1d16, 0x000000)
    static let ok = room(0x3d6b30, 0x8fd69a)
    static let danger = room(0xa3311e, 0xff9d8a)
}

// MARK: - View

private struct UninstallerView: View {
    @ObservedObject var model: UninstallerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.screen {
            case .waiting: waiting
            case let .result(result): ResultView(result: result, act: model.act)
            }
        }
        .padding(EdgeInsets(top: 24, leading: 26, bottom: 22, trailing: 26))
        .frame(width: 440, alignment: .topLeading)
        .background(UninstallerPalette.paper)
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "lock")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(UninstallerPalette.ink2)
                .frame(width: 44, height: 44)
                .background(Circle().fill(UninstallerPalette.paper2))
                .overlay(Circle().strokeBorder(UninstallerPalette.line, lineWidth: 2))
                .accessibilityHidden(true)
            Text(UninstallerResult.waitingTitle)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(UninstallerPalette.ink)
                .accessibilityAddTraits(.isHeader)
            Text(UninstallerResult.waitingBody)
                .font(.system(size: 14)).foregroundStyle(UninstallerPalette.ink2)
            Text(UninstallerResult.waitingNote)
                .font(.system(size: 12.5)).foregroundStyle(UninstallerPalette.muted)
        }
    }
}

private struct ResultView: View {
    let result: UninstallerResult
    let act: (UninstallerResult.Action) -> Void
    @State private var showDetails: Bool

    init(result: UninstallerResult, act: @escaping (UninstallerResult.Action) -> Void) {
        self.result = result
        self.act = act
        _showDetails = State(initialValue: result.detailsExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if result.failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(UninstallerPalette.danger).accessibilityHidden(true)
                }
                Text(result.headline)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(UninstallerPalette.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            if let subline = result.subline {
                Text(subline).font(.system(size: 14)).foregroundStyle(UninstallerPalette.ink2)
            }
            if !result.rows.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(result.rows.enumerated()), id: \.offset) { _, row in rowView(row) }
                }
            }
            if let footnote = result.footnote {
                Text(footnote).font(.system(size: 13)).foregroundStyle(UninstallerPalette.ink2)
            }
            // Inline Details disclosure. The notices slice's shared component
            // replaces this private copy when it lands; the uninstall-contract
            // target cannot import it (see UninstallerPalette).
            if !result.details.isEmpty, showDetails {
                Text(verbatim: result.details)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(UninstallerPalette.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
                    .background(RoundedRectangle(cornerRadius: 8).fill(UninstallerPalette.slip))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(UninstallerPalette.line, lineWidth: 2))
            }
            HStack(spacing: 12) {
                if !result.details.isEmpty {
                    Button { showDetails.toggle() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showDetails ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .bold)).accessibilityHidden(true)
                            Text("Details")
                        }
                    }
                    .buttonStyle(UninstallerQuietStyle())
                    .accessibilityValue(showDetails ? "expanded" : "collapsed")
                }
                Spacer(minLength: 0)
                if let secondary = result.secondary {
                    Button(secondary.title) { act(secondary) }.buttonStyle(UninstallerSecondaryStyle())
                }
                Button(result.primary.title) { act(result.primary) }
                    .buttonStyle(UninstallerPrimaryStyle())
                    .keyboardShortcut(.defaultAction)
                    .padding(.trailing, 3).padding(.bottom, 4)
            }
            .padding(.top, 4)
        }
    }

    private func rowView(_ row: UninstallerResult.Row) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: row.mark == .ok ? "checkmark" : "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(row.mark == .ok ? UninstallerPalette.ok : UninstallerPalette.accent)
                .frame(width: 18).padding(.top, 1).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.text).font(.system(size: 14, weight: row.emphasised ? .semibold : .regular))
                if let note = row.note {
                    Text(note).font(.system(size: 12.5))
                        .foregroundStyle(row.emphasised ? UninstallerPalette.ink2 : UninstallerPalette.muted)
                }
            }
            .foregroundStyle(UninstallerPalette.ink)
        }
        .padding(row.emphasised ? EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10) : EdgeInsets())
        .background(row.emphasised
            ? AnyView(UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 7,
                bottomTrailingRadius: 11, topTrailingRadius: 8, style: .continuous)
                .fill(UninstallerPalette.accentSoft))
            : AnyView(Color.clear))
        .padding(.horizontal, row.emphasised ? -10 : 0)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Buttons (board Uninstall-App: 44 pt, ink edge, 3/4 offset shadow)

private struct UninstallerPrimaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 12,
            bottomTrailingRadius: 15, topTrailingRadius: 11, style: .continuous)
        let offset = CGSize(width: 3, height: 4)
        let pressed = configuration.isPressed
        configuration.label
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(UninstallerPalette.primaryInk)
            .padding(.horizontal, 22)
            .frame(minWidth: 120, minHeight: 44)
            .background(UninstallerPalette.primary, in: shape)
            .overlay(shape.strokeBorder(UninstallerPalette.edge, lineWidth: 3))
            .background(shape.fill(UninstallerPalette.edge).offset(pressed ? .zero : offset))
            .offset(pressed ? offset : .zero)
            .contentShape(shape)
    }
}

private struct UninstallerSecondaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 9,
            bottomTrailingRadius: 13, topTrailingRadius: 10, style: .continuous)
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(UninstallerPalette.ink)
            .padding(.horizontal, 18)
            .frame(minHeight: 44)
            .overlay(shape.strokeBorder(UninstallerPalette.ink, lineWidth: 2.5))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(shape)
    }
}

private struct UninstallerQuietStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .underline()
            .foregroundStyle(UninstallerPalette.accent)
            .frame(minHeight: 34)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}
