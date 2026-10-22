//
//  LinkSpeedTest.swift
//  ScreenRelay
//
//  Measures how much data the connection to the target can actually carry, so we
//  know whether uncompressed-quality 5K (BC7, ~7 Gbps at 60 fps) fits the link.
//

import Foundation

nonisolated final class LinkSpeedTest: @unchecked Sendable {
    struct Result {
        let bytes: UInt64
        let seconds: Double
        var gigabitsPerSecond: Double { seconds > 0 ? Double(bytes) * 8 / seconds / 1_000_000_000 : 0 }
    }

    private static let chunkSize = 1 << 20          // 1 MB
    private static let chunksInFlight = 16
    private static let duration: TimeInterval = 2

    private let connection: MessageConnection
    private let lock = NSLock()
    private let chunk = Data(count: LinkSpeedTest.chunkSize)
    private var deadline = Date.distantPast
    private var inFlight = 0
    private var finished = false
    private var completion: ((Result?) -> Void)?

    init(connection: MessageConnection) {
        self.connection = connection
    }

    /// Floods the connection for a couple of seconds. The target measures what arrives
    /// and replies with `bandwidthResult`, which must be passed to `handleResult(_:)`.
    func start(completion: @escaping (Result?) -> Void) {
        lock.withLock {
            self.completion = completion
            deadline = Date().addingTimeInterval(Self.duration)
        }
        for _ in 0..<Self.chunksInFlight { sendNext() }
    }

    func handleResult(_ payload: Data) {
        var reader = ByteReader(payload)
        let result = reader.readUInt64().flatMap { bytes in
            reader.readUInt64().map { Result(bytes: bytes, seconds: Double($0) / 1_000_000) }
        }
        let completion = lock.withLock {
            defer { self.completion = nil }
            return self.completion
        }
        completion?(result)
    }

    private func sendNext() {
        let action: (send: Bool, end: Bool) = lock.withLock {
            if finished { return (false, false) }
            if Date() < deadline {
                inFlight += 1
                return (true, false)
            }
            // Out of time: once the last chunk has been handed over, ask for the result.
            if inFlight == 0 {
                finished = true
                return (false, true)
            }
            return (false, false)
        }
        if action.end {
            connection.send(.bandwidthProbeEnd)
        } else if action.send {
            connection.send(.bandwidthProbe, payload: chunk) { [weak self] error in
                guard let self else { return }
                self.lock.withLock { self.inFlight -= 1 }
                if error == nil { self.sendNext() }
            }
        }
    }
}
