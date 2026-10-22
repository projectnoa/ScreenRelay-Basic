//
//  VideoEncoder.swift
//  ScreenRelay
//
//  Hardware H.264/HEVC encoder tuned for low-latency desktop streaming.
//

import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

enum VideoEncoderError: LocalizedError {
    case sessionCreationFailed(VideoCodec, OSStatus)

    var errorDescription: String? {
        switch self {
        case let .sessionCreationFailed(codec, status):
            "Couldn't create a hardware \(codec) encoder (error \(status))."
        }
    }
}

nonisolated final class VideoEncoder: @unchecked Sendable {
    struct EncodedFrame {
        /// Length-prefixed (AVCC/HVCC) NAL units.
        let data: Data
        let isKeyFrame: Bool
        /// Present on keyframes so the receiver can (re)build its decoder.
        let format: FormatDescriptionMessage?
        /// Seconds from submitting the frame to receiving the encoded output.
        let encodeDuration: CFAbsoluteTime
    }

    let codec: VideoCodec
    private let session: VTCompressionSession
    private let lock = NSLock()
    private var forceKeyFrame = true

    /// Called on a VideoToolbox thread for every encoded frame.
    var onEncodedFrame: (@Sendable (EncodedFrame) -> Void)?
    /// Called when a submitted frame produced no output (dropped or failed), so callers
    /// that count frames in flight can release it.
    var onFrameDropped: (@Sendable () -> Void)?

    init(codec: VideoCodec, width: Int, height: Int, frameRate: Int, bitrate: Int) throws {
        self.codec = codec

        // Low-latency rate control is deliberately not enabled: measured on Apple silicon it
        // made each frame take ~60% longer to encode with HEVC and ~7% longer with H.264.
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codec.codecType,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw VideoEncoderError.sessionCreationFailed(codec, status)
        }
        self.session = session

        let profile = codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: profile,
            kVTCompressionPropertyKey_ExpectedFrameRate: frameRate,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            // Cap bursts at 1.5× the average over one second (value is in bytes).
            kVTCompressionPropertyKey_DataRateLimits: [bitrate * 3 / 16, 1] as CFArray,
            // Keyframes are requested on demand, so a periodic one is only a safety net.
            kVTCompressionPropertyKey_MaxKeyFrameInterval: frameRate * 10,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 10,
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: true,
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        for (key, value) in properties {
            let result = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
            if result != noErr {
                print("[VideoEncoder] \(key) not supported (\(result))")
            }
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    func requestKeyFrame() {
        lock.withLock { forceKeyFrame = true }
    }

    /// Changes the target bitrate of a running encoder.
    func setBitrate(_ bitrate: Int) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [bitrate * 3 / 16, 1] as CFArray)
    }

    func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        let keyFrame = lock.withLock {
            defer { forceKeyFrame = false }
            return forceKeyFrame
        }
        let frameProperties = keyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let start = CFAbsoluteTimeGetCurrent()
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: .invalid,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self else { return }
            guard status == noErr, let sampleBuffer,
                  self.handle(sampleBuffer, encodeDuration: CFAbsoluteTimeGetCurrent() - start) else {
                if status != noErr { print("[VideoEncoder] Encode failed: \(status)") }
                if keyFrame || status != noErr { self.requestKeyFrame() }
                self.onFrameDropped?()
                return
            }
        }
        if status != noErr {
            print("[VideoEncoder] Couldn't submit frame: \(status)")
            if keyFrame { requestKeyFrame() }
            onFrameDropped?()
        }
    }

    /// Returns false if the sample buffer carried no frame.
    private func handle(_ sampleBuffer: CMSampleBuffer, encodeDuration: CFAbsoluteTime) -> Bool {
        guard let blockBuffer = sampleBuffer.dataBuffer else { return false }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKeyFrame = !notSync

        let length = CMBlockBufferGetDataLength(blockBuffer)
        var data = Data(count: length)
        let copyStatus = data.withUnsafeMutableBytes { buffer in
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: buffer.baseAddress!)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return false }

        let format = isKeyFrame ? sampleBuffer.formatDescription.flatMap(makeFormatMessage) : nil
        onEncodedFrame?(EncodedFrame(data: data, isKeyFrame: isKeyFrame, format: format, encodeDuration: encodeDuration))
        return true
    }

    /// Extracts the parameter sets (VPS/SPS/PPS) from the encoder's format description.
    private func makeFormatMessage(_ description: CMFormatDescription) -> FormatDescriptionMessage? {
        var count = 0
        var nalHeaderLength: Int32 = 0
        let getter = codec == .hevc
            ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex
            : CMVideoFormatDescriptionGetH264ParameterSetAtIndex

        guard getter(description, 0, nil, nil, &count, &nalHeaderLength) == noErr else { return nil }

        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard getter(description, index, &pointer, &size, nil, nil) == noErr, let pointer else { return nil }
            sets.append(Data(bytes: pointer, count: size))
        }
        return FormatDescriptionMessage(codec: codec, nalUnitHeaderLength: Int(nalHeaderLength), parameterSets: sets)
    }
}
