import Foundation

/// A small unsigned big integer.
///
/// ADB needs two pieces of arithmetic iOS does not expose: point operations on
/// edwards25519 for the pairing handshake (CryptoKit only offers signing and key
/// agreement, not the raw group), and Montgomery constants for Android's RSA
/// public key format. Both need a few hundred multi-word operations per pairing,
/// so a plain schoolbook implementation is more than fast enough, and being
/// plain is the point: it can be read, and it is checked against BoringSSL
/// vectors in the tests.
///
/// It is not constant-time and must not be used for long-lived secrets. The
/// only secrets that pass through it are a single-use pairing scalar and a
/// six-digit code that is already on the watch's screen.
struct BigUInt: Equatable, Comparable, Sendable {

    /// Little-endian 32-bit limbs with no trailing zero limb.
    private(set) var limbs: [UInt32]

    static let zero = BigUInt(limbs: [])
    static let one = BigUInt(1)

    private init(limbs: [UInt32]) {
        self.limbs = limbs
        normalize()
    }

    init(_ value: UInt64) {
        limbs = [UInt32(truncatingIfNeeded: value), UInt32(truncatingIfNeeded: value >> 32)]
        normalize()
    }

    init(littleEndian bytes: [UInt8]) {
        var out = [UInt32](repeating: 0, count: (bytes.count + 3) / 4)
        for (index, byte) in bytes.enumerated() {
            out[index / 4] |= UInt32(byte) << UInt32(8 * (index % 4))
        }
        limbs = out
        normalize()
    }

    init(bigEndian bytes: [UInt8]) {
        self.init(littleEndian: bytes.reversed())
    }

    /// Big-endian hexadecimal, as constants are usually written.
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bigEndian: bytes)
    }

    private mutating func normalize() {
        while let last = limbs.last, last == 0 {
            limbs.removeLast()
        }
    }

    var isZero: Bool { limbs.isEmpty }

    var bitWidth: Int {
        guard let last = limbs.last else { return 0 }
        return limbs.count * 32 - last.leadingZeroBitCount
    }

    var lowWord: UInt32 { limbs.first ?? 0 }

    func bit(_ index: Int) -> Bool {
        let limb = index / 32
        guard limb < limbs.count else { return false }
        return (limbs[limb] >> UInt32(index % 32)) & 1 == 1
    }

    func littleEndianBytes(count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        for index in 0..<count {
            let limb = index / 4
            if limb < limbs.count {
                out[index] = UInt8(truncatingIfNeeded: limbs[limb] >> UInt32(8 * (index % 4)))
            }
        }
        return out
    }

    func bigEndianBytes(count: Int) -> [UInt8] {
        littleEndianBytes(count: count).reversed()
    }

    // MARK: - Comparison

    static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
        if lhs.limbs.count != rhs.limbs.count {
            return lhs.limbs.count < rhs.limbs.count
        }
        var index = lhs.limbs.count - 1
        while index >= 0 {
            if lhs.limbs[index] != rhs.limbs[index] {
                return lhs.limbs[index] < rhs.limbs[index]
            }
            index -= 1
        }
        return false
    }

    // MARK: - Arithmetic

    static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        let count = max(lhs.limbs.count, rhs.limbs.count)
        var out = [UInt32]()
        out.reserveCapacity(count + 1)
        var carry: UInt64 = 0
        for index in 0..<count {
            let left = index < lhs.limbs.count ? UInt64(lhs.limbs[index]) : 0
            let right = index < rhs.limbs.count ? UInt64(rhs.limbs[index]) : 0
            let sum = left + right + carry
            out.append(UInt32(truncatingIfNeeded: sum))
            carry = sum >> 32
        }
        if carry != 0 {
            out.append(UInt32(carry))
        }
        return BigUInt(limbs: out)
    }

    /// Requires `lhs >= rhs`; there are no negative values here.
    static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        precondition(lhs >= rhs, "BigUInt subtraction would underflow")
        var out = lhs.limbs
        var borrow: Int64 = 0
        for index in 0..<out.count {
            let right = index < rhs.limbs.count ? Int64(rhs.limbs[index]) : 0
            var difference = Int64(out[index]) - right - borrow
            if difference < 0 {
                difference += 1 << 32
                borrow = 1
            } else {
                borrow = 0
            }
            out[index] = UInt32(difference)
        }
        return BigUInt(limbs: out)
    }

    static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        if lhs.isZero || rhs.isZero { return .zero }
        var out = [UInt32](repeating: 0, count: lhs.limbs.count + rhs.limbs.count)
        for i in 0..<lhs.limbs.count {
            var carry: UInt64 = 0
            let left = UInt64(lhs.limbs[i])
            for j in 0..<rhs.limbs.count {
                // (2^32-1) + (2^32-1)^2 + (2^32-1) = 2^64 - 1, so this never overflows.
                let current = UInt64(out[i + j]) + left * UInt64(rhs.limbs[j]) + carry
                out[i + j] = UInt32(truncatingIfNeeded: current)
                carry = current >> 32
            }
            out[i + rhs.limbs.count] = UInt32(carry)
        }
        return BigUInt(limbs: out)
    }

    static func << (value: BigUInt, shift: Int) -> BigUInt {
        if value.isZero || shift == 0 { return value }
        let limbShift = shift / 32
        let bitShift = UInt64(shift % 32)
        var out = [UInt32](repeating: 0, count: value.limbs.count + limbShift + 1)
        for index in 0..<value.limbs.count {
            let wide = UInt64(value.limbs[index]) << bitShift
            out[index + limbShift] |= UInt32(truncatingIfNeeded: wide)
            out[index + limbShift + 1] |= UInt32(truncatingIfNeeded: wide >> 32)
        }
        return BigUInt(limbs: out)
    }

    static func >> (value: BigUInt, shift: Int) -> BigUInt {
        let limbShift = shift / 32
        let bitShift = UInt32(shift % 32)
        guard limbShift < value.limbs.count else { return .zero }
        var out = [UInt32](repeating: 0, count: value.limbs.count - limbShift)
        for index in 0..<out.count {
            let low = value.limbs[index + limbShift] >> bitShift
            var high: UInt32 = 0
            if bitShift > 0 && index + limbShift + 1 < value.limbs.count {
                high = value.limbs[index + limbShift + 1] << (32 - bitShift)
            }
            out[index] = low | high
        }
        return BigUInt(limbs: out)
    }

    /// `self mod 2^count`.
    func lowBits(_ count: Int) -> BigUInt {
        let full = count / 32
        let remainder = UInt32(count % 32)
        if limbs.count <= full { return self }
        var out = Array(limbs.prefix(full + (remainder > 0 ? 1 : 0)))
        if remainder > 0 {
            out[full] &= (UInt32(1) << remainder) - 1
        }
        return BigUInt(limbs: out)
    }

    /// Binary long division, keeping only the remainder. Slow and obviously
    /// correct, which is the right trade for something called a few times.
    func mod(_ modulus: BigUInt) -> BigUInt {
        precondition(!modulus.isZero, "modulus must not be zero")
        if self < modulus { return self }
        var remainder = BigUInt.zero
        var index = bitWidth - 1
        while index >= 0 {
            remainder = remainder << 1
            if bit(index) {
                remainder = remainder + .one
            }
            if remainder >= modulus {
                remainder = remainder - modulus
            }
            index -= 1
        }
        return remainder
    }
}
