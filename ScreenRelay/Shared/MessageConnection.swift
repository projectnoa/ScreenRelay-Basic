//
//  MessageConnection.swift
//  ScreenRelay
//
//  Wraps an NWConnection and reads/writes length-prefixed messages.
//

import Foundation
import Network

nonisolated final class MessageConnection: @unchecked Sendable {
    let connection: NWConnection
    private let queue: DispatchQueue

    /// Called on `queue` for every complete message.
    var onMessage: (@Sendable (MessageType, Data) -> Void)?
    /// Called on `queue` whenever the underlying connection changes state.
    var onStateChange: (@Sendable (NWConnection.State) -> Void)?

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    var endpointDescription: String {
        "\(connection.endpoint)"
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.onStateChange?(state)
        }
        connection.start(queue: queue)
        receiveHeader()
    }

    func cancel() {
        connection.cancel()
    }

    func send(_ type: MessageType, payload: Data = Data(), completion: ((NWError?) -> Void)? = nil) {
        var frame = Data(capacity: RelayProtocol.headerLength + payload.count)
        frame.append(type.rawValue)
        frame.appendBigEndian(UInt32(payload.count))
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { error in
            completion?(error)
        })
    }

    // MARK: - Receiving

    private func receiveHeader() {
        let headerLength = RelayProtocol.headerLength
        connection.receive(minimumIncompleteLength: headerLength, maximumLength: headerLength) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                print("[MessageConnection] Receive error: \(error)")
                self.connection.cancel()
                return
            }
            guard let data, data.count == headerLength else {
                if isComplete { self.connection.cancel() }
                return
            }
            var reader = ByteReader(data)
            guard let rawType = reader.readUInt8(), let length = reader.readUInt32(),
                  length <= RelayProtocol.maxPayloadLength else {
                print("[MessageConnection] Malformed header, closing connection")
                self.connection.cancel()
                return
            }
            if length == 0 {
                self.deliver(rawType: rawType, payload: Data())
                self.receiveHeader()
            } else {
                self.receiveBody(rawType: rawType, length: Int(length))
            }
        }
    }

    private func receiveBody(rawType: UInt8, length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                print("[MessageConnection] Receive error: \(error)")
                self.connection.cancel()
                return
            }
            guard let data, data.count == length else {
                if isComplete { self.connection.cancel() }
                return
            }
            self.deliver(rawType: rawType, payload: data)
            self.receiveHeader()
        }
    }

    private func deliver(rawType: UInt8, payload: Data) {
        // Unknown message types are skipped so newer peers can add messages.
        guard let type = MessageType(rawValue: rawType) else { return }
        onMessage?(type, payload)
    }
}
