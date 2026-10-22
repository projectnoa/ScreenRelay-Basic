//
//  HostStreamSession.swift
//  ScreenRelay
//
//  Capture → encode → send pipeline for one connected target.
//

import Foundation
import CoreMedia
import CoreVideo

nonisolated final class HostStreamSession: StreamSession, @unchecked Sendable {
    /// Frames allowed anywhere in the pipeline (encoding, on the network, or decoding
    /// on the target) before new captures are skipped. A frame counts from the moment
    /// it's handed to the encoder until the target acknowledges decoding it, so no stage
    /// can build a backlog. Skipping before encoding keeps the reference chain intact.
    private static let maxFramesInFlight = 2
    /// While the screen is static, the last frame is re-encoded at this interval. An
    /// unchanged frame encodes to a few hundred bytes, but it keeps the encoder, the
    /// target's decoder and both apps from dropping into low-power states, which is what
    /// made the first moments after an idle period lag.
    private static let keepWarmInterval: TimeInterval = 0.2
    /// If no ack arrives for this long while frames are in flight, assume one was lost
    /// (e.g. the target rebuilt its decoder) and stop waiting for it.
    private static let ackTimeout: TimeInterval = 1

    typealias EncoderFactory = @Sendable (_ width: Int, _ height: Int, _ bitrate: Int) throws -> VideoEncoder

    private let connection: MessageConnection
    private let makeEncoder: EncoderFactory
    private let capturer = ScreenCapturer()
    private let lock = NSLock()
    private var encoder: VideoEncoder
    private var bitrate: Int
    private(set) var size: (width: Int, height: Int)

    /// Frames submitted to the encoder and not yet acknowledged (or dropped).
    private var framesInFlight = 0
    private var lastSubmitTime = CFAbsoluteTimeGetCurrent()
    private var lastPresentationTime = CMTime.invalid
    private var lastAckTime = CFAbsoluteTimeGetCurrent()
    private let timerQueue = DispatchQueue(label: "ScreenRelay.keepWarm", qos: .userInteractive)
    private var keepWarmTimer: DispatchSourceTimer?
    /// Send times of unacknowledged frames, oldest first. Acks arrive in order over TCP.
    private var unacknowledgedSendTimes: [CFAbsoluteTime] = []
    private var smoothedRoundTrip: Double?
    private var smoothedDecode: Double?
    private var smoothedEncode: Double?
    private var capturedSinceLastSample = 0
    private var skippedSinceLastSample = 0
    private var acknowledgedSinceLastSample = 0
    private var lastSampleTime = CFAbsoluteTimeGetCurrent()
    private var lastFormat: FormatDescriptionMessage?
    /// The most recent capture, kept so a keyframe can be produced on demand even
    /// while the screen is static and ScreenCaptureKit isn't delivering frames.
    private var lastPixelBuffer: CVPixelBuffer?

    var onStop: (@Sendable (Error) -> Void)?

    var codec: VideoCodec { lock.withLock { encoder.codec } }
    var modeDescription: String { "\(codec)" }

    init(connection: MessageConnection, width: Int, height: Int, bitrate: Int,
         makeEncoder: @escaping EncoderFactory) throws {
        self.connection = connection
        self.makeEncoder = makeEncoder
        self.encoder = try makeEncoder(width, height, bitrate)
        self.bitrate = bitrate
        self.size = (width, height)

        attach(encoder)
        capturer.onFrame = { [weak self] pixelBuffer, time in
            self?.handleCapturedFrame(pixelBuffer, time: time)
        }
        capturer.onStop = { [weak self] error in
            self?.onStop?(error)
        }
    }

    func start(displayID: CGDirectDisplayID, frameRate: Int, showsCursor: Bool) async throws {
        try await capturer.start(displayID: displayID, pixelWidth: size.width, pixelHeight: size.height,
                                 frameRate: frameRate, showsCursor: showsCursor)
        startKeepWarmTimer()
    }

    func stop() {
        keepWarmTimer?.cancel()
        keepWarmTimer = nil
        capturer.stop()
        capturer.onFrame = nil
        lock.withLock {
            encoder.onEncodedFrame = nil
            encoder.onFrameDropped = nil
        }
    }

    /// Switches capture and encoding to a new size, e.g. after the virtual display's
    /// resolution was changed in System Settings. The new encoder starts with a keyframe
    /// and new parameter sets, which makes the target rebuild its decoder.
    func resize(width: Int, height: Int) async throws {
        guard (width, height) != size else { return }
        let newEncoder = try makeEncoder(width, height, lock.withLock { bitrate })
        attach(newEncoder)
        let oldEncoder = lock.withLock {
            defer {
                encoder = newEncoder
                size = (width, height)
                lastPixelBuffer = nil
            }
            return encoder
        }
        oldEncoder.onEncodedFrame = nil
        oldEncoder.onFrameDropped = nil
        // Frames still inside the old encoder will never be sent or acknowledged.
        lock.withLock {
            framesInFlight = unacknowledgedSendTimes.count
        }
        try await capturer.updateSize(width: width, height: height)
    }

    /// Draws the pointer into the video (fallback when the target can't draw it itself).
    func setShowsCursor(_ showsCursor: Bool) async throws {
        try await capturer.setShowsCursor(showsCursor)
    }

    func setBitrate(_ bitrate: Int) {
        let encoder = lock.withLock {
            self.bitrate = bitrate
            return self.encoder
        }
        encoder.setBitrate(bitrate)
    }

    func requestKeyFrame() {
        let (encoder, pixelBuffer) = lock.withLock { (encoder, lastPixelBuffer) }
        encoder.requestKeyFrame()
        if let pixelBuffer {
            submit(pixelBuffer, to: encoder, presentationTime: CMClockGetTime(CMClockGetHostTimeClock()), force: true)
        }
    }

    /// Called for every `frameAck` from the target.
    func handleFrameAck(decodeMicroseconds: UInt32) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.withLock {
            lastAckTime = now
            framesInFlight = max(0, framesInFlight - 1)
            guard !unacknowledgedSendTimes.isEmpty else { return }
            let roundTrip = now - unacknowledgedSendTimes.removeFirst()
            smoothedRoundTrip = Self.smooth(smoothedRoundTrip, roundTrip)
            if decodeMicroseconds > 0 {
                smoothedDecode = Self.smooth(smoothedDecode, Double(decodeMicroseconds) / 1_000_000)
            }
            acknowledgedSinceLastSample += 1
        }
    }

    /// Returns statistics since the previous call.
    func sampleStatistics() -> StreamStatistics {
        let now = CFAbsoluteTimeGetCurrent()
        return lock.withLock {
            let elapsed = max(now - lastSampleTime, 0.001)
            let stats = StreamStatistics(
                capturedPerSecond: Double(capturedSinceLastSample) / elapsed,
                skippedPerSecond: Double(skippedSinceLastSample) / elapsed,
                shownPerSecond: Double(acknowledgedSinceLastSample) / elapsed,
                encodeMilliseconds: smoothedEncode.map { $0 * 1000 },
                decodeMilliseconds: smoothedDecode.map { $0 * 1000 },
                roundTripMilliseconds: smoothedRoundTrip.map { $0 * 1000 },
                megabitsPerSecond: nil
            )
            capturedSinceLastSample = 0
            skippedSinceLastSample = 0
            acknowledgedSinceLastSample = 0
            lastSampleTime = now
            return stats
        }
    }

    // MARK: - Pipeline

    private func attach(_ encoder: VideoEncoder) {
        encoder.onEncodedFrame = { [weak self, weak encoder] frame in
            guard let self, let encoder else { return }
            // Drop output from an encoder that was replaced by `resize` mid-frame.
            guard self.lock.withLock({ self.encoder === encoder }) else { return }
            self.send(frame)
        }
        encoder.onFrameDropped = { [weak self, weak encoder] in
            guard let self, let encoder else { return }
            self.lock.withLock {
                if self.encoder === encoder { self.framesInFlight = max(0, self.framesInFlight - 1) }
            }
        }
    }

    /// Hands a frame to the encoder if the pipeline has room (or `force` is set).
    private func submit(_ pixelBuffer: CVPixelBuffer, to encoder: VideoEncoder, presentationTime: CMTime, force: Bool = false) {
        let time: CMTime? = lock.withLock {
            guard force || framesInFlight < Self.maxFramesInFlight else { return nil }
            framesInFlight += 1
            lastSubmitTime = CFAbsoluteTimeGetCurrent()
            // Keep-warm and keyframe repeats use "now", while captures carry their capture
            // time, so the two can interleave out of order; encoders need increasing times.
            var time = presentationTime
            if lastPresentationTime.isValid, time <= lastPresentationTime {
                time = lastPresentationTime + CMTime(value: 1, timescale: 1_000_000)
            }
            lastPresentationTime = time
            return time
        }
        if let time {
            encoder.encode(pixelBuffer, presentationTime: time)
        }
    }

    private func startKeepWarmTimer() {
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + Self.keepWarmInterval, repeating: Self.keepWarmInterval)
        timer.setEventHandler { [weak self] in self?.keepWarm() }
        timer.resume()
        keepWarmTimer = timer
    }

    private func keepWarm() {
        let now = CFAbsoluteTimeGetCurrent()
        let work: (VideoEncoder, CVPixelBuffer)? = lock.withLock {
            // Watchdog: never stall forever waiting for an ack that won't come.
            if framesInFlight > 0, now - max(lastAckTime, lastSubmitTime) > Self.ackTimeout {
                print("[Host] No ack for \(framesInFlight) frame(s), resetting flow control")
                framesInFlight = 0
                unacknowledgedSendTimes.removeAll()
            }
            guard framesInFlight == 0, now - lastSubmitTime >= Self.keepWarmInterval,
                  let lastPixelBuffer else { return nil }
            return (encoder, lastPixelBuffer)
        }
        if let (encoder, pixelBuffer) = work {
            submit(pixelBuffer, to: encoder, presentationTime: CMClockGetTime(CMClockGetHostTimeClock()))
        }
    }

    private func handleCapturedFrame(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        let encoder: VideoEncoder? = lock.withLock {
            capturedSinceLastSample += 1
            // Frames captured at the old size right after a resize are ignored.
            guard CVPixelBufferGetWidth(pixelBuffer) == size.width,
                  CVPixelBufferGetHeight(pixelBuffer) == size.height else { return nil }
            lastPixelBuffer = pixelBuffer
            guard framesInFlight < Self.maxFramesInFlight else {
                skippedSinceLastSample += 1
                return nil
            }
            return self.encoder
        }
        if let encoder {
            submit(pixelBuffer, to: encoder, presentationTime: time)
        }
    }

    private func send(_ frame: VideoEncoder.EncodedFrame) {
        if let format = frame.format {
            let changed = lock.withLock {
                defer { lastFormat = format }
                return lastFormat != format
            }
            if changed {
                connection.send(.formatDescription, payload: format.encoded())
            }
        }

        var payload = Data(capacity: frame.data.count + 1)
        payload.append(frame.isKeyFrame ? VideoFrameFlags.keyFrame.rawValue : 0)
        payload.append(frame.data)

        lock.withLock {
            unacknowledgedSendTimes.append(CFAbsoluteTimeGetCurrent())
            smoothedEncode = Self.smooth(smoothedEncode, frame.encodeDuration)
        }
        connection.send(.videoFrame, payload: payload)
    }

    private static func smooth(_ average: Double?, _ sample: Double) -> Double {
        average.map { $0 * 0.9 + sample * 0.1 } ?? sample
    }
}
