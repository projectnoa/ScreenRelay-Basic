//
//  StreamRenderer.swift
//  ScreenRelay
//
//  Decodes received NAL units with VideoToolbox and shows the newest decoded
//  frame by handing its IOSurface straight to a CALayer.
//
//  This deliberately avoids AVSampleBufferDisplayLayer: that layer queues frames
//  internally, so when the decoder can't keep up (5K HEVC on a 2017 iMac), every
//  frame waits behind the backlog. Here nothing queues: each frame is acknowledged
//  only after it's decoded, so the host never sends faster than this Mac decodes,
//  and only the latest decoded frame is ever put on screen.
//

import Foundation
import CoreMedia
import CoreVideo
import QuartzCore
import VideoToolbox

nonisolated final class StreamRenderer: @unchecked Sendable {
    /// Layer whose contents are replaced with every decoded frame.
    let layer: CALayer

    private let lock = NSLock()
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    /// Delta frames are useless until a keyframe has been decoded.
    private var awaitingKeyFrame = true
    /// Newest decoded frame not yet shown, and whether a main-thread update is queued.
    private var pendingImage: CVPixelBuffer?
    private var displayScheduled = false

    /// Called when the decoder needs a keyframe to recover.
    var onKeyFrameNeeded: (@Sendable () -> Void)?
    /// Called exactly once per `videoFrame` payload, once it has been decoded (or
    /// discarded), with the decode time in microseconds (0 if it wasn't decoded).
    var onFrameFinished: (@Sendable (UInt32) -> Void)?

    @MainActor
    init(layer: CALayer) {
        self.layer = layer
        layer.contentsGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    @MainActor
    func reset() {
        let oldSession = lock.withLock {
            defer {
                session = nil
                formatDescription = nil
                awaitingKeyFrame = true
                pendingImage = nil
            }
            return session
        }
        if let oldSession {
            VTDecompressionSessionWaitForAsynchronousFrames(oldSession)
            VTDecompressionSessionInvalidate(oldSession)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = nil
        CATransaction.commit()
    }

    func updateFormat(_ message: FormatDescriptionMessage) {
        guard let description = Self.makeFormatDescription(message) else {
            print("[StreamRenderer] Invalid parameter sets")
            onKeyFrameNeeded?()
            return
        }
        lock.withLock { formatDescription = description }
    }

    /// Called on the network queue with a `videoFrame` payload.
    func enqueueFrame(_ payload: Data) {
        let finished = FrameCompletion(onFrameFinished)

        var reader = ByteReader(payload)
        guard let rawFlags = reader.readUInt8() else { return finished(0) }
        let isKeyFrame = VideoFrameFlags(rawValue: rawFlags).contains(.keyFrame)

        let format: CMVideoFormatDescription? = lock.withLock {
            if isKeyFrame { awaitingKeyFrame = false }
            return awaitingKeyFrame ? nil : formatDescription
        }
        guard let format,
              let session = decompressionSession(for: format),
              let sampleBuffer = Self.makeSampleBuffer(reader.remaining, format: format) else {
            return finished(0)
        }

        let start = CFAbsoluteTimeGetCurrent()
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            // No `_1xRealTimePlayback`: that hint lets the decoder run slower to save power,
            // whereas each frame here should be ready as soon as possible.
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            let micros = UInt32(min(max((CFAbsoluteTimeGetCurrent() - start) * 1_000_000, 0), Double(UInt32.max)))
            defer { finished(micros) }
            guard let self else { return }
            guard status == noErr, let imageBuffer else {
                print("[StreamRenderer] Decode failed: \(status)")
                self.recoverFromDecoderFailure()
                return
            }
            self.display(imageBuffer)
        }
        if status != noErr {
            print("[StreamRenderer] Couldn't submit frame: \(status)")
            recoverFromDecoderFailure()
            finished(0)
        }
    }

    // MARK: - Decoding

    /// Returns a session for `format`, recreating it when the stream's format changes
    /// in a way the current session can't handle (e.g. a new resolution).
    private func decompressionSession(for format: CMVideoFormatDescription) -> VTDecompressionSession? {
        lock.lock()
        defer { lock.unlock() }
        if let session, VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: format) {
            return session
        }
        if let session {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }

        let decoderSpecification: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
        ]
        // Keep the decoder's native 4:2:0 output (no conversion pass) and make it
        // IOSurface-backed so Core Animation can composite it without a copy.
        let imageAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: decoderSpecification as CFDictionary,
            imageBufferAttributes: imageAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &newSession
        )
        guard status == noErr, let newSession else {
            print("[StreamRenderer] Couldn't create decoder: \(status)")
            return nil
        }
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        let valueOut = UnsafeMutablePointer<Unmanaged<CFTypeRef>?>.allocate(capacity: 1)
        valueOut.initialize(to: nil)
        VTSessionCopyProperty(newSession, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                              allocator: nil, valueOut: valueOut)
        let usingHardware = valueOut.pointee?.takeRetainedValue() as? Bool ?? false
        valueOut.deallocate()
        print("[StreamRenderer] Decoder ready, hardware: \(usingHardware)")
        session = newSession
        return newSession
    }

    private func recoverFromDecoderFailure() {
        lock.withLock { awaitingKeyFrame = true }
        onKeyFrameNeeded?()
    }

    // MARK: - Display

    /// Latest frame wins: if the main thread hasn't shown the previous frame yet,
    /// it's simply replaced, so a busy main thread never builds a backlog either.
    private func display(_ imageBuffer: CVImageBuffer) {
        let shouldSchedule = lock.withLock {
            pendingImage = imageBuffer
            defer { displayScheduled = true }
            return !displayScheduled
        }
        guard shouldSchedule else { return }
        DispatchQueue.main.async { [self] in
            let image = lock.withLock {
                defer {
                    pendingImage = nil
                    displayScheduled = false
                }
                return pendingImage
            }
            guard let image, let surface = CVPixelBufferGetIOSurface(image)?.takeUnretainedValue() else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = surface
            CATransaction.commit()
        }
    }

    // MARK: - CoreMedia plumbing

    private static func makeFormatDescription(_ message: FormatDescriptionMessage) -> CMVideoFormatDescription? {
        let sets = message.parameterSets
        guard !sets.isEmpty else { return nil }

        // CoreMedia wants stable pointers to every parameter set at once, so copy them out.
        let buffers = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(set.count, 1))
            set.copyBytes(to: buffer, count: set.count)
            return buffer
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)

        var description: CMFormatDescription?
        let status: OSStatus = switch message.codec {
        case .hevc:
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: Int32(message.nalUnitHeaderLength),
                extensions: nil, formatDescriptionOut: &description)
        case .h264:
            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: Int32(message.nalUnitHeaderLength),
                formatDescriptionOut: &description)
        }
        return status == noErr ? description : nil
    }

    private static func makeSampleBuffer(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr,
              let blockBuffer else { return nil }

        let copyStatus = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = data.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer) == noErr else { return nil }
        return sampleBuffer
    }
}

/// Guarantees a frame is reported finished exactly once, whichever path completes it.
nonisolated private final class FrameCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (UInt32) -> Void)?

    init(_ handler: (@Sendable (UInt32) -> Void)?) {
        self.handler = handler
    }

    func callAsFunction(_ decodeMicroseconds: UInt32) {
        let handler = lock.withLock {
            defer { self.handler = nil }
            return self.handler
        }
        handler?(decodeMicroseconds)
    }
}
