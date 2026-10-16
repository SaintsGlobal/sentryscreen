import AppKit
import CoreGraphics
import CoreVideo
import Foundation

/// DEV-only pixel observer for `--dev-crop-dir`. It receives notifications
/// from Tracker and Curtain, but it does not return data to either pipeline.
/// The detector queue copies the current BGRA frame once per notification
/// batch. JPEG encoding and disk writes run on `writeQueue`.
final class CropWriter {
    enum Kind: String, Encodable {
        case regionBirth = "region_birth"
        case curtainDrop = "curtain_drop"
    }

    struct Request {
        let kind: Kind
        let detection: Detection
        let regionID: Int?
        let windowID: CGWindowID?
    }

    private struct PendingRequest {
        let seq: Int
        let request: Request
    }

    private struct FrameDetection: Encodable {
        let label: String
        let conf: Float
        let box: [Double]
    }

    private struct FrameCopy {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let bytes: Data
    }

    private struct Record: Encodable {
        let ts: String
        let seq: Int
        let frameSeq: Int
        let kind: Kind
        let label: String
        let conf: Float
        let box: [Double]
        let frameW: Int
        let frameH: Int
        let windowID: UInt32?
        let regionID: Int?
        let tight: String
        let ctx: String
        let frameDets: [FrameDetection]
        /// Pixel coordinates in the copied frame, top-left origin. The judge
        /// uses `ctxWindow` to map the normalized student box into ctx pixels.
        let ctxWindow: [Int]

        enum CodingKeys: String, CodingKey {
            case ts, seq, kind, label, conf, box, tight, ctx
            case frameSeq = "frame_seq"
            case frameDets = "frame_dets"
            case frameW = "frame_w"
            case frameH = "frame_h"
            case windowID = "window_id"
            case regionID = "region_id"
            case ctxWindow = "ctx_window"
        }
    }

    private let directory: URL
    private let metadataHandle: FileHandle
    private let onEvent: (String) -> Void
    private let maxFilesLimit: Int
    private let maxBytesLimit: Int
    private let maxPendingJobsLimit: Int
    private let encoder = JSONEncoder()
    private let writeQueue = DispatchQueue(label: "sentryscreen.crop-writer", qos: .utility)
    private let stateLock = NSLock()

    private var nextSeq = 1
    private var nextFrameSeq = 1
    private var pendingJobs = 0
    // crops.jsonl is the first capture-owned file and counts against maxFiles.
    private var filesReserved = 1
    private var bytesWritten = 0
    // Admission tripwires stop new jobs but let already-reserved work drain.
    // A byte or integrity failure also stops queued writes because completion
    // would violate the byte cap or the all-crops-complete contract.
    private var accepting = true
    private var writeFailed = false

    /// Initial budget before the first shielded crop run. STATED REASON
    /// (owner brief, 2026-09-03): capture owns one JSONL plus exactly two JPEGs
    /// per event. 2,048 files permits 1,023 complete birth/drop rows (2,047
    /// files; the pair invariant leaves one slot unused). MEASURED in the first
    /// complete shielded pass `crop-proto-20260903-real-a`: 25 rows / 51 owned
    /// files, so this is 40.16x the observed file count. The wide DEV margin allows
    /// different pages without an unbounded directory. Never raise it after a
    /// trip without a new measurement.
    static let maxFiles = 2_048
    /// Initial logical-byte budget. STATED REASON (owner brief, 2026-09-03): 512 MiB
    /// gives 512 KiB per event at the 1,024-event file ceiling. MEASURED in
    /// `crop-proto-20260903-real-a`: 2,727,027 logical bytes for 25 rows
    /// (JPEG payloads + metadata + newlines), so this is 196.87x the observed
    /// run. The independent file cap stays the
    /// primary item-count tripwire.
    static let maxBytes = 512 * 1_024 * 1_024
    /// Background queue tripwire. STATED REASON (2026-09-03): eight copied
    /// 1280x720 BGRA frames are about 28 MiB. A ninth means disk/JPEG work is
    /// no longer keeping up with the live path. Stop capture instead of
    /// allowing an unbounded frame-retention queue.
    static let maxPendingJobs = 8
    /// The brief requires JPEG output. A 0.90 compression factor keeps box
    /// edges legible for local judges while the byte tripwire remains the
    /// authoritative disk bound. This is a stated diagnostic-quality choice,
    /// not an accuracy measurement.
    static let jpegQuality: CGFloat = 0.90
    /// Owner requirement: the tight crop extends by 15 percent of the box
    /// width and height on each side.
    static let tightMarginFraction: CGFloat = 0.15
    /// Owner requirement: the context crop is 640x640 where the frame permits.
    static let contextSide = 640

    init(
        directory path: String,
        maxFiles: Int = CropWriter.maxFiles,
        maxBytes: Int = CropWriter.maxBytes,
        maxPendingJobs: Int = CropWriter.maxPendingJobs,
        onEvent: @escaping (String) -> Void
    ) throws {
        self.directory = URL(fileURLWithPath: path, isDirectory: true)
        self.onEvent = onEvent
        self.maxFilesLimit = maxFiles
        self.maxBytesLimit = maxBytes
        self.maxPendingJobsLimit = maxPendingJobs
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata = directory.appendingPathComponent("crops.jsonl")
        if fm.fileExists(atPath: metadata.path) {
            // Local file read via FileManager, never `Data(contentsOf:)`: that
            // Foundation loader fetches http(s) URLs too, so the source egress
            // Tripwire bans it
            // outright rather than guessing at a grep whether a URL is local.
            // A nil here is an unreadable resume file, which fails by name.
            guard let contents = fm.contents(atPath: metadata.path) else {
                throw NSError(
                    domain: "CropWriter", code: 3,
                    userInfo: [NSLocalizedDescriptionKey:
                        "cannot resume \(metadata.path): file exists but is unreadable"])
            }
            for (lineNumber, line) in contents.split(separator: 0x0a).enumerated() {
                guard let row = try JSONSerialization.jsonObject(with: Data(line))
                    as? [String: Any],
                    let seq = row["seq"] as? Int
                else {
                    throw NSError(
                        domain: "CropWriter", code: 1,
                        userInfo: [NSLocalizedDescriptionKey:
                            "cannot resume \(metadata.path): invalid row \(lineNumber + 1)"])
                }
                nextSeq = max(nextSeq, seq + 1)
                if let frameSeq = row["frame_seq"] as? Int {
                    nextFrameSeq = max(nextFrameSeq, frameSeq + 1)
                }
            }
            filesReserved = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent == "crops.jsonl" || $0.pathExtension == "jpg" }.count
            bytesWritten = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
                .filter { $0.lastPathComponent == "crops.jsonl" || $0.pathExtension == "jpg" }
                .reduce(0) { total, url in
                    total + ((try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
            metadataHandle = try FileHandle(forWritingTo: metadata)
            metadataHandle.seekToEndOfFile()
            onEvent("resumed=true seq=\(nextSeq)")
            return
        }
        guard fm.createFile(atPath: metadata.path, contents: nil),
            let handle = try? FileHandle(forWritingTo: metadata)
        else {
            throw NSError(
                domain: "CropWriter", code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "--dev-crop-dir cannot create \(metadata.path)"])
        }
        metadataHandle = handle
    }

    deinit {
        try? metadataHandle.close()
    }

    /// Called on the detector queue. It only validates/reserves the budget,
    /// copies one frame, and hands the immutable bytes to `writeQueue`.
    func submit(
        _ pixelBuffer: CVPixelBuffer, frameDetections: [Detection], requests: [Request]
    ) {
        guard !requests.isEmpty else { return }
        let neededFiles = requests.count * 2
        stateLock.lock()
        if !accepting {
            stateLock.unlock()
            return
        }
        if filesReserved + neededFiles > maxFilesLimit {
            let observed = filesReserved + neededFiles
            accepting = false
            stateLock.unlock()
            trip(
                budget: "CropWriter.maxFiles", limit: maxFilesLimit, observed: observed,
                remediation: "CropWriter.maxFiles (remeasure the shielded run before changing)")
            return
        }
        if pendingJobs + 1 > maxPendingJobsLimit {
            let observed = pendingJobs + 1
            accepting = false
            stateLock.unlock()
            trip(
                budget: "CropWriter.maxPendingJobs", limit: maxPendingJobsLimit,
                observed: observed,
                remediation: "CropWriter.maxPendingJobs or JPEG/write throughput")
            return
        }
        let pending = requests.map { request -> PendingRequest in
            defer { nextSeq += 1 }
            return PendingRequest(seq: nextSeq, request: request)
        }
        let frameSeq = nextFrameSeq
        nextFrameSeq += 1
        let timestamp = ISO8601DateFormatter().string(from: .now)
        filesReserved += neededFiles
        pendingJobs += 1
        stateLock.unlock()

        guard let frame = Self.copy(pixelBuffer) else {
            stopForFailure("frame-copy failed (expected kCVPixelFormatType_32BGRA)")
            finishJob()
            return
        }
        writeQueue.async { [self] in
            defer { finishJob() }
            let detections = frameDetections.map { detection in
                FrameDetection(
                    label: detection.label, conf: detection.confidence,
                    box: [detection.box.minX, detection.box.minY,
                          detection.box.width, detection.box.height].map {
                        (Double($0) * 1_000).rounded() / 1_000
                    })
            }
            write(
                frame: frame, timestamp: timestamp, frameSeq: frameSeq,
                frameDetections: detections, requests: pending)
        }
    }

    /// Normal shutdown waits for every accepted frame job. This is outside
    /// the live frame path and makes `crops.jsonl` a complete receipt.
    func finish() {
        writeQueue.sync {}
        try? metadataHandle.synchronize()
    }

    private func finishJob() {
        stateLock.lock()
        pendingJobs = max(0, pendingJobs - 1)
        stateLock.unlock()
    }

    private func trip(budget: String, limit: Int, observed: Int, remediation: String) {
        onEvent(
            "budget=\(budget) limit=\(limit) observed=\(observed) "
            + "writing=stopped remediation=\(remediation)")
    }

    private func stopForFailure(_ failure: String) {
        stateLock.lock()
        let first = !writeFailed
        accepting = false
        writeFailed = true
        stateLock.unlock()
        if first {
            onEvent(
                "budget=CropWriter.writeIntegrity limit=all-crops-complete "
                + "observed=\(failure) writing=stopped remediation=--dev-crop-dir permissions and CropWriter")
        }
    }

    private func write(
        frame: FrameCopy, timestamp: String, frameSeq: Int,
        frameDetections: [FrameDetection], requests: [PendingRequest]
    ) {
        for pending in requests {
            stateLock.lock()
            let shouldStop = writeFailed
            stateLock.unlock()
            if shouldStop { return }

            let box = pending.request.detection.box
            let tightRect = Self.tightRect(box, width: frame.width, height: frame.height)
            let ctxRect = Self.contextRect(box, width: frame.width, height: frame.height)
            guard let tightData = Self.jpeg(frame, rect: tightRect),
                let ctxData = Self.jpeg(frame, rect: ctxRect)
            else {
                stopForFailure("JPEG encode failed at seq \(pending.seq)")
                return
            }
            let tightName = String(format: "tight-%06d.jpg", pending.seq)
            let ctxName = String(format: "ctx-%06d.jpg", pending.seq)
            let record = Record(
                ts: timestamp,
                seq: pending.seq, frameSeq: frameSeq, kind: pending.request.kind,
                label: pending.request.detection.label,
                conf: pending.request.detection.confidence,
                box: [box.minX, box.minY, box.width, box.height].map {
                    (Double($0) * 1_000).rounded() / 1_000
                },
                frameW: frame.width, frameH: frame.height,
                windowID: pending.request.windowID,
                regionID: pending.request.regionID,
                tight: tightName, ctx: ctxName,
                frameDets: frameDetections,
                ctxWindow: [ctxRect.minX, ctxRect.minY, ctxRect.width, ctxRect.height])
            guard let metadata = try? encoder.encode(record) else {
                stopForFailure("JSON encode failed at seq \(pending.seq)")
                return
            }
            let batchBytes = tightData.count + ctxData.count + metadata.count + 1
            stateLock.lock()
            let observedBytes = bytesWritten + batchBytes
            if observedBytes > maxBytesLimit {
                accepting = false
                writeFailed = true
                stateLock.unlock()
                trip(
                    budget: "CropWriter.maxBytes", limit: maxBytesLimit,
                    observed: observedBytes,
                    remediation: "CropWriter.maxBytes (remeasure the shielded run before changing)")
                return
            }
            bytesWritten = observedBytes
            stateLock.unlock()
            do {
                try tightData.write(to: directory.appendingPathComponent(tightName), options: .atomic)
                try ctxData.write(to: directory.appendingPathComponent(ctxName), options: .atomic)
                try metadataHandle.write(contentsOf: metadata)
                try metadataHandle.write(contentsOf: Data([0x0a]))
            } catch {
                stopForFailure("seq \(pending.seq): \(error)")
                return
            }
        }
    }

    private static func copy(_ buffer: CVPixelBuffer) -> FrameCopy? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
            CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess
        else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let dataSize = CVPixelBufferGetDataSize(buffer)
        guard bytesPerRow <= dataSize / max(height, 1) else { return nil }
        return FrameCopy(
            width: width, height: height, bytesPerRow: bytesPerRow,
            bytes: Data(bytes: base, count: bytesPerRow * height))
    }

    /// Int rects use top-left pixel coordinates, matching the copied BGRA rows.
    private static func tightRect(_ box: CGRect, width: Int, height: Int) -> IntRect {
        let x0 = (box.minX - box.width * tightMarginFraction) * CGFloat(width)
        let x1 = (box.maxX + box.width * tightMarginFraction) * CGFloat(width)
        let y0 = (1 - box.maxY - box.height * tightMarginFraction) * CGFloat(height)
        let y1 = (1 - box.minY + box.height * tightMarginFraction) * CGFloat(height)
        return IntRect.clamped(x0: x0, y0: y0, x1: x1, y1: y1, width: width, height: height)
    }

    private static func contextRect(_ box: CGRect, width: Int, height: Int) -> IntRect {
        let sideW = min(contextSide, width)
        let sideH = min(contextSide, height)
        let cx = box.midX * CGFloat(width)
        let cy = (1 - box.midY) * CGFloat(height)
        let x = min(max(Int((cx - CGFloat(sideW) / 2).rounded()), 0), width - sideW)
        let y = min(max(Int((cy - CGFloat(sideH) / 2).rounded()), 0), height - sideH)
        return IntRect(minX: x, minY: y, width: sideW, height: sideH)
    }

    private static func jpeg(_ frame: FrameCopy, rect: IntRect) -> Data? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let rowBytes = rect.width * 4
        var cropped = Data(count: rowBytes * rect.height)
        cropped.withUnsafeMutableBytes { dstRaw in
            frame.bytes.withUnsafeBytes { srcRaw in
                guard let dst = dstRaw.baseAddress, let src = srcRaw.baseAddress else { return }
                for row in 0..<rect.height {
                    memcpy(
                        dst.advanced(by: row * rowBytes),
                        src.advanced(by: (rect.minY + row) * frame.bytesPerRow + rect.minX * 4),
                        rowBytes)
                }
            }
        }
        guard let provider = CGDataProvider(data: cropped as CFData),
            let image = CGImage(
                width: rect.width, height: rect.height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent)
        else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(
            using: .jpeg, properties: [.compressionFactor: jpegQuality])
    }
}

private struct IntRect {
    let minX: Int
    let minY: Int
    let width: Int
    let height: Int

    static func clamped(
        x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat, width: Int, height: Int
    ) -> IntRect {
        let left = min(max(Int(floor(x0)), 0), max(0, width - 1))
        let top = min(max(Int(floor(y0)), 0), max(0, height - 1))
        let right = min(max(Int(ceil(x1)), left + 1), width)
        let bottom = min(max(Int(ceil(y1)), top + 1), height)
        return IntRect(minX: left, minY: top, width: right - left, height: bottom - top)
    }
}
