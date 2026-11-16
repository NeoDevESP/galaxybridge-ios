import CryptoKit
import Foundation

/// Swift counterpart of `Crypto.kt`. Same HKDF step, same nonce layout, same
/// AES-GCM parameters: a mismatch here shows up as "decrypt failed" on the
/// watch, so both sides are covered by the same test vector.
struct SessionCrypto {
    static let tagWatchToPhone = Data([0x57, 0x32, 0x50, 0x00])   // "W2P\0"
    static let tagPhoneToWatch = Data([0x50, 0x32, 0x57, 0x00])   // "P2W\0"

    private let key: SymmetricKey
    private let directionTag: Data
    private var counter: UInt64 = 0

    init(key: Data, directionTag: Data) {
        precondition(key.count == 32, "AES-256 key expected")
        precondition(directionTag.count == 4, "4-byte direction tag expected")
        self.key = SymmetricKey(data: key)
        self.directionTag = directionTag
    }

    /// Returns 8-byte counter || ciphertext || 16-byte tag.
    mutating func seal(_ plaintext: Data) throws -> Data {
        let current = counter
        counter += 1
        let counterBytes = Self.counterBytes(current)
        let nonce = try AES.GCM.Nonce(data: directionTag + counterBytes)
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        return counterBytes + box.ciphertext + box.tag
    }

    func open(_ sealed: Data) throws -> Data {
        guard sealed.count > 8 + 16 else { throw CryptoError.short }
        let counterBytes = sealed.prefix(8)
        let rest = sealed.dropFirst(8)
        let ciphertext = rest.dropLast(16)
        let tag = rest.suffix(16)
        let nonce = try AES.GCM.Nonce(data: directionTag + Data(counterBytes))
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: Data(ciphertext), tag: Data(tag))
        return try AES.GCM.open(box, using: key)
    }

    static let sessionLabel = "GalaxyBridge/session"
    static let sessionNonceSize = 16
    static let saltSize = 16

    /// Traffic key for one session: HMAC-SHA256 over the session nonce, keyed
    /// with the long-term key. The watch issues a fresh nonce on every read of
    /// its control characteristic, so both counters can restart at zero without
    /// ever reusing a (key, nonce) pair in GCM. Mirrors `deriveSessionKey` in
    /// `Crypto.kt`, and both suites assert the same vector.
    static func deriveSessionKey(longTermKey: Data, sessionNonce: Data) -> Data {
        var input = Data(sessionLabel.utf8)
        input.append(sessionNonce)
        return Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: longTermKey)))
    }

    /// One-block HKDF-SHA256, matching the Kotlin implementation exactly.
    static func deriveKey(pairingCode: String, salt: Data, info: String = "GalaxyBridge/v1") -> Data {
        let prk = HMAC<SHA256>.authenticationCode(
            for: Data(pairingCode.utf8),
            using: SymmetricKey(data: salt)
        )
        var infoData = Data(info.utf8)
        infoData.append(0x01)
        let okm = HMAC<SHA256>.authenticationCode(
            for: infoData,
            using: SymmetricKey(data: Data(prk))
        )
        return Data(okm)
    }

    static func fingerprint(_ key: Data) -> String {
        Data(SHA256.hash(data: key)).prefix(4).map { String(format: "%02X", $0) }.joined()
    }

    private static func counterBytes(_ value: UInt64) -> Data {
        var out = Data(count: 8)
        for index in 0..<8 {
            out[index] = UInt8((value >> (8 * (7 - UInt64(index)))) & 0xFF)
        }
        return out
    }

    enum CryptoError: Error {
        case short
    }
}
