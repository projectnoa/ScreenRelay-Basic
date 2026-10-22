//
//  Pairing.swift
//  ScreenRelay
//
//  Who this Mac is, which Macs it has been paired with, and the cryptography of the
//  connection handshake.
//
//  Pairing happens once: the target shows a 6-digit code, the host's user types it,
//  and the target hands the host a random 256-bit key. Every later connection is
//  authenticated in both directions with that key (HMAC-SHA256 over fresh nonces):
//  the target only shows pictures from a paired host, and the host only streams its
//  screen to a target that proves it is the paired one.
//

import Foundation
import CryptoKit
import Security

nonisolated enum DeviceIdentity {
    /// A stable, random identifier for this Mac's ScreenRelay installation.
    static let id: UUID = {
        let key = "deviceID"
        if let stored = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: stored) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }()

    static var name: String { Host.current().localizedName ?? "Mac" }
}

/// Pairing keys, kept in the login keychain (one item per paired Mac).
nonisolated enum PairingStore {
    struct Peer: Identifiable, Hashable {
        let id: UUID
        let name: String
    }

    private static let service = "com.buildthestack.ScreenRelay.pairing"

    static func key(for peer: UUID) -> SymmetricKey? {
        var query = baseQuery(peer)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    static func save(_ key: SymmetricKey, for peer: UUID, name: String) {
        remove(peer)
        var item = baseQuery(peer)
        item[kSecAttrLabel as String] = "ScreenRelay pairing with \(name)"
        item[kSecAttrDescription as String] = name
        item[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { print("[Pairing] Couldn't store key: \(status)") }
    }

    static func remove(_ peer: UUID) {
        SecItemDelete(baseQuery(peer) as CFDictionary)
    }

    static func peers() -> [Peer] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String, let id = UUID(uuidString: account) else { return nil }
            return Peer(id: id, name: item[kSecAttrDescription as String] as? String ?? "Unknown Mac")
        }
        .sorted { $0.name < $1.name }
    }

    private static func baseQuery(_ peer: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: peer.uuidString]
    }
}

/// The handshake's cryptography. Labels bind each proof to its role, so a host proof
/// can't be replayed as a target proof, and fresh nonces from both sides stop replays
/// of whole sessions.
nonisolated enum Handshake {
    static let nonceLength = 32
    static let macLength = 32

    static func nonce() -> Data { randomBytes(nonceLength) }

    static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return data
    }

    static func newPairingKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    /// A 6-digit code shown on the target during pairing.
    static func pairingCode() -> String {
        String(format: "%06d", Int.random(in: 0..<1_000_000))
    }

    /// Host proves it holds the pairing key.
    static func hostProof(key: SymmetricKey, targetNonce: Data, hostNonce: Data, targetID: UUID, hostID: UUID) -> Data {
        mac(key, "ScreenRelay host v1", targetNonce, hostNonce, targetID.data, hostID.data)
    }

    /// Target proves it holds the pairing key.
    static func targetProof(key: SymmetricKey, targetNonce: Data, hostNonce: Data, targetID: UUID, hostID: UUID) -> Data {
        mac(key, "ScreenRelay target v1", hostNonce, targetNonce, hostID.data, targetID.data)
    }

    /// Key derived from the pairing code and both nonces; proves the host's user typed the
    /// right code and wraps the new pairing key for transfer.
    static func codeKey(code: String, targetNonce: Data, hostNonce: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(code.utf8)),
                               salt: targetNonce + hostNonce,
                               info: Data("ScreenRelay pairing v1".utf8), outputByteCount: 32)
    }

    static func codeProof(codeKey: SymmetricKey, hostID: UUID) -> Data {
        mac(codeKey, "ScreenRelay code v1", hostID.data)
    }

    static func wrap(_ key: SymmetricKey, with codeKey: SymmetricKey) -> Data? {
        try? ChaChaPoly.seal(key.withUnsafeBytes { Data($0) }, using: codeKey).combined
    }

    static func unwrap(_ sealed: Data, with codeKey: SymmetricKey) -> SymmetricKey? {
        guard let box = try? ChaChaPoly.SealedBox(combined: sealed),
              let data = try? ChaChaPoly.open(box, using: codeKey), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    /// Constant-time comparison of a received proof with the expected one.
    static func matches(_ received: Data, _ expected: Data) -> Bool {
        guard received.count == expected.count else { return false }
        return zip(received, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func mac(_ key: SymmetricKey, _ label: String, _ parts: Data...) -> Data {
        var hmac = HMAC<SHA256>(key: key)
        hmac.update(data: Data(label.utf8))
        for part in parts { hmac.update(data: part) }
        return Data(hmac.finalize())
    }
}

nonisolated extension UUID {
    var data: Data { withUnsafeBytes(of: uuid) { Data($0) } }

    init?(data: Data) {
        guard data.count == 16 else { return nil }
        let bytes = Array(data)
        self.init(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                         bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
