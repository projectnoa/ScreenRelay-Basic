//
//  TileStreamSession.swift
//  ScreenRelay
//
//  Native-quality pipeline for fast wired links: each captured frame is BC7-encoded
//  on the GPU (~4 ms for 5K), the GPU flags which 64×64 tiles actually changed, and
//  only those tiles are sent. The target copies them straight into a BC7 texture and
//  draws it — there is no video decoder anywhere, so there's nothing to wait for and
//  no compression artifacts beyond BC7's (visually lossless for desktop content).
//

import Foundation
import CoreMedia
import CoreVideo
import Metal

nonisolated final class TileStreamSession: StreamSession, @unchecked Sendable {
    /// Frames sent but not yet drawn by the target before new frames wait.
    private static let maxFramesInFlight = 2
    private static let ackTimeout: TimeInterval = 1

    private let connection: MessageConnection
    private let encoder: BC7Encoder
    private let capturer = ScreenCapturer()
    private let sendQueue = DispatchQueue(label: "ScreenRelay.tiles.send", qos: .userInteractive)
    private let lock = NSLock()

    private var frame: BC7Frame
    private(set) var size: (width: Int, height: Int)
    private var frameNumber: UInt32 = 0
    /// True while the GPU encodes or tiles are being copied out; only one frame at a time
    /// touches the shared block buffer.
    private var encoding = false
    /// The newest capture that arrived while busy (older ones are simply replaced).
    private var pendingFrame: CVPixelBuffer?
    private var lastPixelBuffer: CVPixelBuffer?
    /// Send everything on the next frame (start, resize, or the target asked for it).
    private var sendAllTiles = true
    private var framesInFlight = 0
    private var lastAckTime = CFAbsoluteTimeGetCurrent()
    private var lastSendTime = CFAbsoluteTimeGetCurrent()

    // Statistics.
    private var unacknowledgedSendTimes: [CFAbsoluteTime] = []
    private var smoothedRoundTrip: Double?
    private var smoothedDraw: Double?
    private var smoothedEncode: Double?
    private var capturedSinceLastSample = 0
    private var skippedSinceLastSample = 0
    private var acknowledgedSinceLastSample = 0
    private var bytesSinceLastSample = 0
    private var lastSampleTime = CFAbsoluteTimeGetCurrent()

    var onStop: (@Sendable (Error) -> Void)?
    var modeDescription: String { "BC7, native quality" }

    init(connection: MessageConnection, width: Int, height: Int) throws {
        self.connection = connection
        self.encoder = try BC7Encoder()
        guard let frame = encoder.makeFrame(width: width, height: height) else { throw BC7EncoderError.noMetalDevice }
        self.frame = frame
        self.size = (width, height)

        capturer.onFrame = { [weak self] pixelBuffer, _ in
            self?.handleCapturedFrame(pixelBuffer)
        }
        capturer.onStop = { [weak self] error in
            self?.onStop?(error)
        }
    }

    func start(displayID: CGDirectDisplayID, frameRate: Int, showsCursor: Bool) async throws {
        sendCanvasFormat(width: size.width, height: size.height)
        try await capturer.start(displayID: displayID, pixelWidth: size.width, pixelHeight: size.height,
                                 frameRate: frameRate, showsCursor: showsCursor, pixelFormat: kCVPixelFormatType_32BGRA)
    }

    func stop() {
        capturer.stop()
        capturer.onFrame = nil
    }

    func resize(width: Int, height: Int) async throws {
        guard (width, height) != size, let newFrame = encoder.makeFrame(width: width, height: height) else { return }
        sendQueue.sync {
            lock.withLock {
                frame = newFrame
                size = (width, height)
                lastPixelBuffer = nil
                pendingFrame = nil
                sendAllTiles = true
            }
            sendCanvasFormat(width: width, height: height)
        }
        try await capturer.updateSize(width: width, height: height)
    }

    func setBitrate(_ bitrate: Int) {
        // BC7 has a fixed size per pixel; there's no bitrate to tune.
    }

    func setShowsCursor(_ showsCursor: Bool) async throws {
        try await capturer.setShowsCursor(showsCursor)
    }

    func requestKeyFrame() {
        let pixelBuffer: CVPixelBuffer? = lock.withLock {
            sendAllTiles = true
            return encoding ? nil : lastPixelBuffer
        }
        if let pixelBuffer { handleCapturedFrame(pixelBuffer, isCapture: false) }
    }

    func handleFrameAck(decodeMicroseconds: UInt32) {
        let now = CFAbsoluteTimeGetCurrent()
        let pending: CVPixelBuffer? = lock.withLock {
            lastAckTime = now
            framesInFlight = max(0, framesInFlight - 1)
            if !unacknowledgedSendTimes.isEmpty {
                smoothedRoundTrip = Self.smooth(smoothedRoundTrip, now - unacknowledgedSendTimes.removeFirst())
            }
            if decodeMicroseconds > 0 {
                smoothedDraw = Self.smooth(smoothedDraw, Double(decodeMicroseconds) / 1_000_000)
            }
            acknowledgedSinceLastSample += 1
            // A frame that waited for room in the pipeline can go now.
            guard !encoding, let pendingFrame else { return nil }
            self.pendingFrame = nil
            return pendingFrame
        }
        if let pending { handleCapturedFrame(pending, isCapture: false) }
    }

    func sampleStatistics() -> StreamStatistics {
        let now = CFAbsoluteTimeGetCurrent()
        return lock.withLock {
            let elapsed = max(now - lastSampleTime, 0.001)
            let stats = StreamStatistics(
                capturedPerSecond: Double(capturedSinceLastSample) / elapsed,
                skippedPerSecond: Double(skippedSinceLastSample) / elapsed,
                shownPerSecond: Double(acknowledgedSinceLastSample) / elapsed,
                encodeMilliseconds: smoothedEncode.map { $0 * 1000 },
                decodeMilliseconds: smoothedDraw.map { $0 * 1000 },
                roundTripMilliseconds: smoothedRoundTrip.map { $0 * 1000 },
                megabitsPerSecond: Double(bytesSinceLastSample) * 8 / elapsed / 1_000_000
            )
            capturedSinceLastSample = 0
            skippedSinceLastSample = 0
            acknowledgedSinceLastSample = 0
            bytesSinceLastSample = 0
            lastSampleTime = now
            return stats
        }
    }

    // MARK: - Pipeline

    private func handleCapturedFrame(_ pixelBuffer: CVPixelBuffer, isCapture: Bool = true) {
        let now = CFAbsoluteTimeGetCurrent()
        let target: BC7Frame? = lock.withLock {
            if isCapture { capturedSinceLastSample += 1 }
            guard CVPixelBufferGetWidth(pixelBuffer) == size.width,
                  CVPixelBufferGetHeight(pixelBuffer) == size.height else { return nil }
            lastPixelBuffer = pixelBuffer
            // Watchdog: never stall forever waiting for an ack that won't come.
            if framesInFlight > 0, now - max(lastAckTime, lastSendTime) > Self.ackTimeout {
                print("[Tiles] No ack for \(framesInFlight) frame(s), resetting flow control")
                framesInFlight = 0
                unacknowledgedSendTimes.removeAll()
            }
            guard !encoding, framesInFlight < Self.maxFramesInFlight else {
                // Busy: keep only the newest frame; it already contains every change.
                if pendingFrame != nil, isCapture { skippedSinceLastSample += 1 }
                pendingFrame = pixelBuffer
                return nil
            }
            encoding = true
            return frame
        }
        guard let target else { return }

        do {
            try encoder.encode(pixelBuffer, into: target) { [weak self] gpuSeconds in
                self?.sendQueue.async { self?.sendChangedTiles(of: target, gpuSeconds: gpuSeconds) }
            }
        } catch {
            print("[Tiles] Encode failed: \(error)")
            lock.withLock { encoding = false }
        }
    }

    /// Runs on `sendQueue` after the GPU finished: sends every changed tile, grouped into
    /// horizontal runs, then `frameEnd`.
    private func sendChangedTiles(of encoded: BC7Frame, gpuSeconds: Double) {
        let (current, sendAll) = lock.withLock { () -> (Bool, Bool) in
            smoothedEncode = Self.smooth(smoothedEncode, gpuSeconds)
            defer { sendAllTiles = false }
            return (encoded === frame, sendAllTiles)
        }
        // A resize replaced the frame while this one was encoding; its tiles are stale.
        guard current else { finishEncoding(sentFrame: false); return }

        let flags = encoded.tileFlags.contents().assumingMemoryBound(to: UInt8.self)
        let blocks = encoded.blocks.contents().assumingMemoryBound(to: UInt8.self)
        let tileBlocks = BC7Frame.tileBlocks
        let frameNumber = lock.withLock { () -> UInt32 in
            self.frameNumber &+= 1
            return self.frameNumber
        }
        var bytesSent = 0

        for tileY in 0..<encoded.tilesHigh {
            var tileX = 0
            while tileX < encoded.tilesWide {
                guard sendAll || flags[tileY * encoded.tilesWide + tileX] != 0 else { tileX += 1; continue }
                // Extend the run across neighbouring changed tiles.
                var runEnd = tileX + 1
                while runEnd < encoded.tilesWide, sendAll || flags[tileY * encoded.tilesWide + runEnd] != 0 { runEnd += 1 }

                let blockX = tileX * tileBlocks, blockY = tileY * tileBlocks
                let blocksWide = min(runEnd * tileBlocks, encoded.blocksWide) - blockX
                let blocksHigh = min(blockY + tileBlocks, encoded.blocksHigh) - blockY
                let rowBytes = blocksWide * BC7Encoder.bytesPerBlock

                var payload = TileRun.header(frame: frameNumber, blockX: blockX, blockY: blockY,
                                             blocksWide: blocksWide, blocksHigh: blocksHigh)
                payload.reserveCapacity(TileRun.headerLength + rowBytes * blocksHigh)
                for row in blockY..<(blockY + blocksHigh) {
                    let start = blocks + row * encoded.bytesPerBlockRow + blockX * BC7Encoder.bytesPerBlock
                    payload.append(start, count: rowBytes)
                }
                connection.send(.tiles, payload: payload)
                bytesSent += payload.count
                tileX = runEnd
            }
        }
        memset(flags, 0, encoded.tilesWide * encoded.tilesHigh)

        if bytesSent > 0 {
            var end = Data()
            end.appendBigEndian(frameNumber)
            connection.send(.frameEnd, payload: end)
        }
        lock.withLock { bytesSinceLastSample += bytesSent }
        finishEncoding(sentFrame: bytesSent > 0)
    }

    private func finishEncoding(sentFrame: Bool) {
        let now = CFAbsoluteTimeGetCurrent()
        let next: CVPixelBuffer? = lock.withLock {
            encoding = false
            if sentFrame {
                framesInFlight += 1
                unacknowledgedSendTimes.append(now)
                lastSendTime = now
            }
            guard framesInFlight < Self.maxFramesInFlight, let pendingFrame else { return nil }
            self.pendingFrame = nil
            return pendingFrame
        }
        if let next { handleCapturedFrame(next, isCapture: false) }
    }

    private func sendCanvasFormat(width: Int, height: Int) {
        var payload = Data()
        payload.appendBigEndian(UInt32(width))
        payload.appendBigEndian(UInt32(height))
        connection.send(.canvasFormat, payload: payload)
    }

    private static func smooth(_ average: Double?, _ sample: Double) -> Double {
        average.map { $0 * 0.9 + sample * 0.1 } ?? sample
    }
}
