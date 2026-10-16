import AppKit
import Foundation

/// The dedicated-window callbacks required by the onboarding driver. The
/// driver receives no API for a display capture or external application.
@MainActor
struct UIOnboardingTestHost {
    let present: () -> Void
    let dismiss: () -> Void
    let signal: (UIOnboardingTestSignal) -> Bool
    let isVisible: () -> Bool
    let windowNumber: () -> Int
    let windowTitle: () -> String?
    let windowCloseButtonEnabled: () -> Bool?
    let attemptWindowClose: () -> Bool
    /// The real close route (performClose → windowShouldClose → close);
    /// returns whether the window is hidden afterwards.
    let closeWindow: () -> Bool
    let contentView: () -> NSView?
    let setAppearance: (String) -> Void
    /// nil on success, else why. The wizard window is built once and reused,
    /// so its scale rides on `UIOnboardingPresentation.textScale` and takes
    /// effect on the next render — no ordering rule, unlike the popover's.
    let setTextSize: (String) -> String?
}

/// Test-only events that stand in for state changes owned by macOS or the
/// capture runtime. The host decides whether a signal is valid for its current
/// fake state; the driver has no permission, TCC, capture, or workspace API.
enum UIOnboardingTestSignal: String, CaseIterable, Equatable, Sendable {
    case screenRecordingRestored = "screen-recording-restored"

    static var acceptedValues: String {
        allCases.map(\.rawValue).joined(separator: "|")
    }
}

enum UIOnboardingTestAction: Equatable, Sendable {
    case show
    case close
    case signal(UIOnboardingTestSignal)
    case appearance(String)
    case textSize(String)
    case wait(Int)
    case waitFor(String, Int)
    case assertText(String, String)
    case assertContains(String, String)
    case assertMissing(String)
    case assertEnabled(String, Bool)
    case assertWindowTitle(String)
    case assertWindowCloseButtonEnabled(Bool)
    case attemptWindowClose
    /// `closewindow`: the close MUST be accepted and hide the window (the
    /// positive twin of `attemptwindowclose`, owner 2026-09-07).
    case closeWindow
    case press(String)
    case type(String, String)
    case screenshot(String)
}

struct UIOnboardingTestLine: Sendable {
    let number: Int
    let display: String
    let action: UIOnboardingTestAction
}

/// Parsed onboarding script. Its grammar is intentionally separate from
/// UIDriver's demo-state grammar, while it reuses the established tokenizer.
struct UIOnboardingTestScript {
    let path: String
    let lines: [UIOnboardingTestLine]

    static var path: String? {
        DevEnv.knob("SENTRY_UI_SCRIPT")
    }

    struct ParseError: Error, CustomStringConvertible {
        let line: Int
        let message: String
        var description: String { "line \(line): \(message)" }
    }

    static func load(_ path: String) -> UIOnboardingTestScript {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            die("onboarding-ui-script: cannot read \(path)", code: UIDriver.Exit.usage.rawValue)
        }
        do {
            return try parse(text, path: path)
        } catch {
            die("onboarding-ui-script: \(error)", code: UIDriver.Exit.usage.rawValue)
        }
    }

    /// The parser behind `load`, throwing instead of dying so the UI
    /// UI-script queue can report a bad script through its result file.
    static func parse(_ text: String, path: String) throws -> UIOnboardingTestScript {
        var lines: [UIOnboardingTestLine] = []
        for (offset, raw) in text.components(separatedBy: "\n").enumerated() {
            let number = offset + 1
            let source = raw.trimmingCharacters(in: .whitespaces)
            if source.isEmpty || source.hasPrefix("#") { continue }
            let fail = { (message: String) -> ParseError in ParseError(line: number, message: message) }
            guard let args = UIDriver.tokenize(source), let verb = args.first else {
                throw fail("unbalanced quotes")
            }
            let rest = Array(args.dropFirst())
            func arity(_ expected: Int) throws {
                guard rest.count == expected else {
                    throw fail("'\(verb)' takes \(expected) argument\(expected == 1 ? "" : "s"), "
                        + "got \(rest.count)")
                }
            }
            func milliseconds(_ raw: String) throws -> Int {
                // Receipt: no single action may outlive the driver's
                // receipted 60 s global Tripwire. A larger delay would make
                // the action's own budget impossible to observe.
                let maximum = Int(UIDriver.defaultTimeoutSecs * 1_000)
                guard let value = Int(raw), (0...maximum).contains(value) else {
                    throw fail("milliseconds budget UIOnboardingTestScript.maximum=\(maximum); "
                        + "requested=\(raw); reduce the script action at \(path):\(number)")
                }
                return value
            }

            let action: UIOnboardingTestAction
            let display: String
            switch verb {
            case "show":
                try arity(0); action = .show; display = source
            case "close":
                try arity(0); action = .close; display = source
            case "signal":
                try arity(1)
                guard let signal = UIOnboardingTestSignal(rawValue: rest[0]) else {
                    throw fail("signal wants \(UIOnboardingTestSignal.acceptedValues), got '\(rest[0])'")
                }
                action = .signal(signal); display = source
            case "appearance":
                try arity(1)
                guard UIAppearanceOption.names.contains(rest[0]) else {
                    throw fail("appearance wants \(UIAppearanceOption.acceptedValues), "
                        + "got '\(rest[0])'")
                }
                action = .appearance(rest[0]); display = source
            case "textsize":
                try arity(1)
                guard UITextScale.named[rest[0]] != nil else {
                    throw fail("textsize wants \(UITextScale.acceptedValues), got '\(rest[0])'")
                }
                action = .textSize(rest[0]); display = source
            case "wait":
                try arity(1); action = .wait(try milliseconds(rest[0])); display = source
            case "waitfor":
                try arity(2)
                action = .waitFor(rest[0], try milliseconds(rest[1])); display = source
            case "assert":
                try arity(2); action = .assertText(rest[0], rest[1]); display = source
            case "assertcontains":
                try arity(2); action = .assertContains(rest[0], rest[1]); display = source
            case "assertmissing":
                try arity(1); action = .assertMissing(rest[0]); display = source
            case "assertenabled":
                try arity(2)
                guard let expected = Bool(rest[1]) else {
                    throw fail("assertenabled wants true|false, got '\(rest[1])'")
                }
                action = .assertEnabled(rest[0], expected); display = source
            case "assertwindowtitle":
                try arity(1); action = .assertWindowTitle(rest[0]); display = source
            case "assertwindowcloseenabled":
                try arity(1)
                guard let expected = Bool(rest[0]) else {
                    throw fail("assertwindowcloseenabled wants true|false, got '\(rest[0])'")
                }
                action = .assertWindowCloseButtonEnabled(expected); display = source
            case "attemptwindowclose":
                try arity(0); action = .attemptWindowClose; display = source
            case "closewindow":
                try arity(0); action = .closeWindow; display = source
            case "press":
                try arity(1); action = .press(rest[0]); display = source
            case "type":
                try arity(2)
                action = .type(rest[0], rest[1])
                // Never print a PIN-bearing script line or value.
                display = "type \(rest[0]) <redacted>"
            case "screenshot":
                try arity(1); action = .screenshot(rest[0]); display = source
            default:
                throw fail("unknown action '\(verb)'")
            }
            lines.append(UIOnboardingTestLine(
                number: number, display: display, action: action))
        }
        return UIOnboardingTestScript(path: path, lines: lines)
    }
}

/// In-process access to the onboarding window's native Accessibility tree.
/// This does not create an AXUIElement for another process and does not need
/// macOS Accessibility permission. There is no CGEvent synthesis.
private enum UIOnboardingOwnWindowAX {
    // Receipt (documented operating assumption): the original onboarding
    // diagnostic bounded view-tree traversal at depth 8. Preserve that cost
    // boundary until a measured failing tree supports a different value.
    private static let diagnosticViewTreeMaximumDepth = 8

    enum Node {
        case view(NSView)
        case cell(NSCell)
        case element(any NSAccessibilityProtocol)
        case control(UIControl)

        var object: AnyObject? {
            switch self {
            case let .view(view): return view
            case let .cell(cell): return cell
            case let .element(element): return element
            case .control: return nil
            }
        }

        var identifier: String? {
            switch self {
            case let .view(view): return view.accessibilityIdentifier()
            case let .cell(cell): return cell.accessibilityIdentifier()
            case let .element(element): return element.accessibilityIdentifier()
            case let .control(control): return control.id
            }
        }

        var children: [Any] {
            switch self {
            case let .view(view):
                // NSHostingView can expose no direct accessibility children
                // while its AppKit platform subview owns the SwiftUI AX tree.
                // Traverse both surfaces; visited-node tracking removes any
                // duplicate view that AppKit also publishes as an AX child.
                return (view.accessibilityChildren() ?? [])
                    + (view.accessibilityChildrenInNavigationOrder() ?? [])
                    + view.subviews
            case let .cell(cell):
                return (cell.accessibilityChildren() ?? [])
                    + (cell.accessibilityChildrenInNavigationOrder() ?? [])
            case let .element(element):
                return (element.accessibilityChildren() ?? [])
                    + (element.accessibilityChildrenInNavigationOrder() ?? [])
            case .control: return []
            }
        }

        var text: String {
            func strings(label: String?, title: String?, value: Any?) -> [String] {
                [label, title, value as? String]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
            }
            let parts: [String]
            switch self {
            case let .view(view):
                parts = strings(
                    label: view.accessibilityLabel(),
                    title: view.accessibilityTitle(),
                    value: view.accessibilityValue())
            case let .cell(cell):
                parts = strings(
                    label: cell.accessibilityLabel(),
                    title: cell.accessibilityTitle(),
                    value: cell.accessibilityValue())
            case let .element(element):
                parts = strings(
                    label: element.accessibilityLabel(),
                    title: element.accessibilityTitle(),
                    value: element.accessibilityValue())
            case let .control(control):
                parts = [control.read()]
            }
            return Array(NSOrderedSet(array: parts))
                .compactMap { $0 as? String }
                .joined(separator: " ")
        }

        var enabled: Bool {
            switch self {
            case let .view(view): return view.isAccessibilityEnabled()
            case let .cell(cell): return cell.isAccessibilityEnabled()
            case let .element(element): return element.isAccessibilityEnabled()
            case let .control(control): return control.enabled()
            }
        }

        func press() -> Bool {
            switch self {
            case let .view(view): return view.accessibilityPerformPress()
            case let .cell(cell): return cell.accessibilityPerformPress()
            case let .element(element): return element.accessibilityPerformPress()
            case let .control(control):
                guard let activate = control.activate else { return false }
                activate()
                return true
            }
        }

        func setValue(_ value: String) {
            switch self {
            case let .view(view): view.setAccessibilityValue(value)
            case let .cell(cell): cell.setAccessibilityValue(value)
            case let .element(element): element.setAccessibilityValue(value)
            case let .control(control): control.setText?(value)
            }
        }
    }

    static func find(_ identifier: String, under root: NSView) -> Node? {
        if let control = UIRegistry.shared.control(identifier) {
            return .control(control)
        }
        var queue: [Node] = [.view(root)]
        var index = 0
        var visited: Set<ObjectIdentifier> = []
        while index < queue.count {
            let node = queue[index]
            index += 1
            guard let object = node.object else { continue }
            let identity = ObjectIdentifier(object)
            guard visited.insert(identity).inserted else { continue }
            if node.identifier == identifier { return node }
            for child in node.children {
                if let view = child as? NSView {
                    queue.append(.view(view))
                } else if let cell = child as? NSCell {
                    queue.append(.cell(cell))
                } else if let element = child as? any NSAccessibilityProtocol {
                    queue.append(.element(element))
                }
            }
        }
        return nil
    }

    static func diagnosticViewTree(under root: NSView) -> String {
        var lines: [String] = []
        var depthTripwireReported = false
        func visit(_ view: NSView, depth: Int) {
            guard depth <= diagnosticViewTreeMaximumDepth else {
                if !depthTripwireReported {
                    lines.append(
                        "TRIPWIRE FAILED: "
                            + "limit=UIOnboardingOwnWindowAX."
                            + "diagnosticViewTreeMaximumDepth "
                            + "configured=\(diagnosticViewTreeMaximumDepth) "
                            + "observed=\(depth); remediation="
                            + "daemon/Sources/SentryScreen/"
                            + "UIOnboardingTestDriver.swift:"
                            + "UIOnboardingOwnWindowAX."
                            + "diagnosticViewTreeMaximumDepth")
                    depthTripwireReported = true
                }
                return
            }
            let children = view.accessibilityChildren() ?? []
            let navigation = view.accessibilityChildrenInNavigationOrder() ?? []
            let childTypes = children.map { String(reflecting: type(of: $0)) }
            let navigationTypes = navigation.map { String(reflecting: type(of: $0)) }
            lines.append(String(repeating: "  ", count: depth)
                + "\(String(reflecting: type(of: view))) "
                + "id=\(view.accessibilityIdentifier()) "
                + "ax=\(childTypes) nav=\(navigationTypes) "
                + "subviews=\(view.subviews.count)")
            for subview in view.subviews { visit(subview, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return lines.joined(separator: " | ")
    }
}

/// Renders only the app-owned onboarding content view. This avoids a display
/// capture permission and cannot fall back to another window or the desktop.
private enum UIOnboardingWindowCapture {
    struct Receipt: Sendable {
        let elapsedMilliseconds: UInt64
        let pixelWidth: Int
        let pixelHeight: Int
    }
    struct Failure: Error, Sendable, CustomStringConvertible {
        let description: String
    }

    @MainActor
    static func capture(view: NSView, output: String) -> Result<Receipt, Failure> {
        let started = DispatchTime.now()
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1 else {
            return .failure(Failure(
                description: "onboarding content bounds are \(bounds.width)x\(bounds.height)"))
        }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            return .failure(Failure(
                description: "AppKit refused an onboarding bitmap for "
                    + "\(bounds.width)x\(bounds.height) bounds"))
        }
        view.cacheDisplay(in: bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            return .failure(Failure(description: "AppKit could not encode onboarding PNG"))
        }
        do {
            try png.write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
        } catch {
            return .failure(Failure(description: "could not write onboarding PNG: \(error)"))
        }
        let elapsed = (DispatchTime.now().uptimeNanoseconds
            - started.uptimeNanoseconds) / 1_000_000
        return .success(Receipt(
            elapsedMilliseconds: elapsed,
            pixelWidth: bitmap.pixelsWide,
            pixelHeight: bitmap.pixelsHigh))
    }
}

@MainActor
final class UIOnboardingTestDriver {
    private let script: UIOnboardingTestScript
    private let host: UIOnboardingTestHost
    private let shotsDirectory: String
    private var screenshots = 0
    /// Every PNG written, in order (the queue's result file lists them).
    private(set) var shotPaths: [String] = []
    private var lastLine: UIOnboardingTestLine?
    /// Set by the UI-script queue: report here instead of exiting.
    /// nil (the demo default) keeps the process-exit contract the
    /// onboarding E2E suite asserts on.
    var onFinish: ((_ code: Int32, _ message: String, _ shots: [String]) -> Void)?
    private var finished = false

    /// `shotsDirectory` nil ⇒ SENTRY_UI_SHOTS, else the script's directory
    /// (the demo contract). The queue passes its own shots/ directory.
    init(script: UIOnboardingTestScript, host: UIOnboardingTestHost, shotsDirectory: String? = nil) {
        self.script = script
        self.host = host
        self.shotsDirectory = shotsDirectory
            ?? DevEnv.knob("SENTRY_UI_SHOTS")
            ?? (script.path as NSString).deletingLastPathComponent
    }

    func run() {
        // Receipt: this driver uses the same main-thread continuation chain
        // as UIDriver and has fewer actions and no PBKDF2 work. Reuse its
        // receipted 60 s global hang Tripwire and its environment override.
        // Queue mode does not read env (spec §3.3): the receipted default is
        // the tripwire whatever the launchd environment carries.
        let timeout = onFinish == nil
            ? (DevEnv.knob("SENTRY_UI_SCRIPT_TIMEOUT")
                .flatMap(Double.init) ?? UIDriver.defaultTimeoutSecs)
            : UIDriver.defaultTimeoutSecs
        guard timeout.isFinite, timeout > 0, timeout <= UIDriver.defaultTimeoutSecs else {
            die(
                "onboarding-ui-script: timeout budget UIDriver.defaultTimeoutSecs="
                    + "\(Int(UIDriver.defaultTimeoutSecs))s; requested=\(timeout)s; "
                    + "set SENTRY_UI_SCRIPT_TIMEOUT within (0,60]",
                code: UIDriver.Exit.usage.rawValue)
        }
        print("onboarding-ui-script: \(script.path) "
            + "(\(script.lines.count) actions, timeout \(Int(timeout))s)")
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            let last = self.lastLine.map { "line \($0.number): \($0.display)" } ?? "(none)"
            self.fail(
                .globalTimeout,
                "global timeout \(Int(timeout))s (budget SENTRY_UI_SCRIPT_TIMEOUT) "
                    + "— last action run: \(last)")
        }
        DispatchQueue.main.async { [weak self] in self?.step(0) }
    }

    private func step(_ index: Int) {
        guard !finished else { return }
        guard index < script.lines.count else {
            let summary = "ONBOARDING-UI-SCRIPT OK "
                + "(\(script.lines.count) actions, \(screenshots) screenshots)"
            print(summary)
            finish(0, summary)
            return
        }
        let line = script.lines[index]
        lastLine = line
        let next = { DispatchQueue.main.async { [weak self] in self?.step(index + 1) } }
        let pass = { print("onboarding-ui-script: [\(line.number)] \(line.display) OK") }

        switch line.action {
        case .show:
            host.present()
            guard host.isVisible(), host.windowNumber() > 0 else {
                fail(.assertFailed, line, "dedicated onboarding window did not become visible")
                return
            }
            pass(); next()
        case .close:
            host.dismiss()
            guard !host.isVisible() else {
                fail(.assertFailed, line, "dedicated onboarding window remained visible")
                return
            }
            pass(); next()
        case let .signal(signal):
            guard host.signal(signal) else {
                fail(
                    .assertFailed,
                    line,
                    "test host refused signal '\(signal.rawValue)' in its current fake state")
                return
            }
            pass(); next()
        case let .appearance(name):
            host.setAppearance(name); pass(); next()
        case let .textSize(name):
            if let reason = host.setTextSize(name) {
                fail(.assertFailed, line, reason)
                return
            }
            pass(); next()
        case let .wait(milliseconds):
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                pass(); next()
            }
        case let .waitFor(identifier, milliseconds):
            let deadline = DispatchTime.now() + .milliseconds(milliseconds)
            let start = DispatchTime.now()
            pollForNode(
                identifier,
                milliseconds: milliseconds,
                deadline: deadline,
                started: start,
                line: line,
                nextIndex: index + 1)
        case let .assertText(identifier, expected):
            guard let found = need(identifier, line) else { return }
            let actual = found.text
            guard actual == expected else {
                fail(.assertFailed, line, expected: expected, actual: actual)
                return
            }
            pass(); next()
        case let .assertContains(identifier, expected):
            guard let found = need(identifier, line) else { return }
            let actual = found.text
            guard actual.contains(expected) else {
                fail(.assertFailed, line, expected: "…\(expected)…", actual: actual)
                return
            }
            pass(); next()
        case let .assertMissing(identifier):
            guard node(identifier) == nil else {
                fail(
                    .assertFailed,
                    line,
                    expected: "\(identifier) absent",
                    actual: "present")
                return
            }
            pass(); next()
        case let .assertEnabled(identifier, expected):
            guard let found = need(identifier, line) else { return }
            let actual = found.enabled
            guard actual == expected else {
                fail(
                    .assertFailed,
                    line,
                    expected: "enabled=\(expected)",
                    actual: "enabled=\(actual)")
                return
            }
            pass(); next()
        case let .assertWindowTitle(expected):
            let actual = host.windowTitle() ?? "<no visible window>"
            guard actual == expected else {
                fail(.assertFailed, line, expected: expected, actual: actual)
                return
            }
            pass(); next()
        case let .assertWindowCloseButtonEnabled(expected):
            guard let actual = host.windowCloseButtonEnabled() else {
                fail(.assertFailed, line, "visible window has no title-bar close control")
                return
            }
            guard actual == expected else {
                fail(
                    .assertFailed,
                    line,
                    expected: "enabled=\(expected)",
                    actual: "enabled=\(actual)")
                return
            }
            pass(); next()
        case .attemptWindowClose:
            let accepted = host.attemptWindowClose()
            guard !accepted else {
                fail(.assertFailed, line, "title-bar close request was accepted")
                return
            }
            guard host.isVisible() else {
                fail(.assertFailed, line, "title-bar close request dismissed the window")
                return
            }
            pass(); next()
        case .closeWindow:
            guard host.closeWindow() else {
                fail(.assertFailed, line, "close request was refused or left the window visible")
                return
            }
            pass(); next()
        case let .press(identifier):
            guard let target = need(identifier, line) else { return }
            guard target.enabled else {
                fail(.assertFailed, line, "\(identifier) is disabled")
                return
            }
            guard target.press() else {
                fail(.assertFailed, line, "\(identifier) refused its test action")
                return
            }
            pass(); next()
        case let .type(identifier, text):
            guard let target = need(identifier, line) else { return }
            guard target.enabled else {
                fail(.assertFailed, line, "\(identifier) is disabled")
                return
            }
            target.setValue(text)
            pass(); next()
        case let .screenshot(relativePath):
            startScreenshot(relativePath, line: line, nextIndex: index + 1)
        }
    }

    private func pollForNode(
        _ identifier: String,
        milliseconds: Int,
        deadline: DispatchTime,
        started: DispatchTime,
        line: UIOnboardingTestLine,
        nextIndex: Int
    ) {
        guard !finished else { return }
        if node(identifier) != nil {
            let elapsed = (DispatchTime.now().uptimeNanoseconds
                - started.uptimeNanoseconds) / 1_000_000
            print("onboarding-ui-script: [\(line.number)] \(line.display) OK "
                + "(found after \(elapsed) ms)")
            DispatchQueue.main.async { [weak self] in self?.step(nextIndex) }
            return
        }
        if DispatchTime.now() >= deadline {
            if let root = host.contentView() {
                let accessibilityTypes = (root.accessibilityChildren() ?? [])
                    .map { String(reflecting: type(of: $0)) }
                    .joined(separator: ", ")
                let subviewTypes = root.subviews
                    .map { String(reflecting: type(of: $0)) }
                    .joined(separator: ", ")
                print("onboarding-ui-script: AX diagnostic root="
                    + "\(String(reflecting: type(of: root))) children=[\(accessibilityTypes)] "
                    + "subviews=[\(subviewTypes)]")
                print("onboarding-ui-script: AX view tree "
                    + UIOnboardingOwnWindowAX.diagnosticViewTree(under: root))
            }
            fail(
                .waitforTimeout,
                line,
                "\(identifier) not found within \(milliseconds) ms")
            return
        }
        // Same receipted run-loop poll cadence as UIDriver.
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(UIDriver.waitforPollMs)
        ) { [weak self] in
            self?.pollForNode(
                identifier,
                milliseconds: milliseconds,
                deadline: deadline,
                started: started,
                line: line,
                nextIndex: nextIndex)
        }
    }

    private func node(_ identifier: String) -> UIOnboardingOwnWindowAX.Node? {
        guard host.isVisible(), let root = host.contentView() else { return nil }
        return UIOnboardingOwnWindowAX.find(identifier, under: root)
    }

    /// nil after reporting the failure (the caller returns).
    private func need(_ identifier: String, _ line: UIOnboardingTestLine)
        -> UIOnboardingOwnWindowAX.Node?
    {
        guard let target = node(identifier) else {
            fail(.assertFailed, line, "\(identifier) is not in the onboarding window")
            return nil
        }
        return target
    }

    /// Captures only the dedicated onboarding content view. There is no
    /// display capture fallback in this driver. Output is one new flat file
    /// under the configured shots root; absolute paths, traversal, and
    /// overwrite are refused before AppKit renders the view.
    private func startScreenshot(
        _ relativePath: String,
        line: UIOnboardingTestLine,
        nextIndex: Int
    ) {
        let fileName = (relativePath as NSString).lastPathComponent
        guard !relativePath.hasPrefix("/"), fileName == relativePath,
            fileName != ".", fileName != "..", !fileName.isEmpty
        else {
            fail(
                .screenshotFailed,
                line,
                "screenshot path must be one relative filename under SENTRY_UI_SHOTS")
            return
        }
        let rootURL = URL(fileURLWithPath: shotsDirectory)
            .standardizedFileURL.resolvingSymlinksInPath()
        let outputURL = rootURL.appendingPathComponent(fileName).standardizedFileURL
        let output = outputURL.path
        guard outputURL.deletingLastPathComponent().path == rootURL.path else {
            fail(.screenshotFailed, line, "screenshot path escaped SENTRY_UI_SHOTS")
            return
        }
        guard !FileManager.default.fileExists(atPath: output) else {
            fail(
                .screenshotFailed,
                line,
                "screenshot target already exists: \(output); use a fresh artifact tag")
            return
        }
        let window = host.windowNumber()
        guard host.isVisible(), window > 0, let contentView = host.contentView() else {
            fail(
                .screenshotFailed,
                line,
                "no dedicated onboarding window to capture; full-display capture is unsupported")
            return
        }
        try? FileManager.default.createDirectory(
            atPath: rootURL.path,
            withIntermediateDirectories: true)
        // The registry can materialize during SwiftUI's update pass before
        // NSHostingView receives its final window bounds. Capture on the next
        // main-loop turn so AppKit has committed that layout.
        DispatchQueue.main.async { [weak self, weak contentView] in
            guard let self, let contentView else { return }
            switch UIOnboardingWindowCapture.capture(view: contentView, output: output) {
            case let .failure(reason):
                self.fail(.screenshotFailed, line, reason.description)
            case let .success(receipt):
                if let reason = UIDriver.verify(png: output) {
                    self.fail(
                        .screenshotFailed,
                        line,
                        "\(reason) (AppKit render elapsed=\(receipt.elapsedMilliseconds)ms, "
                            + "pixels=\(receipt.pixelWidth)x\(receipt.pixelHeight), "
                            + "onboarding window=\(window))")
                    return
                }
                self.screenshots += 1
                self.shotPaths.append(output)
                print("onboarding-ui-script: [\(line.number)] \(line.display) OK "
                    + "(\(receipt.elapsedMilliseconds) ms, "
                    + "\(receipt.pixelWidth)x\(receipt.pixelHeight))")
                DispatchQueue.main.async { [weak self] in self?.step(nextIndex) }
            }
        }
    }

    /// The one exit: process exit under the demo (the onboarding E2E
    /// contract), the queue's callback otherwise. Idempotent.
    private func finish(_ code: Int32, _ message: String) {
        guard !finished else { return }
        finished = true
        if let onFinish {
            onFinish(code, message, shotPaths)
        } else {
            Foundation.exit(code)
        }
    }

    private func fail(
        _ exit: UIDriver.Exit,
        _ line: UIOnboardingTestLine,
        _ reason: String
    ) {
        let message = "ONBOARDING-UI-SCRIPT FAILED at line \(line.number): \(line.display)\n  reason:   \(reason)"
        FileHandle.standardError.write(Data((message + "\n  script:   \(script.path)\n\n").utf8))
        finish(exit.rawValue, message)
    }

    private func fail(
        _ exit: UIDriver.Exit,
        _ line: UIOnboardingTestLine,
        expected: String,
        actual: String
    ) {
        let message = "ONBOARDING-UI-SCRIPT FAILED at line \(line.number): \(line.display)\n"
            + "  expected: \"\(expected)\"\n  actual:   \"\(actual)\""
        FileHandle.standardError.write(Data((message + "\n  script:   \(script.path)\n\n").utf8))
        finish(exit.rawValue, message)
    }

    private func fail(_ exit: UIDriver.Exit, _ reason: String) {
        let message = "ONBOARDING-UI-SCRIPT FAILED: \(reason)"
        FileHandle.standardError.write(Data((message + "\n  script:   \(script.path)\n").utf8))
        finish(exit.rawValue, message)
    }
}
