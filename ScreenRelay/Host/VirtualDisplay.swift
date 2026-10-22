//
//  VirtualDisplay.swift
//  ScreenRelay
//
//  A software display that macOS treats as a real monitor, so windows can be
//  dragged onto it and it shows up in System Settings › Displays. It exists for
//  as long as this object is alive.
//

import CoreGraphics
import Foundation

enum VirtualDisplayError: LocalizedError {
    case creationFailed
    case settingsRejected
    case neverBecameReady

    var errorDescription: String? {
        switch self {
        case .creationFailed: "macOS refused to create the virtual display."
        case .settingsRejected: "macOS rejected the virtual display's resolution."
        case .neverBecameReady: "The virtual display was created but macOS never brought it online."
        }
    }
}

final class VirtualDisplay {
    let displayID: CGDirectDisplayID
    private let display: CGVirtualDisplay
    private let requestedPixelWidth: Int
    private let requestedPixelHeight: Int
    private let requestedScale: Int

    /// - Parameters:
    ///   - pixelWidth/pixelHeight: Backing resolution, which matches the target's panel.
    ///   - backingScale: 2 for Retina targets, so the display gets a HiDPI mode.
    init(name: String, pixelWidth: Int, pixelHeight: Int, backingScale: Int,
         sizeInMillimeters: CGSize, refreshRate: Double = 60) throws {
        let scale = max(1, backingScale)
        // Modes are given in backing pixels; with hiDPI set, macOS offers each one as a
        // Retina "looks like" size of half that. The panel's native mode comes first so
        // it's the default; the rest are the Larger Text / More Space choices a real
        // display offers. More Space modes render above the panel's resolution, but the
        // host caps what it streams at the panel's size, so only this Mac pays for them.
        let factors = scale > 1 ? [1.0, 0.8, 0.9, 1.125, 1.25] : [1.0]
        let sizes = factors.map { factor -> (width: Int, height: Int) in
            let width = Int((Double(pixelWidth) * factor / 16).rounded()) * 16
            let height = Int((Double(width) * Double(pixelHeight) / Double(pixelWidth) / 2).rounded()) * 2
            return (width, height)
        }

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(sizes.map(\.width).max() ?? pixelWidth)
        descriptor.maxPixelsHigh = UInt32(sizes.map(\.height).max() ?? pixelHeight)
        descriptor.sizeInMillimeters = sizeInMillimeters.width > 0
            ? sizeInMillimeters
            // Fall back to ~110 ppi, which is typical for desktop panels.
            : CGSize(width: Double(pixelWidth) / Double(backingScale) * 0.23,
                     height: Double(pixelHeight) / Double(backingScale) * 0.23)
        // Arbitrary but stable IDs so macOS remembers the arrangement between sessions.
        descriptor.vendorID = 0x5352 // "SR"
        descriptor.productID = 0x0001
        descriptor.serialNum = 0x0001

        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            throw VirtualDisplayError.creationFailed
        }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = scale > 1 ? 1 : 0
        settings.modes = sizes.map {
            CGVirtualDisplayMode(width: UInt32($0.width), height: UInt32($0.height), refreshRate: refreshRate)
        }
        guard display.apply(settings) else {
            throw VirtualDisplayError.settingsRejected
        }

        self.display = display
        self.displayID = display.displayID
        self.requestedPixelWidth = pixelWidth
        self.requestedPixelHeight = pixelHeight
        self.requestedScale = scale
    }

    /// Waits for the window server to bring the display online, switches it to the
    /// target's native mode, and returns the resulting backing pixel size.
    ///
    /// Right after `apply(_:)` the display has no modes yet and reports a provisional
    /// (often zero) size, so nothing may be sized from it until this returns.
    func waitUntilReady(timeout: TimeInterval = 5) async throws -> (width: Int, height: Int) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let mode = CGDisplayCopyDisplayMode(displayID), mode.pixelWidth > 0, mode.pixelHeight > 0 {
                // macOS remembers the mode picked in System Settings for this display (its
                // serial number is stable), so only step in if it came up in a non-Retina mode.
                if requestedScale > 1, mode.pixelWidth == mode.width {
                    selectMode(pixelWidth: requestedPixelWidth, pixelHeight: requestedPixelHeight, scale: requestedScale)
                }
                // Give a mode switch a moment to take effect before reading the final size.
                try await Task.sleep(nanoseconds: 200_000_000)
                let size = pixelSize
                if size.width > 0, size.height > 0 { return size }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw VirtualDisplayError.neverBecameReady
    }

    /// Current backing pixel size of the display (what ScreenCaptureKit should capture).
    var pixelSize: (width: Int, height: Int) {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else {
            return (Int(CGDisplayPixelsWide(displayID)), Int(CGDisplayPixelsHigh(displayID)))
        }
        return (mode.pixelWidth, mode.pixelHeight)
    }

    /// Switches to the mode that renders at the target's native pixel size with the
    /// target's scale factor (e.g. 5120×2880 pixels "looks like" 2560×1440).
    private func selectMode(pixelWidth: Int, pixelHeight: Int, scale: Int) {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else { return }

        let preferred = modes.first {
            $0.pixelWidth == pixelWidth && $0.pixelHeight == pixelHeight && $0.width == pixelWidth / scale
        } ?? modes.first {
            $0.pixelWidth == pixelWidth && $0.pixelHeight == pixelHeight
        }
        guard let preferred, CGDisplayCopyDisplayMode(displayID)?.ioDisplayModeID != preferred.ioDisplayModeID else { return }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        guard CGConfigureDisplayWithDisplayMode(config, displayID, preferred, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            return
        }
        CGCompleteDisplayConfiguration(config, .forSession)
    }
}
