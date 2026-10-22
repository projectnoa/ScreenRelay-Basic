//
//  RelayProtocol.swift
//  ScreenRelay
//
//  Wire format shared by the host and the target.
//
//  Every message on the TCP stream is framed as:
//      [type: UInt8][payload length: UInt32 big-endian][payload]
//

import Foundation
import Network
import CoreMedia

nonisolated enum RelayProtocol {
    static let serviceType = "_screenrelay._tcp"
    static let defaultPort: UInt16 = 52100
    /// Both Macs must speak the same version. Message numbers are never reused, so the
    /// gaps in `MessageType` are intentional.
    static let version = 9
    /// UDP port for cursor positions. Kept off the TCP stream so a large video frame can
    /// never delay the pointer, and because only the latest position matters.
    static let cursorPort: UInt16 = 52101
    static let headerLength = 5
    /// Bonjour TXT key listing the target's non‑Wi‑Fi IPv4 addresses, comma separated,
    /// Thunderbolt Bridge first. Lets the host connect over the cable directly instead of
    /// relying on Bonjour resolution, which may only return the Wi‑Fi address.
    static let wiredAddressesTXTKey = "wired"
    /// Upper bound for a single message; a 5K keyframe is typically well under this.
    static let maxPayloadLength = 64 * 1024 * 1024

    /// TCP parameters tuned for low-latency video.
    /// - Parameters:
    ///   - wiredOnly: When true, Wi‑Fi is excluded so traffic is forced over the
    ///     Thunderbolt Bridge (or Ethernet). Ignored when `localAddress` is given,
    ///     since binding to a wired address already guarantees a wired path.
    ///   - localAddress: Binds the connection to this IPv4 address of a local interface
    ///     (e.g. the Thunderbolt Bridge's 169.254.x.x). Needed because both the bridge
    ///     and Wi‑Fi can hold a 169.254.0.0/16 route; when Wi‑Fi's is the primary one an
    ///     unbound connection to the target's link-local address goes out over Wi‑Fi.
    ///     Binding the source address makes macOS use the interface that owns it.
    static func parameters(wiredOnly: Bool = false, localAddress: String? = nil) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.serviceClass = .interactiveVideo
        parameters.includePeerToPeer = false
        if let localAddress, let address = IPv4Address(localAddress) {
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(address), port: .any)
        } else if wiredOnly {
            parameters.prohibitedInterfaceTypes = [.wifi, .cellular]
        }
        return parameters
    }
}

nonisolated enum MessageType: UInt8 {
    /// Target → host. JSON-encoded `TargetHello`.
    case hello = 1
    /// Host → target. `FormatDescriptionMessage` with the codec parameter sets.
    case formatDescription = 2
    /// Host → target. `[flags: UInt8][length-prefixed NAL units]`.
    case videoFrame = 3
    /// Target → host. Empty payload; asks the encoder for a new keyframe.
    case requestKeyFrame = 4
    /// Target → host. `[decode time µs: UInt32]`, sent for every `videoFrame` once it has
    /// been decoded (or discarded), in order. The host limits unacknowledged frames so
    /// latency can't build up in socket buffers or behind a slow decoder.
    case frameAck = 5
    // 6–7 are reserved.
    /// Host → target. Filler data for the link speed test.
    case bandwidthProbe = 8
    /// Host → target. Empty; the speed test is over, report what arrived.
    case bandwidthProbeEnd = 9
    /// Target → host. `[bytes: UInt64][microseconds: UInt64]` received during the test.
    case bandwidthResult = 10
    /// Host → target. `CursorShape`: the host's current pointer image.
    case cursorShape = 11
    /// Target → host. Empty; cursor datagrams are arriving, so the host can leave the
    /// pointer out of the video.
    case cursorChannelReady = 12
    /// Host → target. `[width: UInt32][height: UInt32]` pixels: (re)create the BC7 canvas.
    /// Sent before the first tiles and after every resize.
    case canvasFormat = 13
    /// Host → target. `TileRun`: a horizontal run of changed BC7 tiles.
    case tiles = 14
    /// Host → target. `[frame: UInt32]`: every tile of this frame has been sent; draw it.
    case frameEnd = 15

    // Handshake. Until it completes, the target ignores everything else and the host
    // sends nothing but handshake messages.

    /// Target → host, first message: `[target ID: 16][nonce: 32][name: UTF-8]`.
    case authChallenge = 16
    /// Host → target, when paired: `[host ID: 16][nonce: 32][proof: 32][name: UTF-8]`.
    case authResponse = 17
    /// Target → host: `[proof: 32]`. The target knows the key too; `hello` follows.
    case authConfirm = 18
    /// Either way: `[AuthFailure: UInt8]`, then the connection closes (except for a wrong
    /// pairing code, which may be retried).
    case authFailed = 19
    /// Host → target, when not paired: `[host ID: 16][nonce: 32][name: UTF-8]`. The target
    /// shows a pairing code.
    case pairRequest = 20
    /// Host → target: `[proof: 32]` derived from the code the user typed.
    case pairCode = 21
    /// Target → host: the new pairing key, sealed with a key derived from the code.
    case pairAccepted = 22

    /// Host → target: `[asleep: UInt8]`. The host's displays went to sleep (or the host is
    /// about to sleep): turn the panel off and let this Mac sleep. 0 means awake again.
    case hostSleepState = 23
    // 24–26 are reserved.
}

nonisolated enum AuthFailure: UInt8 {
    case notPaired = 1
    case wrongCode = 2
    case tooManyAttempts = 3
    case wifiNotAllowed = 4
    case badProof = 5

    var message: String {
        switch self {
        case .notPaired: "The Macs aren't paired."
        case .wrongCode: "That pairing code is wrong."
        case .tooManyAttempts: "Too many wrong codes. Connect again for a new code."
        case .wifiNotAllowed: "The display only accepts connections over the Thunderbolt Bridge (it can allow Wi‑Fi in its settings)."
        case .badProof: "The other Mac couldn't prove it's the paired one. Pair them again."
        }
    }
}

/// `[ID: 16][nonce: 32][optional proof: 32][name: UTF-8]`, the shape shared by
/// `authChallenge`, `authResponse` and `pairRequest`.
nonisolated struct HandshakeIntro {
    var id: UUID
    var nonce: Data
    var proof: Data?
    var name: String

    func encoded() -> Data {
        var data = id.data + nonce
        if let proof { data += proof }
        data += Data(name.utf8)
        return data
    }

    init(id: UUID, nonce: Data, proof: Data? = nil, name: String) {
        self.id = id
        self.nonce = nonce
        self.proof = proof
        self.name = name
    }

    init?(_ data: Data, hasProof: Bool) {
        var reader = ByteReader(data)
        guard let idData = reader.readData(count: 16), let id = UUID(data: Data(idData)),
              let nonce = reader.readData(count: Handshake.nonceLength) else { return nil }
        var proof: Data?
        if hasProof {
            guard let value = reader.readData(count: Handshake.macLength) else { return nil }
            proof = Data(value)
        }
        self.init(id: id, nonce: Data(nonce), proof: proof,
                  name: String(decoding: reader.remaining, as: UTF8.self))
    }
}

/// A rectangle of BC7 blocks (4×4 pixels, 16 bytes each), stored row by row.
///
/// Layout: `[frame: UInt32][x, y, width, height: UInt16, in blocks][block data]`
nonisolated struct TileRun {
    static let headerLength = 12

    var frame: UInt32
    var blockX: Int, blockY: Int, blocksWide: Int, blocksHigh: Int
    var data: Data

    static func header(frame: UInt32, blockX: Int, blockY: Int, blocksWide: Int, blocksHigh: Int) -> Data {
        var data = Data(capacity: headerLength)
        data.appendBigEndian(frame)
        for value in [blockX, blockY, blocksWide, blocksHigh] { data.appendBigEndian(UInt16(value)) }
        return data
    }

    init?(_ payload: Data) {
        var reader = ByteReader(payload)
        guard let frame = reader.readUInt32(), let x = reader.readUInt16(), let y = reader.readUInt16(),
              let w = reader.readUInt16(), let h = reader.readUInt16(), w > 0, h > 0 else { return nil }
        let data = reader.remaining
        guard data.count == Int(w) * Int(h) * 16 else { return nil }
        self.frame = frame
        blockX = Int(x); blockY = Int(y); blocksWide = Int(w); blocksHigh = Int(h)
        self.data = data
    }
}

/// The host's pointer image. Sent over TCP whenever it changes (it's rare and must arrive).
///
/// Layout: `[hot spot x, y][size width, height]` as Float32 points, then PNG data.
nonisolated struct CursorShape {
    var hotSpot: CGPoint
    var size: CGSize
    var png: Data

    func encoded() -> Data {
        var data = Data(capacity: 16 + png.count)
        for value in [hotSpot.x, hotSpot.y, size.width, size.height] {
            data.appendBigEndian(Float32(value).bitPattern)
        }
        data.append(png)
        return data
    }

    init(hotSpot: CGPoint, size: CGSize, png: Data) {
        self.hotSpot = hotSpot
        self.size = size
        self.png = png
    }

    init?(_ data: Data) {
        var reader = ByteReader(data)
        guard let x = reader.readFloat32(), let y = reader.readFloat32(),
              let width = reader.readFloat32(), let height = reader.readFloat32(),
              width > 0, height > 0 else { return nil }
        self.init(hotSpot: CGPoint(x: CGFloat(x), y: CGFloat(y)),
                  size: CGSize(width: CGFloat(width), height: CGFloat(height)),
                  png: reader.remaining)
    }
}

/// The host pointer's position on the virtual display, sent over UDP on every move
/// (and periodically, so a lost datagram is corrected quickly).
///
/// Layout: `[magic "SRCP"][sequence: UInt32][flags: UInt8][x, y: Float32 0…1 from top-left]
/// [display width, height: Float32 points]`
nonisolated struct CursorDatagram {
    static let magic: UInt32 = 0x5352_4350 // "SRCP"

    var sequence: UInt32
    /// False when the pointer is on another of the host's displays.
    var visible: Bool
    var x: Float
    var y: Float
    var displayWidth: Float
    var displayHeight: Float

    func encoded() -> Data {
        var data = Data(capacity: 25)
        data.appendBigEndian(Self.magic)
        data.appendBigEndian(sequence)
        data.append(visible ? 1 : 0)
        for value in [x, y, displayWidth, displayHeight] {
            data.appendBigEndian(value.bitPattern)
        }
        return data
    }

    init(sequence: UInt32, visible: Bool, x: Float, y: Float, displayWidth: Float, displayHeight: Float) {
        self.sequence = sequence
        self.visible = visible
        self.x = x
        self.y = y
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
    }

    init?(_ data: Data) {
        var reader = ByteReader(data)
        guard reader.readUInt32() == Self.magic,
              let sequence = reader.readUInt32(), let flags = reader.readUInt8(),
              let x = reader.readFloat32(), let y = reader.readFloat32(),
              let width = reader.readFloat32(), let height = reader.readFloat32() else { return nil }
        self.init(sequence: sequence, visible: flags & 1 != 0, x: x, y: y, displayWidth: width, displayHeight: height)
    }
}

nonisolated enum VideoCodec: UInt8, CustomStringConvertible {
    case h264 = 1
    case hevc = 2

    var codecType: CMVideoCodecType {
        switch self {
        case .h264: kCMVideoCodecType_H264
        case .hevc: kCMVideoCodecType_HEVC
        }
    }

    var description: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        }
    }
}

/// Describes the target's screen so the host can create a matching virtual display.
nonisolated struct TargetHello: Codable {
    var protocolVersion: Int
    var name: String
    var pixelWidth: Int
    var pixelHeight: Int
    var backingScale: Int
    var widthMillimeters: Double
    var heightMillimeters: Double
    var supportsHEVC: Bool
    /// The GPU can sample BC7 textures, so native-quality tile streaming is possible.
    var supportsBC7: Bool
    /// The target's app edition and version, e.g. "Basic 1.0 (1)", shown on the host.
    var appVersion: String?
}

/// Codec configuration (SPS/PPS, plus VPS for HEVC) sent before every keyframe
/// whose parameter sets differ from the previous ones.
nonisolated struct FormatDescriptionMessage: Equatable {
    var codec: VideoCodec
    var nalUnitHeaderLength: Int
    var parameterSets: [Data]

    func encoded() -> Data {
        var data = Data()
        data.append(codec.rawValue)
        data.append(UInt8(nalUnitHeaderLength))
        data.append(UInt8(parameterSets.count))
        for set in parameterSets {
            data.appendBigEndian(UInt16(set.count))
            data.append(set)
        }
        return data
    }

    init(codec: VideoCodec, nalUnitHeaderLength: Int, parameterSets: [Data]) {
        self.codec = codec
        self.nalUnitHeaderLength = nalUnitHeaderLength
        self.parameterSets = parameterSets
    }

    init?(_ data: Data) {
        var reader = ByteReader(data)
        guard let codecRaw = reader.readUInt8(),
              let codec = VideoCodec(rawValue: codecRaw),
              let nalLength = reader.readUInt8(),
              let count = reader.readUInt8() else { return nil }
        var sets: [Data] = []
        for _ in 0..<count {
            guard let length = reader.readUInt16(), let set = reader.readData(count: Int(length)) else { return nil }
            sets.append(set)
        }
        self.init(codec: codec, nalUnitHeaderLength: Int(nalLength), parameterSets: sets)
    }
}

nonisolated struct VideoFrameFlags: OptionSet {
    let rawValue: UInt8
    static let keyFrame = VideoFrameFlags(rawValue: 1 << 0)
}

// MARK: - Byte helpers

nonisolated extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

nonisolated struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    var remaining: Data { data[offset...] }

    mutating func readUInt8() -> UInt8? {
        guard offset < data.endIndex else { return nil }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt16() -> UInt16? { readInteger() }
    mutating func readUInt32() -> UInt32? { readInteger() }
    mutating func readUInt64() -> UInt64? { readInteger() }
    mutating func readFloat32() -> Float? { readUInt32().map(Float.init(bitPattern:)) }

    mutating func readData(count: Int) -> Data? {
        guard count >= 0, offset + count <= data.endIndex else { return nil }
        defer { offset += count }
        return data[offset..<(offset + count)]
    }

    private mutating func readInteger<T: FixedWidthInteger>() -> T? {
        guard let bytes = readData(count: MemoryLayout<T>.size) else { return nil }
        return bytes.reduce(T.zero) { ($0 << 8) | T($1) }
    }
}
