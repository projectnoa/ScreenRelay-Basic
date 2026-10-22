//
//  CursorController.swift
//  ScreenRelay
//
//  Moves this Mac's own (hardware) cursor to wherever the host's pointer is on the
//  streamed display, with the host's pointer shape. The hardware cursor is drawn by
//  the display controller on every refresh, so it never waits for video frames.
//
//  Using this Mac's own mouse takes over: while it moves (and for a moment after), the
//  host's positions are ignored, so the desktop here stays usable.
//

import AppKit
import Network

final class CursorController {
    /// After local mouse input, the host's pointer is ignored for this long.
    private static let localInputGrace: TimeInterval = 2

    private let presenter: FullScreenPresenter
    private let receiveQueue = DispatchQueue(label: "ScreenRelay.cursor.receive", qos: .userInteractive)
    private let lock = NSLock()
    private var listener: NWListener?
    /// Only touched on `receiveQueue`.
    nonisolated(unsafe) private var datagramConnections: [NWConnection] = []

    // Shared with the receive queue (guarded by `lock`).
    nonisolated(unsafe) private var expectedHost: String?
    nonisolated(unsafe) private var lastSequence: UInt32?
    nonisolated(unsafe) private var latest: CursorDatagram?
    nonisolated(unsafe) private var applyScheduled = false
    nonisolated(unsafe) private var announcedReady = false

    // Main thread only.
    private var shape: CursorShape?
    private var cursor: NSCursor = .arrow
    private var cursorScale: CGFloat = 0
    private var hiddenForHost = false
    private var localInputUntil = Date.distantPast
    private var localMonitor: Any?

    /// Called (on the main thread) when the first datagram of a session arrives.
    var onChannelReady: (() -> Void)?

    init(presenter: FullScreenPresenter) {
        self.presenter = presenter
    }

    func start() {
        guard listener == nil, let port = NWEndpoint.Port(rawValue: RelayProtocol.cursorPort) else { return }
        do {
            let listener = try NWListener(using: .udp, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: receiveQueue)
            self.listener = listener
        } catch {
            print("[Cursor] Couldn't listen on UDP \(RelayProtocol.cursorPort): \(error)")
        }
    }

    func stop() {
        endSession()
        listener?.cancel()
        listener = nil
    }

    /// Accepts datagrams only from the host of the current stream.
    func beginSession(hostAddress: String?) {
        lock.withLock {
            expectedHost = hostAddress
            lastSequence = nil
            latest = nil
            announcedReady = false
        }
        shape = nil
        cursor = .arrow
        cursorScale = 0
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                       .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            // Warping the cursor generates no events, so anything seen here is this Mac's mouse.
            self?.localInputUntil = Date().addingTimeInterval(Self.localInputGrace)
            if self?.hiddenForHost == true {
                self?.hiddenForHost = false
                NSCursor.setHiddenUntilMouseMoves(false)
            }
            return event
        }
    }

    func endSession() {
        lock.withLock {
            expectedHost = nil
            latest = nil
        }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        if hiddenForHost {
            hiddenForHost = false
            NSCursor.setHiddenUntilMouseMoves(false)
        }
        presenter.autoHidesCursor = true
        receiveQueue.async { [self] in
            datagramConnections.forEach { $0.cancel() }
            datagramConnections.removeAll()
        }
    }

    /// Called with a `cursorShape` payload.
    func setShape(_ payload: Data) {
        guard let shape = CursorShape(payload) else { return }
        self.shape = shape
        cursorScale = 0 // rebuild at the current scale on the next update
    }

    // MARK: - Receiving (on `receiveQueue`)

    nonisolated private func accept(_ connection: NWConnection) {
        datagramConnections.append(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .cancelled = state, let connection {
                self?.datagramConnections.removeAll { $0 === connection }
            }
        }
        connection.start(queue: receiveQueue)
        receive(on: connection)
    }

    nonisolated private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }
            if let data, let datagram = CursorDatagram(data) {
                self.handle(datagram, from: connection.endpoint)
            }
            if error == nil {
                self.receive(on: connection)
            }
        }
    }

    nonisolated private func handle(_ datagram: CursorDatagram, from endpoint: NWEndpoint) {
        guard case let .hostPort(host, _) = endpoint else { return }
        let source = Self.address(host)
        let (accepted, announce, schedule) = lock.withLock { () -> (Bool, Bool, Bool) in
            guard let expectedHost, source == expectedHost else { return (false, false, false) }
            // Drop datagrams that arrive out of order (wrap-around safe).
            if let lastSequence, Int32(bitPattern: datagram.sequence &- lastSequence) <= 0 {
                return (false, false, false)
            }
            lastSequence = datagram.sequence
            latest = datagram
            let announce = !announcedReady
            announcedReady = true
            let schedule = !applyScheduled
            applyScheduled = true
            return (true, announce, schedule)
        }
        guard accepted else { return }
        if announce {
            DispatchQueue.main.async { [weak self] in self?.onChannelReady?() }
        }
        if schedule {
            // Latest position wins: positions that arrive while one is pending replace it.
            DispatchQueue.main.async { [weak self] in self?.applyLatest() }
        }
    }

    // MARK: - Applying (main thread)

    private func applyLatest() {
        let datagram: CursorDatagram? = lock.withLock {
            applyScheduled = false
            return latest
        }
        guard let datagram else { return }
        presenter.autoHidesCursor = false

        // Leave the cursor alone while this Mac is being used directly, or the stream
        // isn't on screen (e.g. the desktop Space is showing).
        guard presenter.isStreamFrontmost, Date() >= localInputUntil else { return }

        guard datagram.visible else {
            // The host's pointer is on one of its other displays.
            if !hiddenForHost {
                hiddenForHost = true
                NSCursor.setHiddenUntilMouseMoves(true)
            }
            return
        }
        guard datagram.displayWidth > 0, datagram.displayHeight > 0,
              let rect = presenter.videoRect(aspectRatio: CGFloat(datagram.displayWidth / datagram.displayHeight)),
              let mainScreen = NSScreen.screens.first else { return }

        // Normalized (top-left origin) → AppKit screen point → Quartz global point.
        let point = NSPoint(x: rect.minX + CGFloat(datagram.x) * rect.width,
                            y: rect.maxY - CGFloat(datagram.y) * rect.height)
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: mainScreen.frame.height - point.y))
        // Re-pair the mouse with the cursor immediately; warping can briefly detach them.
        CGAssociateMouseAndMouseCursorPosition(1)

        // Match the host's pointer size to the picture, which may be scaled to fit.
        updateCursor(scale: rect.width / CGFloat(datagram.displayWidth))
        presenter.setStreamCursor(cursor)
        cursor.set()

        if hiddenForHost {
            hiddenForHost = false
            NSCursor.setHiddenUntilMouseMoves(false)
        }
    }

    private func updateCursor(scale: CGFloat) {
        guard let shape, abs(scale - cursorScale) > 0.01, let image = NSImage(data: shape.png) else { return }
        cursorScale = scale
        image.size = NSSize(width: shape.size.width * scale, height: shape.size.height * scale)
        cursor = NSCursor(image: image, hotSpot: NSPoint(x: shape.hotSpot.x * scale, y: shape.hotSpot.y * scale))
    }

    /// Normalizes an address for comparison (e.g. drops an IPv6 scope or mapped prefix).
    nonisolated static func address(_ host: NWEndpoint.Host) -> String {
        switch host {
        case let .ipv4(address): "\(address)".components(separatedBy: "%").first ?? "\(address)"
        case let .ipv6(address):
            address.asIPv4.map { "\($0)" } ?? ("\(address)".components(separatedBy: "%").first ?? "\(address)")
        case let .name(name, _): name
        @unknown default: "\(host)"
        }
    }
}
