//
//  HostController.swift
//  ScreenRelay
//
//  Discovers targets, connects to one, and drives the virtual display + stream.
//

import AppKit
import Foundation
import Network
import CoreGraphics
import Combine
import CryptoKit
import SwiftUI

struct DiscoveredTarget: Identifiable, Hashable {
    let name: String
    let endpoint: NWEndpoint
    /// Non‑Wi‑Fi IPv4 addresses the target advertises, Thunderbolt Bridge first.
    var wiredAddresses: [String] = []
    var id: String { name }
}

final class HostController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting(String)
        /// Waiting for the user to type the code the display shows.
        case pairing(String)
        case streaming(String)
        case failed(String)
    }

    static let frameRate = 60
    static let connectTimeout: TimeInterval = 10

    @Published private(set) var targets: [DiscoveredTarget] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var streamDescription = ""
    @Published private(set) var hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()

    /// Applied immediately, including to a running stream.
    @Published var bitrateMbps: Double = UserDefaults.standard.object(forKey: "host.bitrateMbps") as? Double ?? 20 {
        didSet {
            UserDefaults.standard.set(bitrateMbps, forKey: "host.bitrateMbps")
            session?.setBitrate(Int(bitrateMbps * 1_000_000))
            updateStreamDescription()
        }
    }
    /// Fraction of the virtual display's pixel size that is actually encoded and sent.
    /// The desktop layout is unaffected; the target scales the video up to fill its panel.
    /// Lower values trade sharpness for a lighter decode on older targets.
    @Published var streamScale: Double = UserDefaults.standard.object(forKey: "host.streamScale") as? Double ?? 1 {
        didSet {
            UserDefaults.standard.set(streamScale, forKey: "host.streamScale")
            applyStreamSize()
        }
    }
    /// Connect to the last display by itself: at launch, after waking, and when it reappears.
    @Published var autoConnect: Bool = UserDefaults.standard.object(forKey: "host.autoConnect") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoConnect, forKey: "host.autoConnect")
            if autoConnect { userDisconnected = false; reconnectIfNeeded() }
        }
    }
    @Published private(set) var lastTargetName: String? = UserDefaults.standard.string(forKey: "host.lastTarget") {
        didSet { UserDefaults.standard.set(lastTargetName, forKey: "host.lastTarget") }
    }
    /// Displays this Mac is paired with.
    @Published private(set) var pairedTargets: [PairingStore.Peer] = PairingStore.peers()

    enum PictureMode: String, CaseIterable, Identifiable {
        /// Native BC7 over the Thunderbolt Bridge, HEVC otherwise.
        case automatic
        /// Always BC7 (needs a fast link: ~7 Gbps for 5K at 60 fps).
        case native
        /// Always HEVC (works over Wi‑Fi, softer picture, more latency).
        case compressed
        var id: String { rawValue }
    }
    /// Applies to the next connection.
    @Published var pictureMode: PictureMode = PictureMode(rawValue: UserDefaults.standard.string(forKey: "host.pictureMode") ?? "") ?? .automatic {
        didSet { UserDefaults.standard.set(pictureMode.rawValue, forKey: "host.pictureMode") }
    }
    /// Excludes Wi‑Fi so the stream is forced over the Thunderbolt Bridge.
    @Published var wiredOnly: Bool = UserDefaults.standard.object(forKey: "host.wiredOnly") as? Bool ?? true {
        didSet { UserDefaults.standard.set(wiredOnly, forKey: "host.wiredOnly") }
    }

    private let networkQueue = DispatchQueue(label: "ScreenRelay.host.network", qos: .userInteractive)
    private var browser: NWBrowser?
    private var connection: MessageConnection?
    private var session: (any StreamSession)?
    private var virtualDisplay: VirtualDisplay?
    private var lastWaitingError: NWError?
    private var statsTimer: Timer?
    /// Delivers frame acks to the session straight from the network queue.
    private var ackRelay = FrameAckRelay()
    /// The connected target's screen, used to avoid streaming more pixels than it has.
    private var currentHello: TargetHello?
    private var isResizing = false
    /// Held while streaming. Without it, App Nap throttles this app whenever the extended
    /// screen is idle (the app is in the background and barely busy), and it takes
    /// seconds to return to full speed once the screen changes again.
    private var streamingActivity: NSObjectProtocol?
    /// This connection's local bridge address, reused for the cursor datagrams.
    private var connectionLocalAddress: String?
    private var cursorRelay: CursorRelay?
    private var cursorFallbackTimer: Timer?
    private var cursorChannelReady = false
    private var linkTest: LinkSpeedTest?

    // Handshake state for the current connection.
    private var targetIntro: HandshakeIntro?
    private var hostNonce = Data()
    private var pendingCodeKey: SymmetricKey?
    /// Set once the display proved it holds the pairing key; nothing is streamed before.
    private var targetVerified = false
    private let pairingPrompt = FloatingPrompt()

    // Automatic connection.
    /// The user pressed Disconnect: don't reconnect until they connect again (or wake).
    private var userDisconnected = false
    private var reconnectTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []

    /// The connected display's app version, and whether it differs from this Mac's.
    @Published private(set) var targetAppVersion = ""
    @Published private(set) var targetVersionMismatch = false

    @Published private(set) var pathDescription = ""
    @Published private(set) var liveStats = ""
    /// How the pointer reaches the target, shown in the status section.
    @Published private(set) var cursorStatus = ""
    /// Result of the last link speed test.
    @Published private(set) var linkSpeed = ""
    @Published private(set) var isTestingLink = false

    var isActive: Bool {
        switch phase {
        case .connecting, .pairing, .streaming: true
        case .idle, .failed: false
        }
    }

    // MARK: - Discovery

    func startBrowsing() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: RelayProtocol.serviceType, domain: nil), using: NWParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                self?.updateTargets(results)
            }
        }
        browser.stateUpdateHandler = { state in
            if case let .failed(error) = state {
                print("[Host] Browser failed: \(error)")
            }
        }
        browser.start(queue: .main)
        self.browser = browser

        observeSleepAndWake()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconnectIfNeeded() }
        }
    }

    /// This Mac's Thunderbolt Bridge address (e.g. 169.254.x.x on bridge0).
    ///
    /// Read from the interface list directly: Network.framework's path monitor only
    /// reports interfaces that can reach the internet, and a link-local bridge can't.
    private static func bridgeAddress() -> (address: String, interface: String)? {
        NetworkAddresses.ipv4Addresses().first { $0.interface.hasPrefix("bridge") }
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers = []
    }

    private func updateTargets(_ results: Set<NWBrowser.Result>) {
        // The same target is reported once per interface (Wi‑Fi, Thunderbolt Bridge, …),
        // and each result's endpoint is pinned to that interface. Pinned to Wi‑Fi while
        // Wi‑Fi is prohibited, a connection waits forever, so drop the interface and let
        // Network.framework resolve the service on whichever allowed path reaches it.
        var byName: [String: DiscoveredTarget] = [:]
        for result in results {
            guard case let .service(name, type, domain, _) = result.endpoint else { continue }
            let endpoint = NWEndpoint.service(name: name, type: type, domain: domain, interface: nil)
            var target = byName[name] ?? DiscoveredTarget(name: name, endpoint: endpoint)
            if case let .bonjour(txt) = result.metadata,
               let list = txt[RelayProtocol.wiredAddressesTXTKey], !list.isEmpty {
                target.wiredAddresses = list.split(separator: ",").map(String.init)
            }
            byName[name] = target
        }
        targets = byName.values.sorted { $0.name < $1.name }
        reconnectIfNeeded()
    }

    func requestScreenRecordingPermission() {
        hasScreenRecordingPermission = CGRequestScreenCaptureAccess()
    }

    // MARK: - Connecting

    func connect(to target: DiscoveredTarget) {
        userDisconnected = false
        // Bonjour resolution may only yield the target's Wi‑Fi address, which "wired only"
        // forbids. Going straight to the address it advertises for the cable avoids that.
        if wiredOnly, let address = target.wiredAddresses.first,
           let port = NWEndpoint.Port(rawValue: RelayProtocol.defaultPort) {
            connect(to: .hostPort(host: NWEndpoint.Host(address), port: port), label: target.name)
        } else {
            connect(to: target.endpoint, label: target.name)
        }
    }

    /// Connects to a manually entered address such as `169.254.12.34` or `imac.local:52100`.
    func connect(toAddress address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var host = trimmed
        var port = RelayProtocol.defaultPort
        if let colon = trimmed.lastIndex(of: ":"), let parsed = UInt16(trimmed[trimmed.index(after: colon)...]) {
            host = String(trimmed[..<colon])
            port = parsed
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        connect(to: .hostPort(host: NWEndpoint.Host(host), port: nwPort), label: host)
    }

    private func connect(to endpoint: NWEndpoint, label: String) {
        disconnect()
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
        if !hasScreenRecordingPermission {
            requestScreenRecordingPermission()
        }

        // With "wired only", bind to this Mac's Thunderbolt Bridge address rather than trust
        // the routing table, which may send link-local (169.254.x.x) traffic out over Wi‑Fi.
        // A Bonjour endpoint is resolved by name, so it keeps the Wi‑Fi prohibition instead.
        var localAddress: String?
        if wiredOnly, case .hostPort = endpoint {
            guard let bridge = Self.bridgeAddress() else {
                phase = .failed("This Mac has no Thunderbolt Bridge address. Check the cable and that Thunderbolt Bridge is active in System Settings › Network, or turn off “wired only”.")
                return
            }
            localAddress = bridge.address
            print("[Host] Connecting to \(label) from \(bridge.address) on \(bridge.interface)")
        }
        connectionLocalAddress = localAddress
        phase = .connecting(label)
        let nwConnection = NWConnection(to: endpoint, using: RelayProtocol.parameters(wiredOnly: wiredOnly, localAddress: localAddress))
        let connection = MessageConnection(connection: nwConnection, queue: networkQueue)

        connection.onStateChange = { [weak self, weak connection] state in
            DispatchQueue.main.async {
                guard let self, let connection, self.connection === connection else { return }
                switch state {
                case let .failed(error):
                    self.tearDown(reason: Self.localNetworkDeniedMessage(connection.connection)
                        ?? "Connection failed: \(error.localizedDescription)")
                case .cancelled:
                    self.tearDown(reason: nil)
                case let .waiting(error):
                    // "Network is down" while waiting usually means Local Network access is off.
                    if let message = Self.localNetworkDeniedMessage(connection.connection) {
                        self.tearDown(reason: message)
                        return
                    }
                    print("[Host] Waiting for network path: \(error)")
                    self.lastWaitingError = error
                case .ready:
                    self.pathDescription = Self.describePath(connection.connection.currentPath)
                default:
                    break
                }
            }
        }
        let ackRelay = FrameAckRelay()
        self.ackRelay = ackRelay
        connection.onMessage = { [weak self, weak connection] type, payload in
            switch type {
            case .authChallenge, .authConfirm, .authFailed, .pairAccepted:
                DispatchQueue.main.async {
                    guard let self, let connection, self.connection === connection else { return }
                    switch type {
                    case .authChallenge: self.handleChallenge(payload, on: connection)
                    case .authConfirm: self.handleAuthConfirm(payload)
                    case .authFailed: self.handleAuthFailed(payload, on: connection)
                    default: self.handlePairAccepted(payload)
                    }
                }
            case .hello:
                guard let hello = try? JSONDecoder().decode(TargetHello.self, from: payload) else { return }
                DispatchQueue.main.async {
                    guard let self, let connection, self.connection === connection else { return }
                    // Only a display that proved it's the paired one gets this Mac's screen.
                    guard self.targetVerified else {
                        self.tearDown(reason: AuthFailure.badProof.message)
                        return
                    }
                    Task { await self.startStreaming(to: hello, over: connection) }
                }
            case .requestKeyFrame:
                DispatchQueue.main.async {
                    self?.session?.requestKeyFrame()
                }
            case .frameAck:
                // Hot path: handled on the network queue without hopping to main.
                var reader = ByteReader(payload)
                ackRelay.handleFrameAck(decodeMicroseconds: reader.readUInt32() ?? 0)
            case .bandwidthResult:
                DispatchQueue.main.async {
                    self?.linkTest?.handleResult(payload)
                }
            case .cursorChannelReady:
                DispatchQueue.main.async {
                    self?.handleCursorChannelReady()
                }
            case .formatDescription, .videoFrame, .bandwidthProbe, .bandwidthProbeEnd, .cursorShape,
                 .canvasFormat, .tiles, .frameEnd, .authResponse, .pairRequest, .pairCode, .hostSleepState:
                break
            }
        }

        self.connection = connection
        lastWaitingError = nil
        connection.start()

        // NWConnection waits indefinitely for a usable path; give up with a real reason instead.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectTimeout) { [weak self, weak connection] in
            guard let self, let connection, self.connection === connection, case .connecting = self.phase else { return }
            var reason = "Couldn't reach \(label) within \(Int(Self.connectTimeout)) seconds."
            if let error = self.lastWaitingError {
                reason += " (\(error.localizedDescription))"
            }
            if self.wiredOnly {
                reason += " Check that Thunderbolt Bridge is connected on both Macs, or turn off “wired only”."
            }
            self.tearDown(reason: reason)
        }
    }

    /// The Disconnect button: also stops automatic reconnection until the next connect or wake.
    func userDisconnect() {
        userDisconnected = true
        disconnect()
    }

    func disconnect() {
        connection?.cancel()
        tearDown(reason: nil)
    }

    func forget(_ target: PairingStore.Peer) {
        PairingStore.remove(target.id)
        pairedTargets = PairingStore.peers()
    }

    private func reconnectIfNeeded() {
        guard autoConnect, !userDisconnected, browser != nil, let name = lastTargetName else { return }
        switch phase {
        case .idle, .failed: break
        default: return
        }
        guard let target = targets.first(where: { $0.name == name }) else { return }
        print("[Host] Reconnecting to \(name)")
        connect(to: target)
    }

    // MARK: - Sleep and wake

    private func observeSleepAndWake() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let observe = { (name: Notification.Name, handler: @escaping @MainActor () -> Void) in
            self.workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler() }
            })
        }
        // The display goes dark with this Mac, and comes back when it does.
        observe(NSWorkspace.willSleepNotification) { [weak self] in self?.sendSleepState(asleep: true) }
        observe(NSWorkspace.screensDidSleepNotification) { [weak self] in self?.sendSleepState(asleep: true) }
        observe(NSWorkspace.screensDidWakeNotification) { [weak self] in self?.sendSleepState(asleep: false) }
        observe(NSWorkspace.didWakeNotification) { [weak self] in
            guard let self else { return }
            self.userDisconnected = false
            // The network needs a moment after wake; the 5-second timer keeps trying too.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.reconnectIfNeeded() }
        }
    }

    private func sendSleepState(asleep: Bool) {
        guard targetVerified, let connection else { return }
        connection.send(.hostSleepState, payload: Data([asleep ? 1 : 0]))
    }

    // MARK: - Pairing and authentication

    private func handleChallenge(_ payload: Data, on connection: MessageConnection) {
        guard let target = HandshakeIntro(payload, hasProof: false) else { return }
        targetIntro = target
        hostNonce = Handshake.nonce()
        if let key = PairingStore.key(for: target.id) {
            let proof = Handshake.hostProof(key: key, targetNonce: target.nonce, hostNonce: hostNonce,
                                            targetID: target.id, hostID: DeviceIdentity.id)
            connection.send(.authResponse, payload: HandshakeIntro(id: DeviceIdentity.id, nonce: hostNonce,
                                                                   proof: proof, name: DeviceIdentity.name).encoded())
        } else {
            beginPairing(with: target, on: connection)
        }
    }

    private func beginPairing(with target: HandshakeIntro, on connection: MessageConnection, error: String? = nil) {
        if error == nil {
            connection.send(.pairRequest, payload: HandshakeIntro(id: DeviceIdentity.id, nonce: hostNonce,
                                                                  name: DeviceIdentity.name).encoded())
        }
        phase = .pairing(target.name)
        pairingPrompt.show(title: "Pair with \(target.name)") {
            PairingEntryView(targetName: target.name, error: error) { [weak self] code in
                self?.submitPairingCode(code)
            } onCancel: { [weak self] in
                self?.userDisconnect()
            }
        }
    }

    func submitPairingCode(_ code: String) {
        guard let connection, let target = targetIntro else { return }
        let digits = code.filter(\.isNumber)
        let codeKey = Handshake.codeKey(code: digits, targetNonce: target.nonce, hostNonce: hostNonce)
        pendingCodeKey = codeKey
        connection.send(.pairCode, payload: Handshake.codeProof(codeKey: codeKey, hostID: DeviceIdentity.id))
        phase = .connecting(target.name)
    }

    private func handlePairAccepted(_ payload: Data) {
        guard let target = targetIntro, let codeKey = pendingCodeKey,
              let key = Handshake.unwrap(payload, with: codeKey) else { return }
        PairingStore.save(key, for: target.id, name: target.name)
        pairedTargets = PairingStore.peers()
        pairingPrompt.dismiss()
        pendingCodeKey = nil
    }

    private func handleAuthConfirm(_ payload: Data) {
        guard let target = targetIntro, let key = PairingStore.key(for: target.id) else { return }
        let expected = Handshake.targetProof(key: key, targetNonce: target.nonce, hostNonce: hostNonce,
                                             targetID: target.id, hostID: DeviceIdentity.id)
        guard Handshake.matches(payload, expected) else {
            // Something answering as this display doesn't hold the key: don't stream to it.
            tearDown(reason: AuthFailure.badProof.message)
            userDisconnected = true
            return
        }
        targetVerified = true
    }

    private func handleAuthFailed(_ payload: Data, on connection: MessageConnection) {
        guard let reason = payload.first.flatMap(AuthFailure.init(rawValue:)) else { return }
        switch reason {
        case .notPaired:
            // The display forgot this Mac (or never knew it): pair again.
            if let target = targetIntro {
                PairingStore.remove(target.id)
                pairedTargets = PairingStore.peers()
                beginPairing(with: target, on: connection)
            }
        case .wrongCode:
            if let target = targetIntro { beginPairing(with: target, on: connection, error: reason.message) }
        case .tooManyAttempts, .wifiNotAllowed, .badProof:
            pairingPrompt.dismiss()
            userDisconnected = true // don't loop on something only the user can fix
            tearDown(reason: reason.message)
        }
    }


    private func tearDown(reason: String?) {
        pairingPrompt.dismiss()
        targetIntro = nil
        pendingCodeKey = nil
        targetVerified = false
        stopCursorRelay()
        linkTest = nil
        isTestingLink = false
        statsTimer?.invalidate()
        statsTimer = nil
        if let streamingActivity {
            ProcessInfo.processInfo.endActivity(streamingActivity)
            self.streamingActivity = nil
        }
        currentHello = nil
        targetAppVersion = ""
        targetVersionMismatch = false
        isResizing = false
        session?.stop()
        session = nil
        ackRelay.session = nil
        pathDescription = ""
        liveStats = ""
        connection?.onStateChange = nil
        connection?.onMessage = nil
        connection?.cancel()
        connection = nil
        // Releasing the virtual display removes it from the system.
        virtualDisplay = nil
        streamDescription = ""
        phase = reason.map(Phase.failed) ?? .idle
    }

    // MARK: - Streaming

    private func startStreaming(to hello: TargetHello, over connection: MessageConnection) async {
        guard hello.protocolVersion == RelayProtocol.version else {
            tearDown(reason: "\(hello.name) runs an incompatible version of ScreenRelay.")
            return
        }

        do {
            let display = try VirtualDisplay(
                name: hello.name,
                pixelWidth: hello.pixelWidth,
                pixelHeight: hello.pixelHeight,
                backingScale: hello.backingScale,
                sizeInMillimeters: CGSize(width: hello.widthMillimeters, height: hello.heightMillimeters),
                refreshRate: Double(Self.frameRate)
            )
            virtualDisplay = display

            // The display reports a provisional size until macOS brings it online.
            let displaySize = try await display.waitUntilReady()
            guard self.connection === connection else { return }
            print("[Host] Virtual display \(display.displayID) ready at \(displaySize.width)×\(displaySize.height); target asked for \(hello.pixelWidth)×\(hello.pixelHeight) @\(hello.backingScale)x, HEVC decode: \(hello.supportsHEVC)")

            currentHello = hello
            let size = captureSize(for: displaySize)
            let session = try makeSession(for: hello, over: connection, size: size)
            session.onStop = { [weak self] error in
                DispatchQueue.main.async {
                    self?.tearDown(reason: "Screen capture stopped: \(error.localizedDescription)")
                }
            }

            // The pointer is left out of the video; the target draws it (see CursorRelay).
            try await session.start(displayID: display.displayID, frameRate: Self.frameRate, showsCursor: false)

            // The user may have hit Disconnect while capture was starting.
            guard self.connection === connection else {
                session.stop()
                return
            }
            self.session = session
            ackRelay.session = session
            streamingActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
                reason: "Streaming a display to \(hello.name)"
            )
            startStatsTimer()
            lastTargetName = hello.name
            targetAppVersion = hello.appVersion ?? "unknown (an older build)"
            targetVersionMismatch = hello.appVersion != AppInfo.versionLabel
            startCursorRelay(displayID: display.displayID, over: connection)
            updateStreamDescription()
            phase = .streaming(hello.name)
        } catch {
            guard self.connection === connection else { return }
            tearDown(reason: error.localizedDescription)
        }
    }

    /// Native BC7 tiles when the target supports them and the link is the Thunderbolt Bridge
    /// (bound to the bridge address); HEVC otherwise, e.g. over Wi‑Fi.
    private func makeSession(for hello: TargetHello, over connection: MessageConnection,
                             size: (width: Int, height: Int)) throws -> any StreamSession {
        let useTiles: Bool = switch pictureMode {
        case .automatic: hello.supportsBC7 && connectionLocalAddress != nil
        case .native: hello.supportsBC7
        case .compressed: false
        }
        if useTiles {
            do {
                return try TileStreamSession(connection: connection, width: size.width, height: size.height)
            } catch {
                print("[Host] BC7 unavailable, using HEVC: \(error)")
            }
        }
        let codec = try preferredCodec(for: hello, width: size.width, height: size.height)
        let frameRate = Self.frameRate
        return try HostStreamSession(
            connection: connection, width: size.width, height: size.height,
            bitrate: Int(bitrateMbps * 1_000_000)
        ) { width, height, bitrate in
            try VideoEncoder(codec: codec, width: width, height: height, frameRate: frameRate, bitrate: bitrate)
        }
    }

    /// The size to capture and encode for a virtual display of `displaySize` pixels: never
    /// more than the target's panel (a "More Space" mode renders above it, and those extra
    /// pixels would be thrown away), then scaled by `streamScale`. Dimensions stay even,
    /// as 4:2:0 video requires.
    private func captureSize(for displaySize: (width: Int, height: Int)) -> (width: Int, height: Int) {
        guard displaySize.width > 0, displaySize.height > 0 else { return displaySize }
        var factor = min(max(streamScale, 0.25), 1)
        if let hello = currentHello, hello.pixelWidth > 0, hello.pixelHeight > 0 {
            factor *= min(1, Double(hello.pixelWidth) / Double(displaySize.width),
                          Double(hello.pixelHeight) / Double(displaySize.height))
        }
        return (Int(Double(displaySize.width) * factor / 2) * 2, Int(Double(displaySize.height) * factor / 2) * 2)
    }

    /// Resizes a running stream when the virtual display's mode or `streamScale` changes.
    private func applyStreamSize() {
        guard let session, let display = virtualDisplay, !isResizing else { return }
        let size = captureSize(for: display.pixelSize)
        guard size.width > 0, size != session.size else { return }
        isResizing = true
        Task {
            defer { isResizing = false }
            do {
                try await session.resize(width: size.width, height: size.height)
                print("[Host] Stream resized to \(size.width)×\(size.height)")
            } catch {
                print("[Host] Couldn't resize stream: \(error)")
            }
            updateStreamDescription()
        }
    }

    private func updateStreamDescription() {
        guard let session else { return }
        var text = "\(session.size.width)×\(session.size.height) · \(session.modeDescription) · \(Self.frameRate) fps"
        if session is HostStreamSession { text += " · \(Int(bitrateMbps)) Mbps" }
        if let display = virtualDisplay {
            let pixels = display.pixelSize
            if pixels != session.size {
                text += " (display renders \(pixels.width)×\(pixels.height))"
            }
        }
        streamDescription = text
    }

    /// macOS reports a missing Local Network permission as "Network is down"; spell it out.
    private static func localNetworkDeniedMessage(_ connection: NWConnection) -> String? {
        guard #available(macOS 14.0, *), connection.currentPath?.unsatisfiedReason == .localNetworkDenied else { return nil }
        return "macOS is blocking ScreenRelay's access to the local network. In System Settings › Privacy & Security › Local Network, turn ScreenRelay off and back on, then connect again."
    }

    // MARK: - Cursor

    /// If no confirmation arrives in this time, the pointer goes back into the video.
    private static let cursorChannelTimeout: TimeInterval = 3

    private func startCursorRelay(displayID: CGDirectDisplayID, over connection: MessageConnection) {
        let remote = connection.connection.currentPath?.remoteEndpoint ?? connection.connection.endpoint
        guard case let .hostPort(host, _) = remote else {
            fallBackToCursorInVideo(reason: "no target address")
            return
        }
        let relay = CursorRelay(displayID: displayID, targetHost: host,
                                localAddress: connectionLocalAddress, control: connection)
        relay.start()
        cursorRelay = relay
        cursorChannelReady = false
        cursorStatus = "Connecting…"
        cursorFallbackTimer = Timer.scheduledTimer(withTimeInterval: Self.cursorChannelTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.cursorChannelReady else { return }
                self.fallBackToCursorInVideo(reason: "cursor updates aren't reaching the target (UDP port \(RelayProtocol.cursorPort))")
            }
        }
    }

    private func handleCursorChannelReady() {
        guard cursorRelay != nil, !cursorChannelReady else { return }
        cursorChannelReady = true
        cursorFallbackTimer?.invalidate()
        cursorFallbackTimer = nil
        cursorStatus = "Drawn by the target (no lag)"
        // Undo the fallback if datagrams only started arriving late.
        if let session { Task { try? await session.setShowsCursor(false) } }
    }

    private func fallBackToCursorInVideo(reason: String) {
        print("[Host] Cursor relay unavailable: \(reason). Drawing the pointer into the video.")
        cursorStatus = "In the video (\(reason))"
        if let session { Task { try? await session.setShowsCursor(true) } }
    }

    private func stopCursorRelay() {
        cursorFallbackTimer?.invalidate()
        cursorFallbackTimer = nil
        cursorRelay?.stop()
        cursorRelay = nil
        cursorChannelReady = false
        cursorStatus = ""
    }

    // MARK: - Link speed

    /// Measures the connection's real throughput. The picture pauses for about 2 seconds
    /// while the test data occupies the link.
    func testLinkSpeed() {
        guard let connection, session != nil, linkTest == nil else { return }
        let test = LinkSpeedTest(connection: connection)
        linkTest = test
        isTestingLink = true
        linkSpeed = "Testing…"
        test.start { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.linkTest = nil
                self.isTestingLink = false
                guard let result else {
                    self.linkSpeed = "Test failed"
                    return
                }
                let needed = 5120.0 * 2880 * 60 * 8 / 1_000_000_000 // BC7: 1 byte per pixel
                self.linkSpeed = String(format: "%.1f Gbps (native 5K at 60 fps with BC7 needs ~%.1f Gbps)",
                                        result.gigabitsPerSecond, needed)
                print("[Host] Link speed: \(result.bytes) bytes in \(result.seconds) s = \(result.gigabitsPerSecond) Gbps")
            }
        }
    }

    private func startStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let session = self.session else { return }
                // Follow resolution changes made in System Settings › Displays.
                self.applyStreamSize()

                let stats = session.sampleStatistics()
                func ms(_ value: Double?) -> String { value.map { String(format: "%.1f ms", $0) } ?? "–" }
                let rates = "\(Int(stats.capturedPerSecond.rounded())) captured · \(Int(stats.shownPerSecond.rounded())) shown · \(Int(stats.skippedPerSecond.rounded())) skipped /s"
                var timings = "encode \(ms(stats.encodeMilliseconds)) · decode \(ms(stats.decodeMilliseconds)) · round trip \(ms(stats.roundTripMilliseconds))"
                if let megabits = stats.megabitsPerSecond {
                    timings += megabits >= 1000 ? String(format: " · %.2f Gbps", megabits / 1000) : String(format: " · %.0f Mbps", megabits)
                }
                self.liveStats = rates + "\n" + timings
            }
        }
    }

    private static func describePath(_ path: NWPath?) -> String {
        guard let path, let interface = path.availableInterfaces.first else { return "" }
        let kind: String = switch interface.type {
        case .wifi: "Wi‑Fi"
        case .wiredEthernet: "Ethernet"
        case .other where interface.name.hasPrefix("bridge"): "Thunderbolt Bridge"
        case .loopback: "Loopback"
        default: "Wired"
        }
        return "\(kind) (\(interface.name))"
    }

    /// Prefers HEVC (better quality per bit, and needed above 4K) and falls back to H.264.
    /// Probes by creating an encoder, so a codec that can't handle the size is skipped.
    private func preferredCodec(for hello: TargetHello, width: Int, height: Int) throws -> VideoCodec {
        let bitrate = Int(bitrateMbps * 1_000_000)
        var hevcError: Error?
        if hello.supportsHEVC {
            do {
                _ = try VideoEncoder(codec: .hevc, width: width, height: height, frameRate: Self.frameRate, bitrate: bitrate)
                return .hevc
            } catch {
                print("[Host] HEVC encoder unavailable, falling back to H.264: \(error)")
                hevcError = error
            }
        }
        do {
            _ = try VideoEncoder(codec: .h264, width: width, height: height, frameRate: Self.frameRate, bitrate: bitrate)
            return .h264
        } catch {
            // Report both attempts and the size involved; the size is usually the culprit.
            var message = "Couldn't create a video encoder for \(width)×\(height)."
            if let hevcError { message += " HEVC: \(hevcError.localizedDescription)" }
            message += " H.264: \(error.localizedDescription)"
            throw EncoderSetupError(message: message)
        }
    }
}

private struct EncoderSetupError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Lock-protected hand-off so acks reach the session without a main-thread hop.
nonisolated private final class FrameAckRelay: @unchecked Sendable {
    private let lock = NSLock()
    private weak var _session: (any StreamSession)?

    var session: (any StreamSession)? {
        get { lock.withLock { _session } }
        set { lock.withLock { _session = newValue } }
    }

    func handleFrameAck(decodeMicroseconds: UInt32) {
        session?.handleFrameAck(decodeMicroseconds: decodeMicroseconds)
    }
}
