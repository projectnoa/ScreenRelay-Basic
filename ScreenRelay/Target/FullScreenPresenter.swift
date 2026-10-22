//
//  FullScreenPresenter.swift
//  ScreenRelay
//
//  Shows the stream in a regular window that enters native full screen (its own
//  Space), so the iMac's desktop stays reachable with its own mouse and keyboard:
//  switch Spaces, press Esc to leave full screen, ⌘M to minimize. The cursor hides
//  while it rests over the stream and reappears as soon as the mouse moves.
//

import AppKit
import QuartzCore

final class FullScreenPresenter: NSObject, NSWindowDelegate {
    /// Seconds of stillness over the stream before the cursor hides.
    private static let cursorIdleDelay: TimeInterval = 2

    private var window: StreamWindow?
    private var activity: NSObjectProtocol?
    private var cursorTimer: Timer?
    private var lastMouseLocation = NSPoint.zero
    private var lastMouseMove = Date()
    private var cursorHidden = false
    private var onClose: (() -> Void)?

    var isPresented: Bool { window != nil }

    /// Hides the cursor after it rests over the stream. Turned off while the host's
    /// pointer is being relayed, since the cursor then mirrors the host instead.
    var autoHidesCursor = true

    /// True when the stream window is what the user is looking at, i.e. it's safe to move
    /// this Mac's cursor around on the host's behalf.
    var isStreamFrontmost: Bool {
        guard let window else { return false }
        return NSApp.isActive && window.isKeyWindow && window.isVisible
            && !window.isMiniaturized && window.isOnActiveSpace
    }

    /// Where a picture of the given aspect ratio is drawn, in screen coordinates
    /// (AppKit's, origin at the bottom left of the main display).
    func videoRect(aspectRatio: CGFloat) -> NSRect? {
        guard let window, let view = window.contentView, aspectRatio > 0 else { return nil }
        let bounds = view.bounds
        var size = bounds.size
        if size.width / size.height > aspectRatio {
            size.width = size.height * aspectRatio
        } else {
            size.height = size.width / aspectRatio
        }
        let inView = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                            width: size.width, height: size.height)
        return window.convertToScreen(view.convert(inView, to: nil))
    }

    /// The cursor shown while the pointer is over the stream.
    func setStreamCursor(_ cursor: NSCursor) {
        guard let view = window?.contentView as? VideoLayerView, view.cursor !== cursor else { return }
        view.cursor = cursor
        window?.invalidateCursorRects(for: view)
    }

    /// - Parameter onClose: Called when the user closes the stream window, which ends the session.
    func present(layer: CALayer, on screen: NSScreen, title: String, onClose: @escaping () -> Void) {
        guard window == nil else { return }
        self.onClose = onClose

        // Start as a large window on the target's screen; full screen takes it from there.
        let frame = screen.visibleFrame.insetBy(dx: screen.visibleFrame.width * 0.1, dy: screen.visibleFrame.height * 0.1)
        let window = StreamWindow(contentRect: frame,
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false, screen: screen)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.contentAspectRatio = screen.frame.size
        window.contentView = VideoLayerView(videoLayer: layer)
        window.delegate = self

        // ScreenRelay normally lives only in the menu bar; while streaming it behaves like a
        // regular app so the full-screen window gets its own Space, Dock icon and ⌘-Tab entry.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
        self.window = window

        setKeepsDisplayAwake(true)
        startCursorAutoHide()
    }

    /// While on, the panel and the Mac stay awake for the session even while another Space
    /// is showing, and timers and I/O keep full precision (no App Nap). Turned off while the
    /// host sleeps, so this Mac's own energy settings apply.
    func setKeepsDisplayAwake(_ keepAwake: Bool) {
        if keepAwake, activity == nil, window != nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                reason: "Acting as an external display"
            )
        } else if !keepAwake, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    /// Brings the stream back after it was minimized or left on another Space.
    func show() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        guard let window else { return }
        self.window = nil
        onClose = nil
        window.delegate = nil
        window.orderOut(nil)
        window.close()
        stopCursorAutoHide()
        setKeepsDisplayAwake(false)
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Closing the stream window means "stop being a display".
        let onClose = self.onClose
        DispatchQueue.main.async { onClose?() }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        window?.finishPendingMiniaturize()
    }

    // MARK: - Cursor

    /// Polls the mouse position: when it has rested over the stream for a moment the
    /// cursor is hidden until the next movement, which AppKit then reveals by itself.
    private func startCursorAutoHide() {
        lastMouseLocation = NSEvent.mouseLocation
        lastMouseMove = Date()
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCursor() }
        }
    }

    private func stopCursorAutoHide() {
        cursorTimer?.invalidate()
        cursorTimer = nil
        cursorHidden = false
        NSCursor.setHiddenUntilMouseMoves(false)
    }

    private func updateCursor() {
        let location = NSEvent.mouseLocation
        if location != lastMouseLocation {
            lastMouseLocation = location
            lastMouseMove = Date()
            cursorHidden = false
            return
        }
        guard autoHidesCursor, !cursorHidden, let window, window.isKeyWindow, NSApp.isActive,
              window.frame.contains(location),
              Date().timeIntervalSince(lastMouseMove) >= Self.cursorIdleDelay else { return }
        NSCursor.setHiddenUntilMouseMoves(true)
        cursorHidden = true
    }
}

private final class StreamWindow: NSWindow {
    private var miniaturizeAfterFullScreen = false

    private var isFullScreen: Bool { styleMask.contains(.fullScreen) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, isFullScreen { // Esc leaves full screen; the stream keeps running.
            toggleFullScreen(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    /// Full-screen windows can't be minimized, so ⌘M first leaves full screen.
    override func performMiniaturize(_ sender: Any?) {
        if isFullScreen {
            miniaturizeAfterFullScreen = true
            toggleFullScreen(nil)
        } else {
            super.performMiniaturize(sender)
        }
    }

    func finishPendingMiniaturize() {
        guard miniaturizeAfterFullScreen else { return }
        miniaturizeAfterFullScreen = false
        miniaturize(nil)
    }
}

/// Hosts the video layer and keeps it sized to the window.
private final class VideoLayerView: NSView {
    private let videoLayer: CALayer
    var cursor: NSCursor?

    init(videoLayer: CALayer) {
        self.videoLayer = videoLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(videoLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        videoLayer.contentsScale = window?.backingScaleFactor ?? 1
    }

    override func resetCursorRects() {
        if let cursor { addCursorRect(bounds, cursor: cursor) }
    }
}
