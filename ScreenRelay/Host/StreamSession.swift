//
//  StreamSession.swift
//  ScreenRelay
//
//  What the host controller needs from a video pipeline, so it can run either the
//  HEVC pipeline (any link) or the native-quality BC7 tile pipeline (fast wired links).
//

import Foundation
import CoreGraphics

nonisolated struct StreamStatistics {
    /// New frames ScreenCaptureKit produced per second (only when the screen changes).
    var capturedPerSecond: Double
    /// Captured frames per second that were skipped because the target was still busy.
    var skippedPerSecond: Double
    /// Frames the target finished per second.
    var shownPerSecond: Double
    var encodeMilliseconds: Double?
    /// Decode (HEVC) or upload-and-draw (BC7) time on the target.
    var decodeMilliseconds: Double?
    /// Smoothed time from handing a frame to the network until the target finished it.
    var roundTripMilliseconds: Double?
    /// Video data actually sent, when the pipeline tracks it.
    var megabitsPerSecond: Double?
}

nonisolated protocol StreamSession: AnyObject, Sendable {
    var size: (width: Int, height: Int) { get }
    /// e.g. "HEVC" or "BC7 (native)".
    var modeDescription: String { get }
    var onStop: (@Sendable (Error) -> Void)? { get set }

    func start(displayID: CGDirectDisplayID, frameRate: Int, showsCursor: Bool) async throws
    func stop()
    func resize(width: Int, height: Int) async throws
    func setBitrate(_ bitrate: Int)
    func setShowsCursor(_ showsCursor: Bool) async throws
    /// Resend a complete picture (after a decoder reset, reconnect, …).
    func requestKeyFrame()
    func handleFrameAck(decodeMicroseconds: UInt32)
    func sampleStatistics() -> StreamStatistics
}
