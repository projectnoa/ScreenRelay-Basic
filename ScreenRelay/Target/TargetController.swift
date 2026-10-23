//
//  TargetController.swift
//  ScreenRelay
//
//  Advertises this Mac as a display, accepts a host connection, and presents
//  the incoming stream full screen.
//

import AppKit
import QuartzCore
import Combine
import CryptoKit
import IOKit.pwr_mgt
import Network
import SwiftUI
import VideoToolbox

final class TargetController: ObservableObject {
    enum Phase: Equatable {
        case stopped
        case waiting
        case streaming(from: String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .stopped
    @Published private(set) var localAddresses: [String] = []
    /// Hosts allowed to use this Mac as a display.
    @Published private(set) var pairedHosts: [PairingStore.Peer] = PairingStore.peers()
    /// Accept hosts over Wi‑Fi too (off: Thunderbolt Bridge / Ethernet only).
    @Published var allowWiFi: Bool = UserDefaults.standard.bool(forKey: "target.allowWiFi") {
        didSet { UserDefaults.standard.set(allowWiFi, forKey: "target.allowWiFi") }
    }
    /// Turn the panel off when the host sleeps or drops off the cable.
    @Published var sleepWithHost: Bool = UserDefaults.standard.object(forKey: "target.sleepWithHost") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sleepWithHost, forKey: "target.sleepWithHost") }
    }

    let displayName = Host.current().localizedName ?? "ScreenRelay Display"

    private let networkQueue = DispatchQueue(label: "ScreenRelay.target.network", qos: .userInteractive)
    private let renderer = StreamRenderer(layer: CALayer())
    /// Native-quality BC7 path; used instead of `renderer` when the host streams tiles.
    private let tileRenderer = TileRenderer()
    /// Holds both pictures; only the one the host is currently sending is visible.
    private lazy var videoContainer: CALayer = {
        let container = CALayer()
        container.backgroundColor = CGColor(gray: 0, alpha: 1)
        for layer in [renderer.layer, tileRenderer.layer] {
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            container.addSublayer(layer)
        }
        tileRenderer.layer.isHidden = true
        return container
    }()
    private let presenter = FullScreenPresenter()
    private lazy var cursorController = CursorController(presenter: presenter)
    private var listener: NWListener?
    private var connection: MessageConnection?
    private var pathMonitor: NWPathMonitor?
    private var addressTimer: Timer?

    // The host's sleep state for the current stream (main thread).
    private var hostAsleep = false
    /// The host stopped sending its "awake" heartbeat.
    private var hostSilent = false
    private var hostSendsHeartbeat = false
    private var lastHostAwake: Date?
    private var silenceTimer: Timer?
    private var wiredInterfaceNames: Set<String> = []
    private var wiredAddresses: [String] = []

    // Handshake state for the current connection (main thread).
    /// Opened once the host has authenticated; until then video and control
    /// messages are dropped on the network queue.
    private let gate = AuthGate()
    private var targetNonce = Data()
    private var pairingHost: HandshakeIntro?
    private var pairingCode: String?
    private var pairingAttempts = 0
    private let pairingPrompt = FloatingPrompt()

    // MARK: - Listening

    func start() {
        guard listener == nil else { return }
        startMonitoringInterfaces()
        cursorController.start()

        let listener: NWListener
        do {
            guard let port = NWEndpoint.Port(rawValue: RelayProtocol.defaultPort) else { return }
            listener = try NWListener(using: RelayProtocol.parameters(), on: port)
        } catch {
            phase = .failed("Couldn't listen on port \(RelayProtocol.defaultPort): \(error.localizedDescription)")
            return
        }
        listener.service = makeService()
        listener.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .ready:
                    if case .stopped = self.phase { self.phase = .waiting }
                case let .failed(error):
                    self.listener = nil
                    self.phase = .failed("Listener failed: \(error.localizedDescription)")
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] nwConnection in
            DispatchQueue.main.async {
                self?.accept(nwConnection)
            }
        }
        listener.start(queue: networkQueue)
        self.listener = listener
    }

    func forget(_ host: PairingStore.Peer) {
        PairingStore.remove(host.id)
        pairedHosts = PairingStore.peers()
    }

    func stop() {
        endStream()
        listener?.cancel()
        listener = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        addressTimer?.invalidate()
        addressTimer = nil
        cursorController.stop()
        phase = .stopped
    }

    // MARK: - Advertising wired addresses

    /// Tracks which interfaces are wired so the Bonjour TXT record always lists the
    /// current Thunderbolt Bridge address, even if the cable is plugged in later.
    private func startMonitoringInterfaces() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let wiredNames = Set(path.availableInterfaces
                .filter { $0.type != .wifi && $0.type != .loopback && $0.type != .cellular }
                .map(\.name))
            DispatchQueue.main.async {
                self?.updateAddresses(wiredInterfaceNames: wiredNames)
            }
        }
        monitor.start(queue: networkQueue)
        pathMonitor = monitor
        updateAddresses(wiredInterfaceNames: [])

        // The path monitor doesn't see the Thunderbolt Bridge, so a new bridge address
        // (e.g. picked again after a night of sleep) would otherwise go unadvertised and
        // hosts would keep trying the old one. Re-reading the addresses is cheap.
        addressTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateAddresses(wiredInterfaceNames: self.wiredInterfaceNames)
            }
        }
    }

    private func updateAddresses(wiredInterfaceNames: Set<String>) {
        self.wiredInterfaceNames = wiredInterfaceNames
        let addresses = NetworkAddresses.ipv4Addresses()
        let described = addresses.map { "\($0.address) (\($0.interface))" }
        if described != localAddresses { localAddresses = described }

        // Thunderbolt Bridge first, then any other wired interface (e.g. Ethernet).
        let wired = addresses
            .filter { wiredInterfaceNames.contains($0.interface) || $0.interface.hasPrefix("bridge") }
            .sorted { ($0.interface.hasPrefix("bridge") ? 0 : 1) < ($1.interface.hasPrefix("bridge") ? 0 : 1) }
            .map(\.address)
        guard wired != wiredAddresses else { return }
        wiredAddresses = wired
        listener?.service = makeService()
    }

    private func makeService() -> NWListener.Service {
        var txt = NWTXTRecord()
        txt[RelayProtocol.wiredAddressesTXTKey] = wiredAddresses.joined(separator: ",")
        return NWListener.Service(name: displayName, type: RelayProtocol.serviceType, domain: nil, txtRecord: txt)
    }

    // MARK: - Connection handling

    private func accept(_ nwConnection: NWConnection) {
        // A display has a single source, so a new host replaces the current one.
        endStream()

        let connection = MessageConnection(connection: nwConnection, queue: networkQueue)
        let renderer = self.renderer
        renderer.reset()
        renderer.onKeyFrameNeeded = { [weak connection] in
            connection?.send(.requestKeyFrame)
        }
        // BC7 frames are acknowledged once drawn; one draw may cover several frames.
        let tileRenderer = self.tileRenderer
        tileRenderer.reset()
        tileRenderer.onFramesDrawn = { [weak connection] count, microseconds in
            var payload = Data()
            payload.appendBigEndian(microseconds)
            for _ in 0..<count { connection?.send(.frameAck, payload: payload) }
        }
        // Acknowledge only once a frame is decoded, so the host paces itself to this
        // Mac's decoder rather than to the network.
        renderer.onFrameFinished = { [weak connection] decodeMicroseconds in
            var payload = Data()
            payload.appendBigEndian(decodeMicroseconds)
            connection?.send(.frameAck, payload: payload)
        }

        connection.onStateChange = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .ready:
                DispatchQueue.main.async {
                    guard let self, self.connection === connection else { return }
                    self.beginHandshake(on: connection)
                }
            case .failed:
                // The host vanished without saying goodbye: it most likely slept or was
                // unplugged, so this panel can go dark too.
                DispatchQueue.main.async {
                    guard let self, self.connection === connection else { return }
                    let wasStreaming = self.gate.isOpen
                    self.endStream()
                    if wasStreaming, self.sleepWithHost { DisplayPower.sleepDisplay() }
                }
            case .cancelled:
                DispatchQueue.main.async {
                    guard let self, self.connection === connection else { return }
                    self.endStream()
                }
            default:
                break
            }
        }
        let speedTest = SpeedTestCounter()
        let gate = self.gate
        gate.close()
        connection.onMessage = { [weak self, weak connection] type, payload in
            // Nothing but the handshake is accepted from a host that hasn't authenticated.
            if !gate.isOpen {
                switch type {
                case .authResponse, .pairRequest, .pairCode:
                    DispatchQueue.main.async { [weak self] in self?.handleHandshake(type, payload) }
                default:
                    break
                }
                return
            }
            // Decoding work stays on the network queue, off the main thread.
            switch type {
            case .formatDescription:
                if let message = FormatDescriptionMessage(payload) {
                    renderer.updateFormat(message)
                }
                DispatchQueue.main.async { [weak self] in self?.showPicture(tiles: false) }
            case .canvasFormat:
                tileRenderer.setCanvas(payload)
                DispatchQueue.main.async { [weak self] in self?.showPicture(tiles: true) }
            case .tiles:
                tileRenderer.applyTiles(payload)
            case .frameEnd:
                tileRenderer.frameEnded()
            case .videoFrame:
                renderer.enqueueFrame(payload)
            case .bandwidthProbe:
                speedTest.add(bytes: payload.count)
            case .bandwidthProbeEnd:
                let (bytes, microseconds) = speedTest.finish()
                var result = Data()
                result.appendBigEndian(bytes)
                result.appendBigEndian(microseconds)
                connection?.send(.bandwidthResult, payload: result)
            case .cursorShape:
                DispatchQueue.main.async { [weak self] in
                    self?.cursorController.setShape(payload)
                }
            case .hostSleepState:
                let asleep = payload.first == 1
                DispatchQueue.main.async { [weak self] in self?.hostSleepStateChanged(asleep: asleep) }
            case .hello, .requestKeyFrame, .frameAck, .bandwidthResult, .cursorChannelReady,
                 .authChallenge, .authResponse, .authConfirm, .authFailed, .pairRequest, .pairCode, .pairAccepted:
                break
            }
        }

        self.connection = connection
        connection.start()
    }

    private func beginPresenting(from connection: MessageConnection) {
        let hostName: String
        var hostAddress: String?
        if case let .hostPort(host, _) = connection.connection.currentPath?.remoteEndpoint ?? connection.connection.endpoint {
            hostName = "\(host)"
            hostAddress = CursorController.address(host)
        } else {
            hostName = connection.endpointDescription
        }
        phase = .streaming(from: hostName)

        // The host's pointer arrives over UDP; confirm it so the host leaves it out of the video.
        cursorController.onChannelReady = { [weak connection] in
            connection?.send(.cursorChannelReady)
        }
        cursorController.beginSession(hostAddress: hostAddress)

        // The host is back (e.g. it just woke up): turn this panel on.
        DisplayPower.wakeDisplay()
        hostAsleep = false
        hostSilent = false
        hostSendsHeartbeat = false
        lastHostAwake = nil
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHostSilence() }
        }

        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        tileRenderer.layer.contentsScale = screen.backingScaleFactor
        presenter.present(layer: videoContainer, on: screen, title: "ScreenRelay — \(hostName)") { [weak self] in
            // Closing the stream window ends the session.
            self?.endStream()
        }
    }

    /// Shows the HEVC or the BC7 picture, whichever the host is sending.
    private func showPicture(tiles: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tileRenderer.layer.isHidden = !tiles
        renderer.layer.isHidden = tiles
        CATransaction.commit()
    }

    /// Brings the stream window back after it was minimized or left on another Space.
    func showStream() {
        presenter.show()
    }

    private func endStream() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        gate.close()
        pairingPrompt.dismiss()
        pairingHost = nil
        pairingCode = nil
        connection?.onStateChange = nil
        connection?.onMessage = nil
        connection?.cancel()
        connection = nil
        renderer.onKeyFrameNeeded = nil
        renderer.onFrameFinished = nil
        renderer.reset()
        tileRenderer.onFramesDrawn = nil
        tileRenderer.reset()
        cursorController.onChannelReady = nil
        cursorController.endSession()
        presenter.dismiss()
        if case .streaming = phase {
            phase = listener == nil ? .stopped : .waiting
        }
    }

    // MARK: - Authentication

    private func beginHandshake(on connection: MessageConnection) {
        // Over Wi‑Fi anyone on the network can reach this Mac; by default only the cable counts.
        if !allowWiFi, connection.connection.currentPath?.usesInterfaceType(.wifi) == true {
            print("[Target] Refusing a host connecting over Wi‑Fi")
            connection.send(.authFailed, payload: Data([AuthFailure.wifiNotAllowed.rawValue])) { [weak connection] _ in
                connection?.cancel()
            }
            return
        }
        targetNonce = Handshake.nonce()
        let challenge = HandshakeIntro(id: DeviceIdentity.id, nonce: targetNonce, name: DeviceIdentity.name)
        connection.send(.authChallenge, payload: challenge.encoded())
    }

    private func handleHandshake(_ type: MessageType, _ payload: Data) {
        guard let connection, !gate.isOpen else { return }
        switch type {
        case .authResponse:
            guard let host = HandshakeIntro(payload, hasProof: true), let proof = host.proof else { return }
            guard let key = PairingStore.key(for: host.id) else {
                // Unknown host: it will start pairing on this same connection.
                connection.send(.authFailed, payload: Data([AuthFailure.notPaired.rawValue]))
                return
            }
            let expected = Handshake.hostProof(key: key, targetNonce: targetNonce, hostNonce: host.nonce,
                                               targetID: DeviceIdentity.id, hostID: host.id)
            guard Handshake.matches(proof, expected) else {
                fail(connection, .badProof)
                return
            }
            completeAuthentication(with: key, host: host, on: connection)

        case .pairRequest:
            guard let host = HandshakeIntro(payload, hasProof: false) else { return }
            pairingHost = host
            pairingAttempts = 0
            let code = Handshake.pairingCode()
            pairingCode = code
            pairingPrompt.show(title: "Pair with \(host.name)") {
                PairingCodeView(hostName: host.name, code: code)
            }

        case .pairCode:
            guard let host = pairingHost, let code = pairingCode, payload.count == Handshake.macLength else { return }
            let codeKey = Handshake.codeKey(code: code, targetNonce: targetNonce, hostNonce: host.nonce)
            guard Handshake.matches(payload, Handshake.codeProof(codeKey: codeKey, hostID: host.id)) else {
                pairingAttempts += 1
                if pairingAttempts >= 3 {
                    fail(connection, .tooManyAttempts)
                } else {
                    connection.send(.authFailed, payload: Data([AuthFailure.wrongCode.rawValue]))
                }
                return
            }
            let key = Handshake.newPairingKey()
            guard let sealed = Handshake.wrap(key, with: codeKey) else { return }
            PairingStore.save(key, for: host.id, name: host.name)
            pairedHosts = PairingStore.peers()
            pairingPrompt.dismiss()
            connection.send(.pairAccepted, payload: sealed)
            completeAuthentication(with: key, host: host, on: connection)

        default:
            break
        }
    }

    /// The host proved it's paired: prove the same back, then start being its display.
    private func completeAuthentication(with key: SymmetricKey, host: HandshakeIntro, on connection: MessageConnection) {
        let proof = Handshake.targetProof(key: key, targetNonce: targetNonce, hostNonce: host.nonce,
                                          targetID: DeviceIdentity.id, hostID: host.id)
        connection.send(.authConfirm, payload: proof)
        gate.open()
        pairingHost = nil
        pairingCode = nil
        Self.sendHello(over: connection)
        beginPresenting(from: connection)
    }

    private func fail(_ connection: MessageConnection, _ reason: AuthFailure) {
        print("[Target] Authentication failed: \(reason)")
        pairingPrompt.dismiss()
        connection.send(.authFailed, payload: Data([reason.rawValue])) { [weak connection] _ in
            connection?.cancel()
        }
    }

    // MARK: - Host sleep

    /// After this long without the host's "awake" heartbeat, the panel is no longer held on.
    private static let hostSilenceLimit: TimeInterval = 20

    private func hostSleepStateChanged(asleep: Bool) {
        if asleep {
            hostAsleep = true
            guard sleepWithHost else { return }
            // Let this Mac's own energy settings take over, then turn the panel off now.
            presenter.setKeepsDisplayAwake(false)
            DisplayPower.sleepDisplay()
            return
        }

        // Current hosts repeat "awake" every few seconds while streaming; once two arrive
        // close together, silence means the host is gone. (Older hosts send it only when
        // their screens wake, and are never held to this.)
        let now = Date()
        if let lastHostAwake, now.timeIntervalSince(lastHostAwake) < 15 { hostSendsHeartbeat = true }
        lastHostAwake = now

        // Repeats only confirm the host is still there; the panel is woken (which counts
        // as user activity here) only when the host comes back from sleep or silence.
        guard hostAsleep || hostSilent else { return }
        hostAsleep = false
        hostSilent = false
        if sleepWithHost { DisplayPower.wakeDisplay() }
        presenter.setKeepsDisplayAwake(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.presenter.restoreFullScreenIfNeeded()
        }
    }

    /// A stream whose host has gone quiet (it slept without saying so, or the link stalled
    /// while the connection lingers) stops holding this panel on, so it can't keep a dark
    /// window lit until the screen saver starts.
    private func checkHostSilence() {
        guard hostSendsHeartbeat, !hostAsleep, !hostSilent, let lastHostAwake,
              Date().timeIntervalSince(lastHostAwake) > Self.hostSilenceLimit else { return }
        print("[Target] No word from the host for \(Int(Self.hostSilenceLimit)) s; letting the display sleep normally.")
        hostSilent = true
        presenter.setKeepsDisplayAwake(false)
    }

    // MARK: - Handshake

    /// Tells the host how big this screen is so it can create a matching virtual display.
    private static func sendHello(over connection: MessageConnection) {
        guard let payload = try? JSONEncoder().encode(makeHello()) else { return }
        connection.send(.hello, payload: payload)
    }

    private static func makeHello() -> TargetHello {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let scale = Int(screen?.backingScaleFactor ?? 1)
        let pointSize = screen?.frame.size ?? CGSize(width: 1920, height: 1080)
        let displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let physicalSize = displayID.map { CGDisplayScreenSize($0) } ?? .zero
        // Report the panel itself, not the current "looks like" setting: a More Space mode
        // renders above the panel's resolution (e.g. 5760×3240 on a 5120×2880 iMac), and
        // streaming those extra pixels would only be scaled away again here.
        let native = displayID.flatMap(nativePixelSize)
            ?? (Int(pointSize.width) * scale, Int(pointSize.height) * scale)

        return TargetHello(
            protocolVersion: RelayProtocol.version,
            name: Host.current().localizedName ?? "ScreenRelay Display",
            pixelWidth: native.width,
            pixelHeight: native.height,
            backingScale: scale,
            widthMillimeters: physicalSize.width,
            heightMillimeters: physicalSize.height,
            supportsHEVC: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
            supportsBC7: TileRenderer.isSupported,
            appVersion: AppInfo.versionLabel
        )
    }

    /// The panel's physical resolution, from the display mode IOKit flags as native.
    nonisolated private static func nativePixelSize(_ displayID: CGDirectDisplayID) -> (width: Int, height: Int)? {
        let nativeFlag: UInt32 = 0x0200_0000 // kDisplayModeNativeFlag
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else { return nil }
        return modes
            .filter { $0.ioFlags & nativeFlag != 0 }
            .max { $0.pixelWidth < $1.pixelWidth }
            .map { ($0.pixelWidth, $0.pixelHeight) }
    }
}

/// Lists this Mac's IPv4 addresses so they can be typed into the host if Bonjour isn't available.
enum NetworkAddresses {
    static func ipv4Addresses() -> [(address: String, interface: String)] {
        var addresses: [(address: String, interface: String)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                addresses.append((String(cString: host), String(cString: interface.ifa_name)))
            }
        }
        return addresses
    }
}

/// Counts link-speed-test data as it arrives (on the network queue).
nonisolated final class SpeedTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: UInt64 = 0
    private var firstArrival: CFAbsoluteTime?

    func add(bytes count: Int) {
        lock.withLock {
            if firstArrival == nil { firstArrival = CFAbsoluteTimeGetCurrent() }
            bytes += UInt64(count)
        }
    }

    /// Bytes received and microseconds from the first chunk to now; resets for the next test.
    func finish() -> (UInt64, UInt64) {
        lock.withLock {
            defer {
                bytes = 0
                firstArrival = nil
            }
            let elapsed = firstArrival.map { CFAbsoluteTimeGetCurrent() - $0 } ?? 0
            return (bytes, UInt64(max(elapsed, 0) * 1_000_000))
        }
    }
}

/// Whether the current host has authenticated; read on the network queue.
nonisolated final class AuthGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    var isOpen: Bool { lock.withLock { opened } }
    func open() { lock.withLock { opened = true } }
    func close() { lock.withLock { opened = false } }
}

/// Turning this Mac's panel off and on.
enum DisplayPower {
    /// Turns the display off right away (like the "Turn display off" hot corner). The Mac
    /// stays awake until its own energy settings put it to sleep.
    static func sleepDisplay() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        do { try process.run() } catch { print("[Target] Couldn't turn the display off: \(error)") }
    }

    /// Wakes the display as if the user had touched the keyboard.
    static func wakeDisplay() {
        var assertion: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("ScreenRelay host connected" as CFString, kIOPMUserActiveLocal, &assertion)
    }
}

/// Shown on the display while a host pairs with it.
struct PairingCodeView: View {
    let hostName: String
    let code: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text("\(hostName) wants to use this Mac as a display")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Enter this code on \(hostName):")
                .foregroundStyle(.secondary)
            Text(code.prefix(3) + " " + code.suffix(3))
                .font(.system(size: 44, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}
