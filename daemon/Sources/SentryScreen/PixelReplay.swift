import AVFoundation
import CoreVideo
import Foundation

/// Headless pixel replay: decode a video file
/// with AVFoundation and push every frame through the SAME pipeline live
/// capture uses (real CoreML detector + MotionBoxes + Tracker + Policy) —
/// Pipeline.step. No capture, no overlay window, no NSApplication: this runs
/// over a plain shell with nothing on screen, so fixtures with exact ground
/// truth can be scored without a display.
///
/// Each log record carries `frame` (0-based decode index, the join key with
/// <fixture>.truth.jsonl) and `painted` (OverlayManager.paintRect, the exact
/// normalized rects the overlay would paint).
func runPixelReplay(_ path: String, opts: Options) -> Never {
    var opts = opts
    guard FileManager.default.fileExists(atPath: path) else {
        die("cannot read video: \(path)", code: 66)
    }
    guard FileManager.default.fileExists(atPath: opts.model) else {
        die("model not found: \(opts.model) (pass --model <path.mlpackage>)", code: 4)
    }

    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let track = asset.tracks(withMediaType: .video).first else {
        die("no video track in \(path)", code: 66)
    }

    // fps drives every frame-counted constant (Tracker hysteresis/sticky hold,
    // media hold frames, MotionBoxes aging), so it must come from the fixture,
    // not the live-capture default. Track-derived always wins; 30 if the track
    // does not report one.
    let nominal = track.nominalFrameRate
    let trackFps = nominal > 0 ? Int(nominal.rounded()) : 30
    // An EXPLICIT --fps / config fps silently overwritten by the track is the
    // same mislabelled-run hazard the --tier guard below refuses (receipt audit
    // 2026-09-02), so it fails the same way rather than only for --tier.
    if opts.fpsExplicit && opts.fps != trackFps {
        die("--fps \(opts.fps) disagrees with \(path)'s \(trackFps) fps; PixelReplay "
            + "takes fps from the video track, so this run would use the track's "
            + "frame-derived constants under the flag's name (fix: replay an "
            + "fps-\(opts.fps) copy of the fixture, or drop --fps)", code: 64)
    }
    opts.fps = trackFps
    // A forced tier and a fixture that disagree would produce a run LABELLED
    // one thing and BEHAVING as another — the tier's derived constants would
    // come from the track's fps while the record said `--tier no-ane`. That is
    // a silently mislabelled measurement, which is worse than no measurement.
    // Decimate the fixture to the tier's fps instead.
    if let forced = opts.tierOverride {
        let want = PerfTier.tier(named: forced).fps
        if want != opts.fps {
            die("--tier \(forced.rawValue) wants fps \(want) but \(path) is "
                + "\(opts.fps) fps; PixelReplay takes fps from the video track, so "
                + "this run would use the track's frame-derived constants under the "
                + "tier's name (fix: replay an fps-\(want) copy of the fixture, "
                + "`ffmpeg -i <in> -vf fps=\(want) -r \(want) <out>`)", code: 64)
        }
    }
    let size = track.naturalSize
    // Rotation metadata would hand us an unrotated buffer while the fixture's
    // ground truth is upright — every rect would land in the wrong space with
    // no error anywhere. Fail loudly instead.
    let t = track.preferredTransform
    if t != .identity {
        FileHandle.standardError.write(Data(
            ("WARNING: video track carries a non-identity transform \(t); frames are "
            + "decoded UNROTATED, so painted rects will not match upright ground truth "
            + "(fix: re-encode the fixture without rotation metadata)\n").utf8))
    }

    let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
    output.alwaysCopiesSampleData = false
    guard let reader = try? AVAssetReader(asset: asset) else {
        die("cannot open \(path) for reading", code: 66)
    }
    reader.add(output)
    guard reader.startReading() else {
        die("AVAssetReader failed to start: \(String(describing: reader.error))", code: 66)
    }

    let pipeline: Pipeline
    do {
        pipeline = try Pipeline(opts: opts, quiet: true)
    } catch {
        die("model load failed: \(error)", code: 4)
    }
    print(
        "processing \(path): \(Int(size.width))x\(Int(size.height)) fps=\(opts.fps) "
        + "cover=\(opts.cover.rawValue) blockFaces=\(opts.blockFaces)"
        + (opts.cover == .media
            ? " mediaHold=\(opts.mediaHoldSecs)s (\(opts.mediaHoldFrames) frames)" : "")
        + " model=\(opts.model)")

    // Clock starts after model compile/warmup so the
    // average reflects steady-state work; frame 0 still carries first-inference
    // warmup.
    let started = CFAbsoluteTimeGetCurrent()
    var frameIndex = 0  // source decode ordinal: the ground-truth join key
    var logged = 0
    var skipped = 0
    while let sample = output.copyNextSampleBuffer() {
        defer { frameIndex += 1 }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
            // The index is the join key with <fixture>.truth.jsonl, so it must
            // stay the SOURCE ordinal: a dropped sample leaves one detectable
            // gap instead of shifting every later frame against the truth.
            skipped += 1
            continue
        }
        pipeline.step(
            pixelBuffer, capturedAt: CFAbsoluteTimeGetCurrent(), frameIndex: frameIndex)
        logged += 1
    }
    let elapsed = CFAbsoluteTimeGetCurrent() - started
    if reader.status == .failed {
        die("decode failed after \(frameIndex) frames: \(String(describing: reader.error))",
            code: 66)
    }
    if skipped > 0 {
        FileHandle.standardError.write(Data(
            ("WARNING: \(skipped) of \(frameIndex) decoded sample(s) had no image buffer "
            + "and produced no record; those frame indices are missing from the log "
            + "(fix: PixelReplay decode loop)\n").utf8))
    }
    print(String(
        format: "processed %d frames in %.2fs (%.1f ms/frame avg, %.1f fps)",
        logged, elapsed, logged > 0 ? elapsed * 1000 / Double(logged) : 0,
        elapsed > 0 ? Double(logged) / elapsed : 0)
        + (pipeline.mediaMsAverage.map {
            String(format: " mediaMs=%.3f avg (budget 2.0)", $0)
        } ?? "")
        // Stdout only, never the log: the weak-detections proof compares logs.
        + (pipeline.weakBoxesSeen > 0 ? " weakBoxesTraceOnly=\(pipeline.weakBoxesSeen)" : ""))
    exit(0)
}
