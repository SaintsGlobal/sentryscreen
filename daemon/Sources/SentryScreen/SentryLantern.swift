import AppKit
import SwiftUI

// Lantern, the SentryScreen mascot, drawn in code so no bundle resource is
// needed.
// Owner approval: "change to the icon with transparent bg" and the
// character sheet's Lantern without the shield (plan §2 Global).
//
// Receipt: the part tables at the bottom are copied verbatim, by
// scratchpad script, from the website's generated drawings (server main
// 6fc46ce):
//   face   = site/favicon.svg
//            sha256 88a74d6187fcae410d54d897427bf8c51bdef1a493f1d5a9fc5d46eb06fe673d
//   figure = src/assets/lantern-neutral.svg (neutral pose, no shield,
//            sticker-edge filter dropped because the background is transparent)
//            sha256 4f4c34196cb7d5f8e7d040ee66d237a7ff396e71176ed1a195efde0c31cabe1e
// Colours are the drawing paints of design/palette.mjs (DAY, NIGHT), kept
// apart from the interface tokens (DESIGN.md "Drawings never use interface
// tokens"). At night only the outline changes, to warm sand `#cdb994`
// (owner approved 2026-09-29, plan §6 item 6; was the favicon's `#f3e6cc`),
// so the ink arms and legs stay visible on the night paper. The site's own
// night figure uses `#140d09` on a lit wall; that choice for the app is an
// open decision.
// The tan app-icon tile is not drawn here: it has no sourced colour and no
// approved consumer yet (plan §2: "tan tile kept only where it stands for
// the macOS app icon").

/// Lantern's face on a transparent background (the site favicon).
struct SentryLanternFace: View {
    var size: CGFloat = 32

    var body: some View {
        SentryLanternCanvas(parts: SentryLanternArt.face, viewBox: SentryLanternArt.faceViewBox)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The full Lantern figure, neutral pose, without the shield. Height is the
/// caller's; width follows the drawing's aspect ratio. `waving` raises the
/// free (right) arm: the same arm and hand parts, rotated about the shoulder
/// (`SentryLanternArt.wave`), so no new drawing is invented.
struct SentryLanternFigure: View {
    var height: CGFloat = 131
    var waving = false

    var body: some View {
        let box = SentryLanternArt.figureViewBox
        SentryLanternCanvas(parts: SentryLanternArt.figure, viewBox: box, waving: waving)
            .frame(width: height * box.width / box.height, height: height)
            .accessibilityHidden(true)
    }
}

private struct SentryLanternCanvas: View {
    let parts: [SentryLanternArt.Part]
    let viewBox: CGRect
    var waving = false

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / viewBox.width, size.height / viewBox.height)
            context.translateBy(
                x: (size.width - viewBox.width * scale) / 2 - viewBox.minX * scale,
                y: (size.height - viewBox.height * scale) / 2 - viewBox.minY * scale)
            context.scaleBy(x: scale, y: scale)
            for part in parts {
                if waving, SentryLanternArt.isRightArm(part) {
                    var arm = context
                    let pivot = SentryLanternArt.wave.shoulder
                    arm.translateBy(x: pivot.x, y: pivot.y)
                    arm.rotate(by: .degrees(SentryLanternArt.wave.degrees))
                    arm.translateBy(x: -pivot.x, y: -pivot.y)
                    SentryLanternArt.draw(part, in: &arm)
                } else if let clip = part.clip {
                    context.drawLayer { layer in
                        layer.clip(to: SentryLanternArt.path(clip))
                        SentryLanternArt.draw(part, in: &layer)
                    }
                } else {
                    SentryLanternArt.draw(part, in: &context)
                }
            }
        }
    }
}

enum SentryLanternArt {
    static let faceViewBox = CGRect(x: 0, y: 0, width: 32, height: 32)

    /// The wave for "You're all set" (review 2026-09-29, item 4). DERIVED from
    /// the neutral figure: the right arm runs from the shoulder (57.5, -100)
    /// to the hand (84.3, -37.9), 67 degrees below horizontal; turning it
    /// -117 degrees about the shoulder lifts the hand to about 50 degrees
    /// above horizontal at (101, -148), inside the figure's viewBox (x to
    /// 150, y from -236). The site has no waving drawing to copy.
    static let wave = (shoulder: CGPoint(x: 57.5, y: -100), degrees: -117.0)
    /// The right arm's two strokes and its hand's two paths, by their first
    /// point (the figure table below; `validate()` checks all four exist).
    static let rightArmStarts = ["M57.2 -100", "M57.5 -100", "M94.9 -42", "M94.5 -40.7"]

    static func isRightArm(_ part: Part) -> Bool {
        guard case let .path(d) = part.shape else { return false }
        return rightArmStarts.contains { d.hasPrefix($0 + "Q") }
    }
    static let figureViewBox = CGRect(x: -110, y: -236, width: 260, height: 242)

    /// Drawing paints, design/palette.mjs DAY then NIGHT (server 6fc46ce).
    enum Paint {
        case outline, navy, navyLight, navyDeep, glow, ink

        var color: Color {
            switch self {
            case .outline: return Self.outlineColor
            case .navy: return Self.navyColor
            case .navyLight: return Self.navyLightColor
            case .navyDeep: return Self.navyDeepColor
            case .glow: return Self.glowColor
            case .ink: return Self.inkColor
            }
        }

        private static let outlineColor = paint("outline", 0x2b1d16, 0xcdb994)
        private static let navyColor = paint("navy", 0x262a3b, 0x232639)
        private static let navyLightColor = paint("navyLight", 0x353b54, 0x30354b)
        private static let navyDeepColor = paint("navyDeep", 0x1b1e2b, 0x1b1e2b)
        private static let glowColor = paint("glow", 0xfff7dc, 0xfff7dc)
        private static let inkColor = paint("ink", 0x2b1d16, 0x2b1d16)
        static let halo = paint("halo", 0xffe7a8, 0xffd98a)
        /// `.halo{opacity:.35}` and the gradient stops of `#em-neutral-halo`.
        static let haloOpacity = 0.35
        static let haloStops: [(location: CGFloat, opacity: Double)] = [(0, 0.9), (0.45, 0.35), (1, 0)]

        private static func paint(_ name: String, _ day: UInt32, _ night: UInt32) -> Color {
            Color(nsColor: SentryColor.NS.room("Lantern." + name, day, night))
        }
    }

    struct Part {
        enum Shape {
            case path(String)
            case rect(CGRect, radius: CGFloat)
            case halo(CGRect)
        }

        let shape: Shape
        var fill: Paint?
        var stroke: Paint?
        var width: CGFloat = 0
        var clip: String?

        init(path: String, fill: Paint?, stroke: Paint?, width: CGFloat, clip: String? = nil) {
            shape = .path(path)
            self.fill = fill
            self.stroke = stroke
            self.width = width
            self.clip = clip
        }

        init(rect: CGRect, radius: CGFloat, fill: Paint?, clip: String? = nil) {
            shape = .rect(rect, radius: radius)
            self.fill = fill
            self.clip = clip
        }

        init(halo: CGRect, clip: String? = nil) {
            shape = .halo(halo)
            self.clip = clip
        }
    }

    static func draw(_ part: Part, in context: inout GraphicsContext) {
        switch part.shape {
        case let .halo(rect):
            let stops = Paint.haloStops.map {
                Gradient.Stop(color: Paint.halo.opacity($0.opacity), location: $0.location)
            }
            var layer = context
            layer.opacity = Paint.haloOpacity
            layer.fill(Path(ellipseIn: rect), with: .radialGradient(
                Gradient(stops: stops),
                center: CGPoint(x: rect.midX, y: rect.midY), startRadius: 0,
                endRadius: max(rect.width, rect.height) / 2))
        case let .rect(rect, radius):
            if let fill = part.fill {
                context.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(fill.color))
            }
        case let .path(d):
            let path = path(d)
            if let fill = part.fill { context.fill(path, with: .color(fill.color)) }
            if let stroke = part.stroke {
                context.stroke(path, with: .color(stroke.color),
                    style: StrokeStyle(lineWidth: part.width, lineCap: .round, lineJoin: .round))
            }
        }
    }

    enum PathError: Error, CustomStringConvertible {
        case unsupportedCommand(Character, offset: Int)
        case badNumber(offset: Int)

        var description: String {
            switch self {
            case let .unsupportedCommand(c, offset):
                return "lantern path: unsupported SVG command '\(c)' at \(offset); SentryLanternArt.parse reads absolute M, L, Q, Z only"
            case let .badNumber(offset):
                return "lantern path: missing or bad number at \(offset)"
            }
        }
    }

    /// Absolute M, L, Q and Z: every command the source drawings use. Any
    /// other command throws, and `validate()` names it.
    static func parse(_ d: String) throws -> Path {
        let chars = Array(d)
        var i = 0
        func skip() { while i < chars.count, chars[i] == " " || chars[i] == "," { i += 1 } }
        func number() throws -> CGFloat {
            skip()
            let start = i
            while i < chars.count, chars[i].isNumber || chars[i] == "." || (chars[i] == "-" && i == start) {
                i += 1
            }
            guard let value = Double(String(chars[start..<i])) else { throw PathError.badNumber(offset: start) }
            return CGFloat(value)
        }
        func point() throws -> CGPoint { CGPoint(x: try number(), y: try number()) }
        var path = Path()
        var command: Character = " "
        while true {
            skip()
            guard i < chars.count else { break }
            if chars[i].isLetter { command = chars[i]; i += 1 }
            switch command {
            case "M": path.move(to: try point()); command = "L"
            case "L": path.addLine(to: try point())
            case "Q": let c = try point(); path.addQuadCurve(to: try point(), control: c)
            case "Z": path.closeSubpath(); command = " "
            default: throw PathError.unsupportedCommand(command, offset: i)
            }
        }
        return path
    }

    /// Parsed once per string. An unparseable string draws nothing and is
    /// reported by `validate()`, which the self-test calls.
    static func path(_ d: String) -> Path {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = cache[d] { return hit }
        let parsed = (try? parse(d)) ?? Path()
        cache[d] = parsed
        return parsed
    }

    private static var cache: [String: Path] = [:]
    private static let cacheLock = NSLock()

    /// Self-test hook: one line per path string that does not parse.
    static func validate() -> [String] {
        let arm = figure.filter(isRightArm).count == rightArmStarts.count ? [] :
            ["lantern wave: expected \(rightArmStarts.count) right-arm parts, found \(figure.filter(isRightArm).count)"]
        return arm + (face + figure).flatMap { part -> [String] in
            var strings = part.clip.map { [$0] } ?? []
            if case let .path(d) = part.shape { strings.append(d) }
            return strings.compactMap { d in
                do { _ = try parse(d); return nil } catch { return "\(error)" }
            }
        }
    }

    // MARK: Part tables (generated; see the Receipt at the top of this file)

    static let figure: [SentryLanternArt.Part] = [
        .init(path: "M-90.6 -48.7Q-89.3 -52.6 -88.3 -53.9Q-87.3 -55.2 -85.5 -56.3Q-83.8 -57.3 -81.7 -57.7Q-79.7 -58.2 -77.9 -57.9Q-76 -57.5 -74.5 -56.6Q-72.9 -55.7 -71.8 -54.1Q-70.7 -52.5 -70 -50.5L-69.2 -48.5", fill: nil, stroke: .outline, width: 3.5),
        .init(path: "M-90.6 -48.5Q-89.3 -52.2 -88.4 -53.7Q-87.4 -55.2 -85.5 -56.2Q-83.6 -57.2 -81.8 -57.7Q-80 -58.3 -78.2 -57.7Q-76.4 -57 -74.8 -56.3Q-73.2 -55.5 -71.8 -53.8Q-70.4 -52.2 -69.7 -50.6L-69.1 -48.9", fill: nil, stroke: .outline, width: 1.6),
        .init(halo: CGRect(x: -114.0, y: -51.0, width: 68.0, height: 68.0)),
        .init(path: "M-88.8 -38.9Q-91.7 -38.6 -90.7 -40.9Q-89.6 -43.3 -88.2 -45.2Q-86.8 -47.2 -84.5 -46.9Q-82.1 -46.7 -79.9 -47Q-77.6 -47.3 -75.4 -47Q-73.2 -46.8 -71.9 -44.8Q-70.7 -42.9 -69.3 -41Q-67.9 -39.2 -71.1 -38.9Q-74.2 -38.6 -77.3 -38.7Q-80.3 -38.8 -83 -39Q-85.8 -39.3 -88.8 -38.9Z", fill: .ink, stroke: .outline, width: 3),
        .init(path: "M-89 -39Q-91.8 -39 -90.5 -41.1Q-89.3 -43.2 -88.2 -45.2Q-87.1 -47.2 -83.4 -47Q-79.8 -46.9 -76.4 -46.8Q-73 -46.7 -71.7 -44.8Q-70.3 -42.9 -69 -41Q-67.7 -39.1 -70.8 -38.9Q-73.9 -38.7 -77 -38.9Q-80.1 -39.2 -83.2 -39.1Q-86.2 -39 -89 -39Z", fill: nil, stroke: .outline, width: 1.4),
        .init(path: "M-76.7 -39.2Q-73.5 -39.1 -72.9 -39.1Q-72.3 -39.1 -71.6 -38.6Q-70.9 -38.2 -70.3 -37.7Q-69.7 -37.1 -69.5 -36.4Q-69.4 -35.6 -69.3 -34.7Q-69.2 -33.8 -69.4 -30.8Q-69.5 -27.8 -69.1 -24.1Q-68.7 -20.3 -69.1 -17.3Q-69.4 -14.2 -69.5 -13.5Q-69.5 -12.7 -69.8 -11.9Q-70.1 -11.1 -70.4 -10.5Q-70.8 -9.8 -71.4 -9.7Q-72.1 -9.6 -72.8 -9.2Q-73.6 -8.7 -76.6 -8.8Q-79.5 -8.9 -83 -9.2Q-86.4 -9.4 -86.9 -9.4Q-87.3 -9.3 -88 -9.6Q-88.7 -9.8 -89.6 -10.4Q-90.5 -11 -90.6 -11.7Q-90.6 -12.5 -90.8 -13.4Q-91 -14.4 -90.8 -17.6Q-90.5 -20.9 -90.7 -24.2Q-90.8 -27.5 -90.8 -30.9Q-90.9 -34.4 -90.8 -35.2Q-90.7 -36 -90.5 -36.6Q-90.3 -37.3 -89.8 -37.8Q-89.3 -38.3 -88.5 -38.4Q-87.6 -38.5 -87 -38.8Q-86.4 -39 -83.2 -39.1Q-80 -39.3 -76.7 -39.2Z", fill: .glow, stroke: .outline, width: 3.5),
        .init(path: "M-76.9 -38.8Q-73.7 -38.7 -73.1 -38.6Q-72.6 -38.4 -71.7 -38.1Q-70.9 -37.7 -70.5 -37.2Q-70 -36.6 -69.8 -36.2Q-69.5 -35.9 -69.3 -34.7Q-69.1 -33.6 -68.9 -28.8Q-68.7 -24 -68.7 -18.9Q-68.7 -13.9 -69 -13.3Q-69.3 -12.8 -69.8 -12.1Q-70.3 -11.3 -70.8 -10.5Q-71.4 -9.7 -72 -9.7Q-72.6 -9.6 -73.2 -9.4Q-73.8 -9.2 -77 -9.2Q-80.2 -9.1 -83 -9Q-85.9 -8.9 -86.6 -8.9Q-87.4 -9 -88 -9.3Q-88.6 -9.6 -89.4 -10.2Q-90.1 -10.9 -90.3 -11.8Q-90.5 -12.8 -90.8 -13.2Q-91.2 -13.6 -91.1 -18.7Q-91.1 -23.7 -91.2 -28.7Q-91.3 -33.6 -91.2 -34.7Q-91.1 -35.8 -90.5 -36.5Q-89.9 -37.3 -89.5 -37.5Q-89.2 -37.8 -88.2 -38.3Q-87.2 -38.7 -86.7 -39Q-86.1 -39.2 -83.1 -39.1Q-80.1 -39 -76.9 -38.8Z", fill: nil, stroke: .outline, width: 1.6),
        .init(path: "M-92.2 -24.2Q-80.4 -23.8 -75.1 -23.4L-69.7 -22.9", fill: nil, stroke: .outline, width: 2),
        .init(path: "M-91.3 -24.4Q-79.1 -24.7 -74.4 -24.7L-69.7 -24.6", fill: nil, stroke: .outline, width: 0.9),
        .init(path: "M-79.7 -38.7Q-80.3 -24.6 -80.5 -17.8L-80.8 -11", fill: nil, stroke: .outline, width: 2),
        .init(path: "M-79.6 -37.2Q-80.1 -24.3 -79.7 -17.4L-79.3 -10.5", fill: nil, stroke: .outline, width: 0.9),
        .init(path: "M-71.8 -10.1Q-68.7 -10 -68.2 -10.1Q-67.7 -10.2 -67.6 -9.9Q-67.5 -9.6 -66.9 -9Q-66.3 -8.4 -66.2 -8.2Q-66.1 -7.9 -66.2 -7.3Q-66.3 -6.8 -66.2 -5.8Q-66.1 -4.9 -66.1 -4.5Q-66.2 -4.1 -66.3 -3.7Q-66.4 -3.4 -66.8 -3.2Q-67.2 -2.9 -67.6 -2.5Q-68.1 -2 -68.5 -2.2Q-68.9 -2.3 -71.5 -2.3Q-74.1 -2.2 -77.1 -1.9Q-80 -1.7 -82.8 -1.8Q-85.5 -1.9 -88.1 -1.9Q-90.7 -1.9 -91.1 -2Q-91.5 -2.2 -92 -2.4Q-92.5 -2.6 -92.8 -3.1Q-93.1 -3.6 -93.7 -4Q-94.2 -4.4 -94.1 -4.7Q-94 -5.1 -94.2 -6.2Q-94.4 -7.3 -94.2 -7.7Q-94.1 -8.2 -93.8 -8.6Q-93.5 -9 -93 -9.1Q-92.5 -9.3 -92.4 -9.5Q-92.3 -9.8 -91.5 -9.7Q-90.7 -9.6 -88.1 -9.9Q-85.5 -10.1 -82.7 -9.9Q-80 -9.8 -77.4 -10Q-74.8 -10.2 -71.8 -10.1Z", fill: .ink, stroke: .outline, width: 3),
        .init(path: "M-72.7 -9.9Q-68.8 -9.9 -68.6 -10Q-68.3 -10.1 -67.6 -9.7Q-66.9 -9.4 -66.9 -9Q-66.8 -8.5 -66.5 -8.2Q-66.1 -8 -66.1 -7.6Q-66.1 -7.2 -66.2 -6.1Q-66.2 -5.1 -66.3 -4.6Q-66.3 -4.1 -66.4 -3.6Q-66.5 -3.1 -66.8 -2.8Q-67.1 -2.6 -67.5 -2.4Q-67.9 -2.3 -68.4 -2.2Q-68.8 -2.2 -72.6 -2Q-76.3 -1.8 -80.1 -1.9Q-83.9 -1.9 -87.6 -2.1Q-91.2 -2.2 -91.6 -2.3Q-92 -2.4 -92.3 -2.6Q-92.7 -2.7 -93.2 -3.1Q-93.7 -3.4 -93.7 -3.8Q-93.7 -4.1 -93.9 -4.4Q-94.1 -4.7 -93.9 -6Q-93.8 -7.3 -93.7 -7.7Q-93.6 -8.2 -93.6 -8.6Q-93.6 -8.9 -93.1 -9.1Q-92.6 -9.2 -92.1 -9.6Q-91.6 -10 -91.3 -9.8Q-91.1 -9.7 -87.4 -10Q-83.7 -10.3 -80.1 -10.1Q-76.5 -9.8 -72.7 -9.9Z", fill: nil, stroke: .outline, width: 1.4),
        .init(path: "M-57.8 -99.3Q-69 -82.3 -74.5 -74L-80.1 -65.8", fill: nil, stroke: .outline, width: 5),
        .init(path: "M-58.5 -100Q-69.3 -83.1 -74.3 -74.8L-79.3 -66.6", fill: nil, stroke: .outline, width: 2.3),
        .init(path: "M-68.7 -68.6Q-68.6 -66.4 -69.1 -63Q-69.7 -59.6 -71.3 -58.1Q-72.9 -56.7 -75.9 -55.9Q-78.8 -55.2 -82.7 -55.3Q-86.6 -55.5 -88.2 -57.8Q-89.8 -60.1 -90.8 -62.4Q-91.8 -64.7 -90.7 -68.1Q-89.7 -71.5 -87.9 -73.4Q-86.2 -75.3 -83.8 -76.9Q-81.3 -78.5 -77.3 -77.5Q-73.2 -76.5 -71.1 -73.7Q-68.9 -70.8 -68.7 -68.6Z", fill: .navy, stroke: .outline, width: 4),
        .init(path: "M-70.1 -69.6Q-68.7 -66.7 -69.5 -63.1Q-70.4 -59.6 -72.9 -57.6Q-75.3 -55.7 -77.8 -55.5Q-80.3 -55.3 -83.5 -55.8Q-86.7 -56.4 -88 -58.9Q-89.3 -61.5 -89.6 -63.8Q-89.9 -66.1 -89.8 -68.5Q-89.6 -70.9 -88.1 -73.1Q-86.6 -75.4 -83.1 -76.5Q-79.7 -77.7 -77.6 -77Q-75.5 -76.3 -73.5 -74.4Q-71.5 -72.5 -70.1 -69.6Z", fill: nil, stroke: .outline, width: 1.8),
        .init(path: "M57.2 -100Q65 -84.1 68.1 -76.9Q71.2 -69.7 74.6 -61.9Q78 -54.1 81.3 -45.8L84.5 -37.6", fill: nil, stroke: .outline, width: 5),
        .init(path: "M57.5 -100Q66.8 -79.8 71.3 -69.4Q75.8 -59 80 -48.6L84.1 -38.1", fill: nil, stroke: .outline, width: 2.3),
        .init(path: "M94.9 -42Q96.2 -39.5 94.7 -36.6Q93.1 -33.7 91 -31.6Q88.8 -29.5 87.2 -28.5Q85.5 -27.4 81.8 -28.7Q78.1 -30 77.1 -31.2Q76.1 -32.3 74.8 -34.6Q73.5 -36.9 73.4 -40.4Q73.3 -44 76 -46.1Q78.8 -48.3 81.9 -49.1Q84.9 -49.8 87.3 -49.2Q89.7 -48.6 91.7 -46.5Q93.6 -44.5 94.9 -42Z", fill: .navy, stroke: .outline, width: 4),
        .init(path: "M94.5 -40.7Q96.1 -38.8 95 -35.5Q93.9 -32.2 91.1 -30.5Q88.3 -28.8 85.8 -28.2Q83.3 -27.6 81.4 -27.6Q79.4 -27.6 77.1 -30.2Q74.8 -32.8 74.3 -35.7Q73.8 -38.6 74.1 -41.6Q74.4 -44.5 75.8 -45.8Q77.3 -47.1 80.2 -48.1Q83.1 -49 86.1 -48.1Q89 -47.1 90.9 -44.9Q92.8 -42.6 94.5 -40.7Z", fill: nil, stroke: .outline, width: 1.8),
        .init(path: "M-27 -42.3Q-26.8 -23.3 -26.5 -13.4L-26.1 -3.6", fill: nil, stroke: .outline, width: 5),
        .init(path: "M-27.6 -42.4Q-26.5 -23 -26.7 -13.3L-26.9 -3.6", fill: nil, stroke: .outline, width: 2.3),
        .init(path: "M-20 -6.1Q-19.9 -4.2 -20.4 -2.2Q-20.8 -0.2 -23.1 1.1Q-25.3 2.4 -27.8 2Q-30.4 1.6 -35.1 2Q-39.8 2.3 -40.8 1Q-41.8 -0.3 -43.7 -2.4Q-45.6 -4.5 -45.1 -6.6Q-44.7 -8.7 -41.8 -9.7Q-38.9 -10.7 -36 -10.1Q-33.1 -9.5 -29 -9.2Q-25 -8.9 -22.6 -8.5Q-20.2 -8.1 -20 -6.1Z", fill: .ink, stroke: .outline, width: 3.5),
        .init(path: "M-19.9 -4.7Q-19.4 -3.3 -20 -2.2Q-20.7 -1.1 -22.7 -0.3Q-24.7 0.5 -28.9 0.9Q-33.1 1.3 -36.4 1.7Q-39.8 2.1 -41.6 0.8Q-43.4 -0.5 -44 -2.2Q-44.6 -3.9 -44.2 -5.4Q-43.7 -6.9 -40.6 -7.7Q-37.6 -8.5 -34.7 -9Q-31.8 -9.5 -29.1 -10.1Q-26.4 -10.7 -23.4 -8.5Q-20.4 -6.2 -19.9 -4.7Z", fill: nil, stroke: .outline, width: 1.6),
        .init(path: "M26.7 -40.9Q27.4 -24.1 26.7 -14.6L26 -5.1", fill: nil, stroke: .outline, width: 5),
        .init(path: "M26.3 -42.6Q27.8 -23.6 27.8 -13.9L27.9 -4.3", fill: nil, stroke: .outline, width: 2.3),
        .init(path: "M44.7 -5Q45.1 -2.9 43.9 -1.2Q42.7 0.6 40.7 0.6Q38.7 0.5 34.7 1.3Q30.7 2 28.5 1.6Q26.3 1.1 23.8 0.8Q21.3 0.4 19.6 -2.3Q17.9 -5 19.4 -6.3Q20.9 -7.5 23.6 -8.6Q26.3 -9.7 28.6 -10.2Q31 -10.8 35.5 -10.2Q40 -9.7 42.1 -8.3Q44.3 -7 44.7 -5Z", fill: .ink, stroke: .outline, width: 3.5),
        .init(path: "M43.8 -5.9Q44 -5.2 43.3 -3.4Q42.7 -1.6 40.5 -0.2Q38.3 1.2 35.3 1.8Q32.4 2.3 28.6 1.4Q24.8 0.4 22.7 -0.5Q20.6 -1.4 19.7 -2.5Q18.7 -3.5 19.8 -5.6Q20.8 -7.6 23.1 -8.4Q25.3 -9.2 28.6 -10.3Q31.9 -11.3 35.3 -9.8Q38.7 -8.4 41.2 -7.5Q43.6 -6.6 43.8 -5.9Z", fill: nil, stroke: .outline, width: 1.6),
        .init(path: "M10.5 -177.3Q20.6 -177.5 27.7 -176.5Q34.9 -175.4 40.9 -172.2Q46.9 -169.1 50.5 -164.2Q54.2 -159.3 57.4 -153.9Q60.5 -148.4 61.4 -142.3Q62.3 -136.1 62.8 -122.9Q63.3 -109.7 63.2 -95.9Q63.2 -82.2 62 -67.4Q60.9 -52.6 61.1 -51.6Q61.4 -50.6 60.4 -47.5Q59.4 -44.5 58 -44.3Q56.6 -44.1 54.9 -42.5Q53.2 -41 50.4 -40Q47.6 -38.9 32.1 -39.4Q16.6 -40 0.5 -40.5Q-15.6 -41 -32.4 -40.9Q-49.1 -40.8 -51 -41.4Q-52.9 -42 -54 -42.8Q-55.2 -43.6 -56.6 -43.9Q-58 -44.3 -59.6 -46.9Q-61.2 -49.5 -62.2 -51.5Q-63.3 -53.6 -63.4 -67.1Q-63.4 -80.7 -63.3 -94.6Q-63.1 -108.5 -62.5 -122.9Q-62 -137.4 -61.7 -143.4Q-61.3 -149.4 -58.4 -153.8Q-55.4 -158.1 -49.7 -163.6Q-43.9 -169 -38.6 -172Q-33.2 -174.9 -27.1 -175.9Q-21.1 -177 -10.3 -177Q0.4 -177.1 10.5 -177.3Z", fill: .navy, stroke: nil, width: 0),
        .init(rect: CGRect(x: -80, y: -186, width: 160, height: 37.2), radius: 0, fill: .navyLight, clip: "M10.5 -177.3Q20.6 -177.5 27.7 -176.5Q34.9 -175.4 40.9 -172.2Q46.9 -169.1 50.5 -164.2Q54.2 -159.3 57.4 -153.9Q60.5 -148.4 61.4 -142.3Q62.3 -136.1 62.8 -122.9Q63.3 -109.7 63.2 -95.9Q63.2 -82.2 62 -67.4Q60.9 -52.6 61.1 -51.6Q61.4 -50.6 60.4 -47.5Q59.4 -44.5 58 -44.3Q56.6 -44.1 54.9 -42.5Q53.2 -41 50.4 -40Q47.6 -38.9 32.1 -39.4Q16.6 -40 0.5 -40.5Q-15.6 -41 -32.4 -40.9Q-49.1 -40.8 -51 -41.4Q-52.9 -42 -54 -42.8Q-55.2 -43.6 -56.6 -43.9Q-58 -44.3 -59.6 -46.9Q-61.2 -49.5 -62.2 -51.5Q-63.3 -53.6 -63.4 -67.1Q-63.4 -80.7 -63.3 -94.6Q-63.1 -108.5 -62.5 -122.9Q-62 -137.4 -61.7 -143.4Q-61.3 -149.4 -58.4 -153.8Q-55.4 -158.1 -49.7 -163.6Q-43.9 -169 -38.6 -172Q-33.2 -174.9 -27.1 -175.9Q-21.1 -177 -10.3 -177Q0.4 -177.1 10.5 -177.3Z"),
        .init(path: "M-69.9 -148.5Q-52.5 -147.9 -43.4 -148.4Q-34.2 -148.9 -26 -148.9Q-17.8 -148.8 -8.8 -149.1Q0.3 -149.3 8.7 -149.4Q17.1 -149.5 25.7 -148.6Q34.3 -147.8 43.1 -148.3Q51.8 -148.8 61.3 -149L70.7 -149.2", fill: nil, stroke: .navyDeep, width: 3, clip: "M10.5 -177.3Q20.6 -177.5 27.7 -176.5Q34.9 -175.4 40.9 -172.2Q46.9 -169.1 50.5 -164.2Q54.2 -159.3 57.4 -153.9Q60.5 -148.4 61.4 -142.3Q62.3 -136.1 62.8 -122.9Q63.3 -109.7 63.2 -95.9Q63.2 -82.2 62 -67.4Q60.9 -52.6 61.1 -51.6Q61.4 -50.6 60.4 -47.5Q59.4 -44.5 58 -44.3Q56.6 -44.1 54.9 -42.5Q53.2 -41 50.4 -40Q47.6 -38.9 32.1 -39.4Q16.6 -40 0.5 -40.5Q-15.6 -41 -32.4 -40.9Q-49.1 -40.8 -51 -41.4Q-52.9 -42 -54 -42.8Q-55.2 -43.6 -56.6 -43.9Q-58 -44.3 -59.6 -46.9Q-61.2 -49.5 -62.2 -51.5Q-63.3 -53.6 -63.4 -67.1Q-63.4 -80.7 -63.3 -94.6Q-63.1 -108.5 -62.5 -122.9Q-62 -137.4 -61.7 -143.4Q-61.3 -149.4 -58.4 -153.8Q-55.4 -158.1 -49.7 -163.6Q-43.9 -169 -38.6 -172Q-33.2 -174.9 -27.1 -175.9Q-21.1 -177 -10.3 -177Q0.4 -177.1 10.5 -177.3Z"),
        .init(path: "M-70 -148.6Q-47.1 -149.1 -35.1 -149.2Q-23 -149.3 -11.9 -148.8Q-0.7 -148.4 11.2 -148.7Q23 -149 35 -149.3Q47 -149.6 58.2 -148.9L69.4 -148.2", fill: nil, stroke: .navyDeep, width: 1.4, clip: "M10.5 -177.3Q20.6 -177.5 27.7 -176.5Q34.9 -175.4 40.9 -172.2Q46.9 -169.1 50.5 -164.2Q54.2 -159.3 57.4 -153.9Q60.5 -148.4 61.4 -142.3Q62.3 -136.1 62.8 -122.9Q63.3 -109.7 63.2 -95.9Q63.2 -82.2 62 -67.4Q60.9 -52.6 61.1 -51.6Q61.4 -50.6 60.4 -47.5Q59.4 -44.5 58 -44.3Q56.6 -44.1 54.9 -42.5Q53.2 -41 50.4 -40Q47.6 -38.9 32.1 -39.4Q16.6 -40 0.5 -40.5Q-15.6 -41 -32.4 -40.9Q-49.1 -40.8 -51 -41.4Q-52.9 -42 -54 -42.8Q-55.2 -43.6 -56.6 -43.9Q-58 -44.3 -59.6 -46.9Q-61.2 -49.5 -62.2 -51.5Q-63.3 -53.6 -63.4 -67.1Q-63.4 -80.7 -63.3 -94.6Q-63.1 -108.5 -62.5 -122.9Q-62 -137.4 -61.7 -143.4Q-61.3 -149.4 -58.4 -153.8Q-55.4 -158.1 -49.7 -163.6Q-43.9 -169 -38.6 -172Q-33.2 -174.9 -27.1 -175.9Q-21.1 -177 -10.3 -177Q0.4 -177.1 10.5 -177.3Z"),
        .init(halo: CGRect(x: -57.5, y: -165.5, width: 63.0, height: 71.4)),
        .init(halo: CGRect(x: -5.5, y: -165.5, width: 63.0, height: 71.4)),
        .init(path: "M10.5 -177.3Q20.6 -177.5 27.7 -176.5Q34.9 -175.4 40.9 -172.2Q46.9 -169.1 50.5 -164.2Q54.2 -159.3 57.4 -153.9Q60.5 -148.4 61.4 -142.3Q62.3 -136.1 62.8 -122.9Q63.3 -109.7 63.2 -95.9Q63.2 -82.2 62 -67.4Q60.9 -52.6 61.1 -51.6Q61.4 -50.6 60.4 -47.5Q59.4 -44.5 58 -44.3Q56.6 -44.1 54.9 -42.5Q53.2 -41 50.4 -40Q47.6 -38.9 32.1 -39.4Q16.6 -40 0.5 -40.5Q-15.6 -41 -32.4 -40.9Q-49.1 -40.8 -51 -41.4Q-52.9 -42 -54 -42.8Q-55.2 -43.6 -56.6 -43.9Q-58 -44.3 -59.6 -46.9Q-61.2 -49.5 -62.2 -51.5Q-63.3 -53.6 -63.4 -67.1Q-63.4 -80.7 -63.3 -94.6Q-63.1 -108.5 -62.5 -122.9Q-62 -137.4 -61.7 -143.4Q-61.3 -149.4 -58.4 -153.8Q-55.4 -158.1 -49.7 -163.6Q-43.9 -169 -38.6 -172Q-33.2 -174.9 -27.1 -175.9Q-21.1 -177 -10.3 -177Q0.4 -177.1 10.5 -177.3Z", fill: nil, stroke: .outline, width: 6),
        .init(path: "M-0.4 -176.7Q21.4 -176.7 28.1 -175.1Q34.7 -173.5 40.6 -170.5Q46.5 -167.5 50.9 -163.7Q55.4 -160 57.3 -154.3Q59.3 -148.6 60.5 -142.2Q61.7 -135.8 62.1 -115.4Q62.5 -95 61.6 -74.2Q60.8 -53.4 60.8 -51.5Q60.8 -49.6 59.5 -47.7Q58.1 -45.8 57 -44Q55.9 -42.2 54.5 -41.5Q53.2 -40.7 51.2 -40Q49.2 -39.3 32.6 -39.3Q15.9 -39.3 -0.6 -39.4Q-17.2 -39.6 -32.2 -40.4Q-47.3 -41.3 -49.6 -41.1Q-51.9 -40.8 -54.4 -42.1Q-56.9 -43.4 -58.6 -44Q-60.3 -44.6 -60.3 -46.9Q-60.3 -49.1 -60.7 -51.1Q-61.2 -53 -61.9 -73.4Q-62.6 -93.8 -62.3 -115.1Q-61.9 -136.3 -60.9 -142.9Q-60 -149.5 -56.8 -154.2Q-53.7 -159 -50.1 -164.1Q-46.5 -169.1 -40.8 -171Q-35.1 -172.9 -28.7 -174.8Q-22.3 -176.7 -0.4 -176.7Z", fill: nil, stroke: .outline, width: 2.7),
        .init(rect: CGRect(x: -37, y: -143.8, width: 22, height: 28), radius: 5, fill: .glow),
        .init(rect: CGRect(x: 15, y: -143.8, width: 22, height: 28), radius: 5, fill: .glow),
        .init(path: "M9.6 -93.1Q7.2 -91.1 6.1 -90.4Q5 -89.7 3.9 -89.3Q2.8 -88.8 1.4 -88.9Q0 -88.9 -1.3 -88.8Q-2.6 -88.7 -3.7 -89.2Q-4.7 -89.6 -6.2 -90.5Q-7.7 -91.3 -8.5 -92.3L-9.3 -93.2", fill: nil, stroke: .glow, width: 4.5),
        .init(path: "M9.1 -93.1Q7.2 -91.2 6.2 -90.7Q5.2 -90.1 4 -89.7Q2.8 -89.3 1.3 -88.8Q-0.3 -88.4 -1.6 -88.7Q-2.9 -89.1 -4 -89.3Q-5.1 -89.5 -6.1 -90.2Q-7.2 -91 -8.1 -91.9L-9 -92.8", fill: nil, stroke: .glow, width: 2),
    ]

    static let face: [SentryLanternArt.Part] = [
        .init(path: "M16 3.4Q17.3 3.4 18.8 3.6Q20.3 3.8 21.9 4.4Q23.6 5.1 24.5 6.4Q25.4 7.7 26.3 9Q27.1 10.2 27.3 12Q27.5 13.7 27.6 16.7Q27.7 19.8 27.6 22.7Q27.5 25.6 27.5 26.3Q27.6 26.9 27 27.3Q26.5 27.7 26.3 28Q26 28.3 25.5 28.7Q24.9 29 24.5 28.9Q24.1 28.8 21.4 29Q18.8 29.2 15.9 29.1Q13.1 29 10.4 29Q7.8 29 7.4 28.8Q6.9 28.7 6.5 28.4Q6.1 28.2 5.6 28Q5.1 27.8 4.8 27.1Q4.6 26.3 4.6 26Q4.6 25.7 4.4 22.5Q4.3 19.4 4.3 16.5Q4.4 13.6 4.7 12Q4.9 10.4 5.5 9.1Q6.2 7.7 7.4 6.7Q8.7 5.7 10.1 5Q11.6 4.2 13.2 3.8Q14.8 3.4 16 3.4Z", fill: .navy, stroke: nil, width: 0),
        .init(path: "M16 3.4Q17.3 3.4 18.8 3.6Q20.3 3.8 21.9 4.4Q23.6 5.1 24.5 6.4Q25.4 7.7 26.3 9Q27.1 10.2 27.3 12Q27.5 13.7 27.6 16.7Q27.7 19.8 27.6 22.7Q27.5 25.6 27.5 26.3Q27.6 26.9 27 27.3Q26.5 27.7 26.3 28Q26 28.3 25.5 28.7Q24.9 29 24.5 28.9Q24.1 28.8 21.4 29Q18.8 29.2 15.9 29.1Q13.1 29 10.4 29Q7.8 29 7.4 28.8Q6.9 28.7 6.5 28.4Q6.1 28.2 5.6 28Q5.1 27.8 4.8 27.1Q4.6 26.3 4.6 26Q4.6 25.7 4.4 22.5Q4.3 19.4 4.3 16.5Q4.4 13.6 4.7 12Q4.9 10.4 5.5 9.1Q6.2 7.7 7.4 6.7Q8.7 5.7 10.1 5Q11.6 4.2 13.2 3.8Q14.8 3.4 16 3.4Z", fill: nil, stroke: .outline, width: 2.4),
        .init(path: "M16 3.3Q17.6 3.3 19.1 3.6Q20.5 3.9 22 4.7Q23.5 5.5 24.5 6.6Q25.4 7.7 26.3 9.1Q27.2 10.5 27.5 12.1Q27.7 13.7 27.7 16.7Q27.6 19.7 27.4 22.6Q27.3 25.5 27.4 26.1Q27.5 26.6 27.1 27.1Q26.8 27.6 26.4 27.9Q25.9 28.1 25.4 28.4Q24.9 28.6 24.4 28.8Q24 29 21.3 28.9Q18.7 28.8 16.1 29Q13.5 29.2 10.9 29.1Q8.2 29 7.6 28.8Q7 28.7 6.5 28.5Q6 28.3 5.6 27.8Q5.3 27.4 5.1 27Q4.8 26.7 4.5 26.1Q4.3 25.4 4.4 22.6Q4.5 19.7 4.4 16.7Q4.3 13.7 4.6 12Q4.8 10.2 5.6 9Q6.3 7.7 7.4 6.7Q8.6 5.6 10 4.9Q11.5 4.1 12.9 3.7Q14.4 3.4 16 3.3Z", fill: nil, stroke: .outline, width: 1.1),
        .init(rect: CGRect(x: 10.6, y: 10.5, width: 3.8, height: 6.2), radius: 1.3, fill: .glow),
        .init(rect: CGRect(x: 17.6, y: 10.5, width: 3.8, height: 6.2), radius: 1.3, fill: .glow),
        .init(path: "M19.3 20.5Q18.4 21.1 17.8 21.4Q17.2 21.6 16.6 21.8Q16 21.9 15.4 21.8Q14.8 21.7 14.3 21.5Q13.8 21.3 13.3 20.8L12.8 20.4", fill: nil, stroke: .glow, width: 1.7),
        .init(path: "M19.3 20.4Q18.3 21.2 17.7 21.4Q17.2 21.6 16.6 21.7Q15.9 21.8 15.4 21.7Q14.8 21.5 14.3 21.4Q13.8 21.2 13.3 20.9L12.8 20.5", fill: nil, stroke: .glow, width: 0.8),
    ]
}

// MARK: Menu-bar glyphs

/// Lantern's face as the menu-bar glyph (OWNER 2026-09-28, relayed by the
/// coordinator: "Lantern glyphs replace the menu-bar shield icons").
///
/// Receipt: geometry copied from the prototype board Popover-MenuBarIcons,
/// viewBox 16x16, drawn 16x16 pt
/// ("Actual size" column) — the same box the old 14 pt shield symbols
/// filled (15x16, UIStatusItem.glyphImage receipt). Shape carries the state;
/// colour only backs it up:
///   on        filled face, eyes and smile cut out, template (no colour)
///   starting  outline, eyes open, template
///   paused    outline, eyes closed, red pause badge
///   attention outline, eyes open, no smile, red "!" badge
///   all good  the "on" face plus a green check badge (2026-10-20, owner):
///             only when protecting AND setup is healthy
///             (`UIState.menuBarBadgeOK`); otherwise the plain "on" face
/// Board colours: ink #1f1a17 / night #f3e6cc, badge #a3311e / night
/// #ff9d8a, badge mark #fbf5e6 / night #2b1d16. The badge's 4 pt ring is
/// painted over the face in the mark colour, so the badge carries its
/// own contrasting edge on any bar, tinted or translucent (item 15 receipt
/// in `draw`).
enum SentryLanternGlyph {
    /// 16 pt: the board draws every glyph in a 16x16 viewBox at 16 px
    /// (Popover-MenuBarIcons). Fixed, not derived from the bar: the paths are
    /// authored on that grid. Bar thickness MEASURED 22 pt on 2026-08-22
    /// (the receipt the old `glyphPointSize` cited), so 16 pt leaves 3 pt
    /// above and below; the old 18 pt tallest glyph fit the same bar.
    /// Tripwire: `--ui-selftest` checks the image is 16x16; a bar thinner
    /// than 16 pt would clip it (none shipped on macOS 14-27).
    static let side: CGFloat = 16

    /// The rounded head, board path `M2 7C2 3.7 4.7 1.5 8 1.5C11.3 1.5 14 3.7
    /// 14 7V12.6C14 13.7 13.2 14.5 12.1 14.5H3.9C2.8 14.5 2 13.7 2 12.6Z`.
    static var head: CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 2, y: 7))
        p.addCurve(to: CGPoint(x: 8, y: 1.5), control1: CGPoint(x: 2, y: 3.7), control2: CGPoint(x: 4.7, y: 1.5))
        p.addCurve(to: CGPoint(x: 14, y: 7), control1: CGPoint(x: 11.3, y: 1.5), control2: CGPoint(x: 14, y: 3.7))
        p.addLine(to: CGPoint(x: 14, y: 12.6))
        p.addCurve(to: CGPoint(x: 12.1, y: 14.5), control1: CGPoint(x: 14, y: 13.7), control2: CGPoint(x: 13.2, y: 14.5))
        p.addLine(to: CGPoint(x: 3.9, y: 14.5))
        p.addCurve(to: CGPoint(x: 2, y: 12.6), control1: CGPoint(x: 2.8, y: 14.5), control2: CGPoint(x: 2, y: 13.7))
        p.closeSubpath()
        return p
    }

    /// Two open eyes, 2.2 x 3.2 with 0.8 corners.
    static var eyes: CGPath {
        let p = CGMutablePath()
        for x in [5.0, 8.8] as [CGFloat] {
            p.addRoundedRect(in: CGRect(x: x, y: 5.4, width: 2.2, height: 3.2), cornerWidth: 0.8, cornerHeight: 0.8)
        }
        return p
    }

    /// Board `M5.6 10.4Q8 13.8 10.4 10.4Q8 11.4 5.6 10.4Z`.
    static var smile: CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 5.6, y: 10.4))
        p.addQuadCurve(to: CGPoint(x: 10.4, y: 10.4), control: CGPoint(x: 8, y: 13.8))
        p.addQuadCurve(to: CGPoint(x: 5.6, y: 10.4), control: CGPoint(x: 8, y: 11.4))
        p.closeSubpath()
        return p
    }

    enum Badge { case none, pause, alert, ok }

    /// The badge for one glyph. `.ok` only on `.protecting`, and only when
    /// the caller says everything else is good too (`allGood`); any other
    /// glyph keeps its own badge or none, so a failure can never wear a check.
    static func badge(for glyph: UIGlyph, allGood: Bool) -> Badge {
        switch glyph {
        case .paused: return .pause
        case .degraded: return .alert
        case .protecting: return allGood ? .ok : .none
        case .starting: return .none
        }
    }

    /// A fresh image per call (UIStatusItem.glyphImage explains why).
    static func image(for glyph: UIGlyph, allGood: Bool = false) -> NSImage {
        let badge = badge(for: glyph, allGood: allGood)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            draw(glyph, badge: badge, in: cg)
            return true
        }
        // Badged glyphs carry colour; the two quiet ones follow the bar. A
        // badged face is NOT a template, so `draw` picks its ink from the
        // drawing appearance itself (day #1f1a17 / night #f3e6cc), which
        // is the bar's: the face still follows a light or dark menu bar.
        image.isTemplate = badge == .none
        return image
    }

    private static func draw(_ glyph: UIGlyph, badge: Badge, in cg: CGContext) {
        let night = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // A template image is recoloured by AppKit; draw it in black.
        let ink = badge == .none ? NSColor.black.cgColor
            : (night ? NSColor(srgbHex: 0xf3e6cc) : NSColor(srgbHex: 0x1f1a17)).cgColor
        cg.setFillColor(ink)
        cg.setStrokeColor(ink)
        if glyph == .protecting {
            cg.addPath(head); cg.addPath(eyes); cg.addPath(smile)
            cg.fillPath(using: .evenOdd)
        } else {
            cg.setLineWidth(1.3)
            cg.addPath(head); cg.strokePath()
            if glyph == .paused {
                cg.setLineCap(.round)
                cg.move(to: CGPoint(x: 5.1, y: 7.3)); cg.addLine(to: CGPoint(x: 7.1, y: 7.3))
                cg.move(to: CGPoint(x: 8.9, y: 7.3)); cg.addLine(to: CGPoint(x: 10.9, y: 7.3))
                cg.strokePath()
            } else {
                cg.addPath(eyes); cg.fillPath()
            }
        }
        guard badge != .none else { return }
        let centre = CGPoint(x: 12.4, y: 12.2)
        // Review 2026-09-29 (item 15): the ring is the badge's own edge, not
        // a hole, so the badge keeps 3:1 against whatever the bar is. On a
        // tinted bar (a mid-blue wallpaper behind a dark bar, relative
        // luminance ~0.15, an ASSUMED bar, not a capture) the bare night coral
        // is about 2.6:1; against this ring it is 8.1:1 (coral #ff9d8a L 0.472 vs ring #2b1d16 L 0.015),
        // and by day #a3311e on the #fbf5e6 ring is 6.4:1 (WCAG formula).
        cg.setFillColor((night ? NSColor(srgbHex: 0x2b1d16) : NSColor(srgbHex: 0xfbf5e6)).cgColor)
        cg.fillEllipse(in: CGRect(x: centre.x - 4, y: centre.y - 4, width: 8, height: 8))
        // OK BADGE (2026-10-20): the brand `ok` room colour (SentryBrand.NS.ok,
        // day #3d6b30 / night #8fd69a) on the same ring. Neither green alone is
        // legible on both bars (WCAG: day green on a #1e1e1e dark bar 2.7:1,
        // night green on a #f6f6f6 light bar 1.6:1; both bars ASSUMED, not
        // captures), so it switches with the appearance like the red badge,
        // and the ring carries the edge: day #3d6b30 on #fbf5e6 5.8:1, night
        // #8fd69a on #2b1d16 9.5:1, the check mark the same against its fill.
        let fill: UInt32 = badge == .ok ? (night ? 0x8fd69a : 0x3d6b30) : (night ? 0xff9d8a : 0xa3311e)
        cg.setFillColor(NSColor(srgbHex: fill).cgColor)
        cg.fillEllipse(in: CGRect(x: centre.x - 3.1, y: centre.y - 3.1, width: 6.2, height: 6.2))
        let mark = (night ? NSColor(srgbHex: 0x2b1d16) : NSColor(srgbHex: 0xfbf5e6)).cgColor
        cg.setFillColor(mark)
        cg.setStrokeColor(mark)
        if badge == .ok {
            // A check inside the 6.2 pt disc, same 1.1 pt stroke as the "!".
            cg.setLineWidth(1.1)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.move(to: CGPoint(x: 10.9, y: 12.3))
            cg.addLine(to: CGPoint(x: 12.0, y: 13.4))
            cg.addLine(to: CGPoint(x: 13.9, y: 11.1))
            cg.strokePath()
        } else if badge == .pause {
            for x in [11.2, 12.8] as [CGFloat] {
                cg.addPath(CGPath(roundedRect: CGRect(x: x, y: 10.8, width: 0.8, height: 2.8),
                    cornerWidth: 0.3, cornerHeight: 0.3, transform: nil))
            }
            cg.fillPath()
        } else {
            cg.setLineWidth(1.1)
            cg.setLineCap(.round)
            cg.move(to: CGPoint(x: 12.4, y: 10.4)); cg.addLine(to: CGPoint(x: 12.4, y: 12.5))
            cg.strokePath()
            cg.fillEllipse(in: CGRect(x: 11.8, y: 13.5, width: 1.2, height: 1.2))
        }
    }
}

private extension NSColor {
    convenience init(srgbHex hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}
