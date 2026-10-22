//
//  ScreenCapturer.swift
//  ScreenRelay
//
//  Captures a single display (the virtual one) with ScreenCaptureKit.
//

import Foundation
import CoreMedia
import CoreVideo
import ScreenCaptureKit

enum ScreenCapturerError: LocalizedError {
    case displayNotFound

    var errorDescription: String? {
        "The virtual display never became available to ScreenCaptureKit. Check Screen Recording permission in System Settings › Privacy & Security."
    }
}

nonisolated final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let sampleQueue = DispatchQueue(label: "ScreenRelay.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var configuration: SCStreamConfiguration?

    /// Called on the capture queue with every new, complete frame.
    var onFrame: (@Sendable (CVPixelBuffer, CMTime) -> Void)?
    /// Called when the system stops the stream (e.g. permission revoked).
    var onStop: (@Sendable (Error) -> Void)?

    /// - Parameter pixelFormat: 4:2:0 for the HEVC encoder, BGRA for the BC7 encoder.
    func start(displayID: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int, frameRate: Int,
               showsCursor: Bool, pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) async throws {
        let display = try await Self.findDisplay(displayID)
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let configuration = SCStreamConfiguration()
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        // Bi-planar 4:2:0 is what the hardware encoder consumes natively, so no conversion is needed.
        configuration.pixelFormat = pixelFormat
        if pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
            configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        }
        configuration.colorSpaceName = CGColorSpace.sRGB
        // Normally the target draws the pointer itself (see CursorRelay); it is only baked
        // into the video as a fallback when cursor datagrams can't reach the target.
        configuration.showsCursor = showsCursor
        // A small pool keeps capture-to-encode latency down; one buffer is held back for
        // on-demand keyframes.
        configuration.queueDepth = 4

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
        self.configuration = configuration
    }

    func setShowsCursor(_ showsCursor: Bool) async throws {
        guard let stream, let configuration, configuration.showsCursor != showsCursor else { return }
        configuration.showsCursor = showsCursor
        try await stream.updateConfiguration(configuration)
    }

    /// Changes the output size of a running capture without restarting it.
    func updateSize(width: Int, height: Int) async throws {
        guard let stream, let configuration else { return }
        configuration.width = width
        configuration.height = height
        try await stream.updateConfiguration(configuration)
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        Task { try? await stream.stopCapture() }
    }

    /// A freshly created virtual display can take a moment to show up in ScreenCaptureKit.
    private static func findDisplay(_ displayID: CGDirectDisplayID) async throws -> SCDisplay {
        for _ in 0..<20 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let display = content.displays.first(where: { $0.displayID == displayID }) {
                return display
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw ScreenCapturerError.displayNotFound
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              // Idle frames mean nothing changed on screen; the target keeps showing the last frame.
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        onFrame?(pixelBuffer, sampleBuffer.presentationTimeStamp)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }
}
