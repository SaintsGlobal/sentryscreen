import AppKit
import Foundation

// "Remove SentryScreen…" — the in-app removal path (SPEC §8.1(7); owner
// decision 2026-09-05: a parent must be able to remove SentryScreen from the
// app, not only by typing a sudo command into Terminal).
//
// The behaviour is DELIBERATELY thin: this file decides nothing about what
// removal means. `packaging/uninstall.sh` — the same script the Terminal path
// runs, installed at `Uninstall.scriptPath` — is the single implementation of
// removal, and everything here is about (a) asking about settings retention
// while always clearing privacy grants, (b) obtaining
// administrator authority, and (c) handing removal to an independent app.
//
// AUTHORITY — the Mac's administrator password, never the parent PIN. The
// Settings sheet is PIN-gated, but the PIN is a family secret a determined
// teenager can watch being typed; removal of a parental control is an
// administrator action and asks for an administrator's name and password the
// way the panic hold does (`PanicAuth`, SPEC §8.1(1)).

/// The removal path's vocabulary: the choice, the outcome, and the one
/// mechanism that runs the installed script as root.
enum Uninstall {
    /// The installed copy of `packaging/uninstall.sh`. Absolute and fixed:
    /// the payload layout is the installer's contract
    /// (`packaging/pkg-scripts/`), and a removal must never run a script
    /// resolved through PATH or through a caller-supplied path.
    static let scriptPath = "/Library/Application Support/SentryScreen/uninstall.sh"
    static let workerBundleID = "com.sentryscreen.uninstaller"

    /// The two questions `uninstall.sh` already answers non-interactively.
    /// Nothing else is configurable from the UI — a flag the Terminal path
    /// does not have would be a second removal behaviour to keep in step.
    struct Choice: Equatable {
        /// Complete removal is the default. Retention requires an explicit
        /// choice, and never retains a privacy permission grant.
        var keepSettings = false
        /// Settings removal always resets permissions. The field remains for
        /// command-level maintenance tests; the UI cannot turn it off.
        var resetPermissions = true

        /// Environment the script is run with.
        var env: [String: String] { ["SENTRY_KEEP_SETTINGS": keepSettings ? "yes" : "no"] }
        /// Arguments. `uninstall.sh` rejects anything else by name.
        var args: [String] { resetPermissions ? ["--reset-permissions"] : [] }
        /// For the `uninstall` log records.
        var logFields: String {
            "keep=\(keepSettings ? "yes" : "no") reset-permissions=\(resetPermissions ? "on" : "off")"
        }
    }

    /// What the run produced. `cancelled` covers a refused or dismissed
    /// administrator prompt: nothing ran, and the machine is untouched.
    enum Outcome: Equatable {
        case handedOff
        case removed(String)
        case cancelled(String)
        case failed(code: Int32, message: String)

        var logDetail: String {
            switch self {
            case .handedOff: return "worker=started removal=not-yet-verified"
            case let .removed(out): return "code=0 \(Self.oneLine(out))"
            case let .cancelled(why): return "authorization=cancelled \(Self.oneLine(why))"
            case let .failed(code, message): return "code=\(code) \(Self.oneLine(message))"
            }
        }

        /// Log records are one line each (`Logger` writes JSONL).
        private static func oneLine(_ s: String) -> String {
            s.replacingOccurrences(of: "\n", with: " ⏎ ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// `--ui-selftest` hook, the same shape and contract as
    /// `PanicAuth.override`: a real administrator prompt cannot be scripted,
    /// and a selftest must never actually remove anything. nil in production.
    static var override: ((Choice, @escaping (Outcome) -> Void) -> Void)?

    // MARK: The root path

    /// AppleScript literal quoting: backslash and double quote, nothing else
    /// (AppleScript string literals have no other escapes).
    static func appleScriptLiteral(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// `/bin/sh` single-quoting for the one command line the prompt runs.
    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The fixed environment the root script starts with. The Uninstaller
    /// app inherits the session's `launchctl setenv` variables, which a
    /// Standard account can set without admin, and the administrator prompt
    /// hands the caller's environment to the root shell. So the command starts
    /// from `env -i` with this PATH, and bash runs with `-p` so no BASH_ENV or
    /// imported function is read before the script's first line.
    static let rootPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// The command `do shell script` runs, as a shell string.
    ///
    /// `2>&1` on purpose: on a failure the parent is shown the script's OWN
    /// error text (it prints `ERROR: … remediation=…` lines by design), and
    /// on success the `bootout … gone after N s` lines land in the log.
    static func shellCommand(_ c: Choice, scriptPath: String = Uninstall.scriptPath) -> String {
        var parts = ["/usr/bin/env", "-i", "PATH=\(rootPath)"]
        parts += c.env.sorted { $0.key < $1.key }.map { "\($0.key)=\(shellQuoted($0.value))" }
        parts += ["/bin/bash", "-p", shellQuoted(scriptPath)]
        parts.append(contentsOf: c.args.map(shellQuoted))
        return parts.joined(separator: " ") + " 2>&1"
    }

    /// The whole AppleScript. One statement; the administrator prompt it
    /// raises IS the authorization for the removal.
    ///
    /// WHY NOT the `AuthorizationCopyRights` reference `PanicAuth` already
    /// holds: an `AuthorizationRef` authorizes THIS process, and the only
    /// public API that carried it to a root child process was
    /// `AuthorizationExecuteWithPrivileges`, which is not merely deprecated
    /// but *unavailable in Swift* — MEASURED 2026-09-05 on this Mac
    /// (`swiftc`, macOS 26.6 SDK): "'AuthorizationExecuteWithPrivileges' is
    /// unavailable in macOS: APIs deprecated as of macOS 10.9 and earlier are
    /// unavailable in Swift". The remaining root path is a privileged helper
    /// (none ships: every verb a helper grows is reachable by whatever passes
    /// its caller check) or this one. `do shell script … with administrator
    /// privileges` asks for an administrator's name and password from any
    /// account, exactly as `system.privilege.admin` does, so the AUTHORITY is
    /// the same even though the API is not — and it is one prompt, not two.
    static func appleScript(_ c: Choice, scriptPath: String = Uninstall.scriptPath) -> String {
        "do shell script " + appleScriptLiteral(shellCommand(c, scriptPath: scriptPath))
            + " with administrator privileges"
    }

    /// AppleScript's user-cancelled error. Stable OS constant, not tunable.
    static let userCancelledError = -128

    /// Runs the installed removal script as root and reports what it said.
    ///
    /// `NSAppleScript` rather than a spawned `/usr/bin/osascript`: the
    /// authorization prompt names the CALLING application, and a parent
    /// removing a parental control must be told that "SentryScreen wants to
    /// make changes", not that "osascript" does. LaunchServices opens a
    /// separate application so stopping the agent cannot stop this command.
    static func run(_ choice: Choice, completion: @escaping (Outcome) -> Void) {
        if let override {
            override(choice, completion)
            return
        }
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: workerBundleID).first {
            existing.activate(options: [])
            completion(.failed(code: -1, message: "Removal is already running. Complete the SentryScreen Uninstaller window."))
            return
        }
        // Receipt: Build 14 Settings removal on 2026-09-16 stopped this app
        // before deletion and lost the result. LaunchServices gives the
        // uninstaller its own application job, outside the agent's launchd
        // process group. Never spawn the uninstaller as a child Process here.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = [choice.keepSettings ? "--keep-settings" : "--delete-settings",
                                   "--reset-permissions"]
        let worker = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/SentryScreen Uninstaller.app")
        NSWorkspace.shared.openApplication(at: worker, configuration: configuration) { app, error in
            DispatchQueue.main.async {
                if let error { completion(.failed(code: -1, message: "Could not open SentryScreen Uninstaller: \(error.localizedDescription)")) }
                else if let app {
                    completion(.handedOff)
                    observeWorkerExit(app, completion: completion)
                }
                else { completion(.failed(code: -1, message: "SentryScreen Uninstaller did not start.")) }
            }
        }
    }

    /// A successful removal stops this agent before the worker exits. If the
    /// agent can still receive worker termination, removal was not completed.
    /// Unlock retry without accepting a broadcast notification as success.
    private static func observeWorkerExit(_ worker: NSRunningApplication,
                                          completion: @escaping (Outcome) -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        var observation: NSObjectProtocol?
        var delivered = false
        let ended = {
            guard !delivered else { return }
            delivered = true
            if let observation { center.removeObserver(observation) }
            observation = nil
            completion(.failed(code: -1, message: "The uninstaller closed while SentryScreen is still running. Removal is not verified. You can try again."))
        }
        observation = center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                         object: nil, queue: .main) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier == worker.processIdentifier else { return }
            ended()
        }
        if worker.isTerminated { ended() }
    }

    /// Never throws and never returns silently: every failure becomes a named
    /// `Outcome` carrying the script's own text.
    static func execute(_ source: String) -> Outcome {
        guard let script = NSAppleScript(source: source) else {
            return .failed(code: -1, message: "NSAppleScript could not compile the removal command")
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int).map(Int32.init) ?? -1
            let message = (errorInfo[NSAppleScript.errorMessage] as? String)
                ?? "AppleScript error \(code)"
            if code == Int32(userCancelledError) {
                return .cancelled("the administrator prompt was cancelled — nothing was removed")
            }
            return .failed(code: code, message: message)
        }
        return .removed(result.stringValue ?? "")
    }
}

// MARK: - The sequence in front of the script

/// Everything that has to happen, in order, between the parent pressing
/// "Remove SentryScreen" and the script running — separated from `UIActions`
/// so `--ui-selftest` can drive it with no window and no
/// authorization prompt.
///
/// Every transition is a named `uninstall` record so the alerts log tells the
/// whole story after the app is gone. That is the point of the event name: by
/// the time removal has succeeded there is no app left to ask.
final class UninstallGate {
    /// The pause between publishing the closing line and starting the script.
    ///
    /// DERIVED from the 400 ms every UI E2E script waits after a popover
    /// relayout before capturing:
    /// the script boots this agent out, so if the line has not been drawn by
    /// then the parent never sees it at all. A tripwire in the other
    /// direction — too short is a silent disappearance, not a slow one.
    static let closingRenderSecs: TimeInterval = 0.4

    enum Stage: Equatable { case idle, closing, done(Uninstall.Outcome) }

    typealias Schedule = (_ delay: TimeInterval, _ work: @escaping () -> Void) -> Void

    private let log: (String, String) -> Void
    private let runScript: (Uninstall.Choice, @escaping (Uninstall.Outcome) -> Void) -> Void
    private let schedule: Schedule

    private(set) var stage: Stage = .idle
    /// Republished by the owner (`UIActions`) on every transition.
    var onStage: ((Stage) -> Void)?

    var inFlight: Bool {
        switch stage {
        case .done(.handedOff), .closing: return true
        case .idle, .done: return false
        }
    }

    init(
        log: @escaping (String, String) -> Void,
        runScript: @escaping (Uninstall.Choice, @escaping (Uninstall.Outcome) -> Void) -> Void
            = Uninstall.run,
        schedule: @escaping Schedule = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    ) {
        self.log = log
        self.runScript = runScript
        self.schedule = schedule
    }

    /// Main thread. A second press while a removal is in flight is ignored
    /// and logged — the run already going is the one that decides.
    func begin(_ choice: Uninstall.Choice) {
        guard !inFlight else {
            log("uninstall", "stage=start ignored: a removal is already in flight")
            return
        }
        log("uninstall", "stage=start \(choice.logFields) by \(AdminCheck.currentUserLabel())")
        proceed(choice)
    }

    /// The closing line goes up FIRST and gets a render turn, because the
    /// script boots this agent out partway through its own run.
    private func proceed(_ choice: Uninstall.Choice) {
        set(.closing)
        log("uninstall", "stage=closing \(UninstallCopy.closing)")
        schedule(Self.closingRenderSecs) { [weak self] in
            guard let self else { return }
            log("uninstall", "stage=script path=\(Uninstall.scriptPath) \(choice.logFields)")
            runScript(choice) { [weak self] outcome in
                guard let self else { return }
                log("uninstall", "stage=done \(outcome.logDetail)")
                set(.done(outcome))
            }
        }
    }

    private func set(_ s: Stage) {
        stage = s
        onStage?(s)
    }
}

// MARK: - Copy

/// Every parent-facing word on the removal path, in one place, so the E2E
/// scripts and the selftest assert the same strings the sheet draws.
enum UninstallCopy {
    /// The row at the bottom of the Settings sheet. The ellipsis is the macOS
    /// promise that a further step follows — here, a confirmation and an
    /// administrator prompt.
    static let row = "Remove SentryScreen…"
    /// Popover footer and Setup window link: there in every state, so a
    /// parent stuck in a bug can always remove the app (owner 2026-10-16).
    static let anywhereLabel = "Uninstall SentryScreen…"
    static let anywhereTitle = "Uninstall SentryScreen"
    static let pinConfirmation = "Enter the parent PIN to uninstall SentryScreen."

    // MARK: Confirm card (board Uninstall-Popover, 2026-09 redesign)
    //
    // The short card: three lines, one tick box, Cancel and Remove. The
    // strings below are what the card draws; the older `title`/`body`/
    // `keepLabel`/`deleteLabel`/`resetPermissionsLabel` set that follows is
    // still drawn by the current Settings sheet and is deleted when the sheet
    // adopts the card. The tick box is `Choice.keepSettings`, off by default
    // (complete removal, as before). There is no permissions switch: it could
    // never be turned off, and the Uninstaller reports permissions cleared.

    static let cardTitle = "Remove SentryScreen?"
    static let cardLines = [
        "Protection stops for everyone on this Mac.",
        "Needs an admin password.",
    ]
    static let keepTickLabel = "Keep settings and PIN"
    static let keepTickCaption = "For a reinstall on this Mac."
    static let cardCancelLabel = "Cancel"
    static let cardRemoveLabel = "Remove"
    /// Under the Settings row that opens the card.
    static let rowCaption = "Needs an admin password."
    /// Card body once the Uninstaller has opened (`Outcome.handedOff`).
    static let waitingTitle = "Enter the admin password"
    static let waitingBody = "Finish in the Uninstaller window. SentryScreen closes when it\u{2019}s done."
    /// "When it doesn't finish" lines, replacing the card body. `Try again`
    /// and `Details` are the actions; Details opens the exit code and script
    /// text (`failure(code:message:)`), selectable.
    static let cardCancelledLine = "Removal cancelled. Nothing changed."
    static let cardFailedLine = "SentryScreen wasn\u{2019}t removed."
    static let cardAlreadyRunningLine = "Already running. Finish it in the Uninstaller window."
    static let cardClosedEarlyLine = "The Uninstaller closed early. Removal isn\u{2019}t confirmed."
    static let tryAgainLabel = "Try again"
    static let detailsLabel = "Details"

    static let title = "Remove SentryScreen from this Mac?"
    static let body = "Protection stops and SentryScreen is removed from this Mac. "
        + "You will be asked for an administrator name and password."

    /// The removal card's one checkbox (review 2026-09-29, item 10).
    static let deleteTickLabel = "Also delete settings and PIN"
    static let keepLabel = "Keep settings and PIN"
    static let deleteLabel = "Delete settings and PIN"
    static let keepCaption = "Kept settings and PIN are picked up by the next install on this Mac."
    static let deleteCaption = "Deleting them means the next install starts from scratch, "
        + "with a new PIN."

    static let resetPermissionsLabel = "Clear SentryScreen permission records for all users"
    static let resetPermissionsCaption = "Removal clears SentryScreen permissions. A reinstall asks for permission again."

    static let confirmLabel = "Remove SentryScreen"
    static let cancelLabel = "Cancel"

    /// Shown before the script runs, because the script ends this process.
    static let closing = "SentryScreen will close now."

    /// Prefix in front of the script's own error text. The script's
    /// `ERROR: … remediation=…` line is shown verbatim after it — never
    /// replaced with a friendlier sentence that hides the repair step.
    static let failedPrefix = "SentryScreen was not removed."
    static let cancelledNotice = "Removal cancelled. Nothing was changed."

    /// Why a build refused to run the removal at all. Says which build it is
    /// and what to do instead, rather than looking like a failure of the
    /// removal itself.
    static func suppressed(_ why: String) -> String {
        "Removal is not available in this build: " + why + ". "
            + "Remove an installed SentryScreen from its own Settings sheet, or with "
            + "`sudo \'/Library/Application Support/SentryScreen/uninstall.sh\'`."
    }

    static func failure(code: Int32, message: String) -> String {
        let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return failedPrefix + " The removal script exited \(code)."
            + (detail.isEmpty ? "" : "\n" + detail)
    }
}
