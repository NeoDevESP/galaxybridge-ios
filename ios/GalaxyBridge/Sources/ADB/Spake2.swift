import CryptoKit
import Foundation

/// Arithmetic in the field of integers modulo 2^255 - 19.
enum Field25519 {
    static let p = (BigUInt.one << 255) - BigUInt(19)
    private static let nineteen = BigUInt(19)

    /// Reduces a value below `p`. 2^255 is congruent to 19, so the bits above
    /// position 255 fold back in multiplied by 19.
    static func reduce(_ value: BigUInt) -> BigUInt {
        var v = value
        while v.bitWidth > 255 {
            v = v.lowBits(255) + (v >> 255) * nineteen
        }
        if v >= p {
            v = v - p
        }
        return v
    }

    static func add(_ a: BigUInt, _ b: BigUInt) -> BigUInt { reduce(a + b) }

    /// Both operands must already be reduced.
    static func sub(_ a: BigUInt, _ b: BigUInt) -> BigUInt { reduce(a + p - b) }

    static func mul(_ a: BigUInt, _ b: BigUInt) -> BigUInt { reduce(a * b) }

    static func pow(_ base: BigUInt, _ exponent: BigUInt) -> BigUInt {
        var result = BigUInt.one
        var index = exponent.bitWidth - 1
        while index >= 0 {
            result = mul(result, result)
            if exponent.bit(index) {
                result = mul(result, base)
            }
            index -= 1
        }
        return result
    }

    static func inverse(_ a: BigUInt) -> BigUInt { pow(a, p - BigUInt(2)) }
}

/// A point on edwards25519 in extended coordinates (X : Y : Z : T), with
/// x = X/Z, y = Y/Z and xy = T/Z.
struct EdwardsPoint: Sendable {
    var x: BigUInt
    var y: BigUInt
    var z: BigUInt
    var t: BigUInt

    private typealias F = Field25519

    static let identity = EdwardsPoint(x: .zero, y: .one, z: .one, t: .zero)

    /// Curve constant d = -121665/121666.
    static let d = BigUInt(hex: "52036cee2b6ffe738cc740797779e89800700a4d4141d8ab75eb4dca135978a3")
    private static let twoD = F.add(d, d)

    /// A square root of -1, used when recovering x from y.
    private static let sqrtMinusOne =
        BigUInt(hex: "2b8324804fc1df0b2b4d00993dfbd7a72f431806ad2fe478c4ee1b274a0ea0b0")

    /// The standard base point, y = 4/5 with even x.
    static let base = EdwardsPoint(
        encoded: Self.bytes(hex: "5866666666666666666666666666666666666666666666666666666666666666")
    )!

    /// Unified addition for a = -1 twisted Edwards curves. It is complete on
    /// edwards25519, so the same formula doubles a point.
    func adding(_ other: EdwardsPoint) -> EdwardsPoint {
        let a = F.mul(F.sub(y, x), F.sub(other.y, other.x))
        let b = F.mul(F.add(y, x), F.add(other.y, other.x))
        let c = F.mul(F.mul(t, Self.twoD), other.t)
        let d = F.mul(F.add(z, z), other.z)
        let e = F.sub(b, a)
        let f = F.sub(d, c)
        let g = F.add(d, c)
        let h = F.add(b, a)
        return EdwardsPoint(x: F.mul(e, f), y: F.mul(g, h), z: F.mul(f, g), t: F.mul(e, h))
    }

    var negated: EdwardsPoint {
        EdwardsPoint(x: F.sub(.zero, x), y: y, z: z, t: F.sub(.zero, t))
    }

    /// Plain double-and-add. The scalar may exceed the group order, which the
    /// SPAKE2 password scalar deliberately does.
    func multiplied(by scalar: BigUInt) -> EdwardsPoint {
        var result = EdwardsPoint.identity
        var addend = self
        let width = scalar.bitWidth
        var index = 0
        while index < width {
            if scalar.bit(index) {
                result = result.adding(addend)
            }
            addend = addend.adding(addend)
            index += 1
        }
        return result
    }

    /// The 32-byte encoding: y little-endian, with the low bit of x in the top bit.
    var encoded: [UInt8] {
        let inverseZ = F.inverse(z)
        let affineX = F.mul(x, inverseZ)
        let affineY = F.mul(y, inverseZ)
        var bytes = affineY.littleEndianBytes(count: 32)
        if affineX.bit(0) {
            bytes[31] |= 0x80
        }
        return bytes
    }

    /// Decodes a point, or returns nil when the bytes are not on the curve.
    init?(encoded bytes: [UInt8]) {
        guard bytes.count == 32 else { return nil }
        var yBytes = bytes
        let sign = (yBytes[31] & 0x80) != 0
        yBytes[31] &= 0x7f
        let y = BigUInt(littleEndian: yBytes)
        guard y < F.p else { return nil }

        let ySquared = F.mul(y, y)
        let u = F.sub(ySquared, .one)
        let v = F.add(F.mul(Self.d, ySquared), .one)

        // x = u v^3 (u v^7)^((p-5)/8), then fix up with sqrt(-1) if needed.
        let v3 = F.mul(F.mul(v, v), v)
        let v7 = F.mul(F.mul(v3, v3), v)
        let exponent = (F.p - BigUInt(5)) >> 3
        var x = F.mul(F.mul(u, v3), F.pow(F.mul(u, v7), exponent))

        let check = F.mul(v, F.mul(x, x))
        if check != u {
            guard check == F.sub(.zero, u) else { return nil }
            x = F.mul(x, Self.sqrtMinusOne)
        }
        if x.isZero && sign { return nil }
        if x.bit(0) != sign {
            x = F.sub(.zero, x)
        }
        self.init(x: x, y: y, z: .one, t: F.mul(x, y))
    }

    init(x: BigUInt, y: BigUInt, z: BigUInt, t: BigUInt) {
        self.x = x
        self.y = y
        self.z = z
        self.t = t
    }

    static func bytes(hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            out.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return out
    }
}

/// SPAKE2 exactly as BoringSSL implements it, which is what `adbd` speaks.
///
/// This is a port of `crypto/curve25519/spake25519.cc`, quirks included: the
/// private scalar is multiplied by the cofactor, the password scalar gets
/// multiples of the group order added until its low three bits are clear, and
/// the transcript is length-prefixed with 8-byte little-endian lengths. A
/// textbook SPAKE2 would derive a different key and the watch would simply
/// report a wrong pairing code, so the tests replay BoringSSL's own vectors.
struct Spake2 {
    enum Role { case alice, bob }

    /// Order of the prime-order subgroup.
    static let order = BigUInt(hex: "1000000000000000000000000000000014def9dea2f79cd65812631a5cf5d3ed")

    private static let pointM = EdwardsPoint(
        encoded: EdwardsPoint.bytes(hex: "5ada7e4bf6ddd9adb6626d32131c6b5c51a1e347a3478f53cfcf441b88eed12e")
    )!
    private static let pointN = EdwardsPoint(
        encoded: EdwardsPoint.bytes(hex: "10e3df0ae37d8e7a99b5fe74b44672103dbddcbd06af680d71329a11693bc778")
    )!

    private let role: Role
    private let myName: [UInt8]
    private let theirName: [UInt8]

    private var privateScalar = BigUInt.zero
    private var passwordScalar = BigUInt.zero
    private var passwordHash: [UInt8] = []
    private var myMessage: [UInt8] = []

    init(role: Role, myName: [UInt8], theirName: [UInt8]) {
        self.role = role
        self.myName = myName
        self.theirName = theirName
    }

    /// Produces this side's 32-byte message. `random` is 64 bytes of entropy
    /// and is only passed explicitly by the tests.
    mutating func generateMessage(password: [UInt8], random: [UInt8]? = nil) -> [UInt8] {
        let entropy = random ?? (0..<64).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }

        // Reduce, then multiply by the cofactor so small-order components of
        // the peer's point vanish later.
        privateScalar = (BigUInt(littleEndian: entropy).mod(Self.order) << 3).lowBits(256)

        passwordHash = Array(SHA512.hash(data: Data(password)))
        var scalar = BigUInt(littleEndian: passwordHash).mod(Self.order)

        // BoringSSL's unilateral fix for a missing cofactor multiplication:
        // add the order, twice the order and four times the order as needed so
        // the scalar becomes a multiple of eight without changing the point.
        if scalar.bit(0) { scalar = scalar + Self.order }
        if scalar.bit(1) { scalar = scalar + (Self.order << 1) }
        if scalar.bit(2) { scalar = scalar + (Self.order << 2) }
        passwordScalar = scalar

        let mask = (role == .alice ? Self.pointM : Self.pointN).multiplied(by: passwordScalar)
        let masked = EdwardsPoint.base.multiplied(by: privateScalar).adding(mask)
        myMessage = masked.encoded
        return myMessage
    }

    /// Consumes the peer's message and returns the 64-byte shared key, or nil
    /// when the message is not a valid point. A wrong password does not fail
    /// here; it yields a different key, and the mismatch shows up when the
    /// first encrypted packet fails to authenticate.
    func processMessage(_ theirMessage: [UInt8]) -> [UInt8]? {
        guard theirMessage.count == 32, !myMessage.isEmpty,
              let theirPoint = EdwardsPoint(encoded: theirMessage) else { return nil }

        let peersMask = (role == .alice ? Self.pointN : Self.pointM).multiplied(by: passwordScalar)
        let unmasked = theirPoint.adding(peersMask.negated)
        let shared = unmasked.multiplied(by: privateScalar).encoded

        var hasher = SHA512()
        func update(_ bytes: [UInt8]) {
            var length = UInt64(bytes.count).littleEndian
            withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
            hasher.update(data: Data(bytes))
        }
        if role == .alice {
            update(myName)
            update(theirName)
            update(myMessage)
            update(theirMessage)
        } else {
            update(theirName)
            update(myName)
            update(theirMessage)
            update(myMessage)
        }
        update(shared)
        update(passwordHash)
        return Array(hasher.finalize())
    }
}
