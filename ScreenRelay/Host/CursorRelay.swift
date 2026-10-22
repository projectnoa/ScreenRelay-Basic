//
//  CursorRelay.swift
//  ScreenRelay
//
//  Sends the host pointer's position (UDP) and shape (TCP) to the target, which moves
//  its own hardware cursor to match. The pointer then responds at the target's refresh
//  rate instead of waiting for video frames to be captured, encoded and decoded.
//

import AppKit
import Network

final class CursorRelay {
    /// Positions are re-sent this often even without movement, so a lost datagram (or
    /// one sent before the target was listening) is corrected quickly.
    private static let heartbeatInterval: TimeInterval = 0.25
    /// The pointer shape is checked this often; shapes change on hover, not per frame.
    private static let shapePollInterval: TimeInterval = 0.1

    private let displayID: CGDirectDisplayID
    private let control: MessageConnection
    private let datagrams: NWConnection
    private var monitors: [Any] = []
    private var timer: Timer?
    private var sequence: UInt32 = 0
    private var lastShapeSignature: Data?
    private var lastShapeCheck = Date.distantPast

    init(displayID: CGDirectDisplayID, targetHost: NWEndpoint.Host, localAddress: String?, control: MessageConnection) {
        self.displayID = displayID
        self.control = control
        let parameters = NWParameters.udp
        parameters.serviceClass = .interactiveVoice
        if let localAddress, let address = IPv4Address(localAddress) {
            // Same reason as the TCP connection: keep link-local traffic on the bridge.
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(address), port: .any)
        }
        guard let port = NWEndpoint.Port(rawValue: RelayProtocol.cursorPort) else { fatalError("invalid cursor port") }
        datagrams = NWConnection(host: targetHost, port: port, using: parameters)
    }

    func start() {
        datagrams.start(queue: DispatchQueue(label: "ScreenRelay.cursor", qos: .userInteractive))
        // Mouse-moved monitors need no Accessibility permission (unlike keyboard monitors).
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            self?.pointerMoved()
        }) {
            monitors.append(global)
        }
        // Global monitors don't see events delivered to this app itself.
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.pointerMoved()
            return event
        }) {
            monitors.append(local)
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sendPosition()
                self?.sendShapeIfChanged(force: false)
            }
        }
        sendShapeIfChanged(force: true)
        sendPosition()
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        timer?.invalidate()
        timer = nil
        datagrams.cancel()
    }

    // MARK: - Position

    private func pointerMoved() {
        sendPosition()
        if Date().timeIntervalSince(lastShapeCheck) >= Self.shapePollInterval {
            sendShapeIfChanged(force: false)
        }
    }

    private func sendPosition() {
        // Quartz global coordinates (top-left origin), the same space as CGDisplayBounds.
        guard let location = CGEvent(source: nil)?.location else { return }
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let visible = bounds.contains(location)
        sequence &+= 1
        let datagram = CursorDatagram(
            sequence: sequence,
            visible: visible,
            x: Float((location.x - bounds.minX) / bounds.width),
            y: Float((location.y - bounds.minY) / bounds.height),
            displayWidth: Float(bounds.width),
            displayHeight: Float(bounds.height)
        )
        datagrams.send(content: datagram.encoded(), completion: .idempotent)
    }

    // MARK: - Shape

    private func sendShapeIfChanged(force: Bool) {
        lastShapeCheck = Date()
        guard let cursor = NSCursor.currentSystem else { return }
        let image = cursor.image
        guard image.size.width > 0, let png = Self.renderPNG(image, scale: 2) else { return }

        var signature = png
        signature.appendBigEndian(Float32(cursor.hotSpot.x).bitPattern)
        signature.appendBigEndian(Float32(cursor.hotSpot.y).bitPattern)
        guard force || signature != lastShapeSignature else { return }
        lastShapeSignature = signature

        let shape = CursorShape(hotSpot: cursor.hotSpot, size: image.size, png: png)
        control.send(.cursorShape, payload: shape.encoded())
    }

    /// Renders the cursor at Retina resolution so it stays crisp on the target.
    private static func renderPNG(_ image: NSImage, scale: CGFloat) -> Data? {
        let width = Int(image.size.width * scale), height = Int(image.size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
