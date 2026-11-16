import Foundation

/// Android's own RSA public key format, which is what `adbd` stores for a
/// paired host and compares the TLS client certificate against.
///
/// It is not DER. It is a little-endian C struct carrying the modulus plus two
/// precomputed Montgomery constants, base64-encoded and followed by a name:
///
///     uint32 modulusSizeInWords      (64 for RSA-2048)
///     uint32 n0inv                   (-1 / n[0] mod 2^32)
///     uint8  modulus[256]            (little-endian)
///     uint8  rr[256]                 ((2^2048)^2 mod n, little-endian)
///     uint32 exponent
enum AdbPublicKey {
    static let modulusBytes = 256

    static func encode(modulusBigEndian: [UInt8], exponent: UInt32, name: String) -> String {
        Data(structure(modulusBigEndian: modulusBigEndian, exponent: exponent)).base64EncodedString()
            + " " + name
    }

    static func structure(modulusBigEndian: [UInt8], exponent: UInt32) -> [UInt8] {
        let modulus = BigUInt(bigEndian: modulusBigEndian)

        // Newton iteration for the inverse of an odd number modulo 2^32; each
        // step doubles the number of correct bits, so five steps are plenty.
        let n0 = modulus.lowWord
        var inverse = n0
        for _ in 0..<5 {
            inverse = inverse &* (2 &- n0 &* inverse)
        }
        let n0inv = 0 &- inverse

        // rr = 2^4096 mod n, by doubling 4096 times and subtracting whenever
        // the value reaches the modulus.
        var rr = BigUInt.one
        for _ in 0..<(modulusBytes * 8 * 2) {
            rr = rr << 1
            if rr >= modulus {
                rr = rr - modulus
            }
        }

        var out: [UInt8] = []
        out.reserveCapacity(4 + 4 + modulusBytes * 2 + 4)
        out += littleEndian(UInt32(modulusBytes / 4))
        out += littleEndian(n0inv)
        out += modulus.littleEndianBytes(count: modulusBytes)
        out += rr.littleEndianBytes(count: modulusBytes)
        out += littleEndian(exponent)
        return out
    }

    private static func littleEndian(_ value: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24),
        ]
    }
}

/// Just enough DER to read an RSA public key and to write one certificate.
enum DER {
    static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var remaining = count
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xff), at: 0)
            remaining >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + length(content.count) + content
    }

    static func sequence(_ parts: [[UInt8]]) -> [UInt8] { tlv(0x30, parts.flatMap { $0 }) }
    static func set(_ parts: [[UInt8]]) -> [UInt8] { tlv(0x31, parts.flatMap { $0 }) }
    static func oid(_ encoded: [UInt8]) -> [UInt8] { tlv(0x06, encoded) }
    static let null: [UInt8] = [0x05, 0x00]
    static func utf8(_ text: String) -> [UInt8] { tlv(0x0c, Array(text.utf8)) }
    static func bitString(_ bytes: [UInt8]) -> [UInt8] { tlv(0x03, [0x00] + bytes) }

    /// A non-negative INTEGER: leading zeros stripped, one added back when the
    /// top bit would otherwise make it negative.
    static func integer(_ bigEndian: [UInt8]) -> [UInt8] {
        var bytes = Array(bigEndian.drop { $0 == 0 })
        if bytes.isEmpty { bytes = [0] }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(0x02, bytes)
    }

    static func utcTime(_ date: Date) -> [UInt8] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return tlv(0x17, Array(formatter.string(from: date).utf8))
    }

    // Object identifiers, already in their encoded form.
    static let sha256WithRSAEncryption: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b]
    static let rsaEncryption: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]
    static let commonName: [UInt8] = [0x55, 0x04, 0x03]

    /// Reads one TLV at `offset`, returning its tag, content and the next offset.
    static func read(_ bytes: [UInt8], at offset: Int) -> (tag: UInt8, content: [UInt8], next: Int)? {
        guard offset + 2 <= bytes.count else { return nil }
        let tag = bytes[offset]
        var index = offset + 1
        var count = Int(bytes[index])
        index += 1
        if count & 0x80 != 0 {
            let lengthBytes = count & 0x7f
            guard lengthBytes > 0, lengthBytes <= 4, index + lengthBytes <= bytes.count else { return nil }
            count = 0
            for _ in 0..<lengthBytes {
                count = (count << 8) | Int(bytes[index])
                index += 1
            }
        }
        guard index + count <= bytes.count else { return nil }
        return (tag, Array(bytes[index..<(index + count)]), index + count)
    }

    /// Parses a PKCS#1 `RSAPublicKey ::= SEQUENCE { modulus, publicExponent }`,
    /// which is what `SecKeyCopyExternalRepresentation` returns for an RSA key.
    static func rsaPublicKey(_ pkcs1: [UInt8]) -> (modulus: [UInt8], exponent: UInt32)? {
        guard let outer = read(pkcs1, at: 0), outer.tag == 0x30,
              let modulus = read(outer.content, at: 0), modulus.tag == 0x02,
              let exponent = read(outer.content, at: modulus.next), exponent.tag == 0x02
        else { return nil }
        let modulusBytes = Array(modulus.content.drop { $0 == 0 })
        var value: UInt32 = 0
        for byte in exponent.content.drop(while: { $0 == 0 }) {
            guard value <= 0x00ff_ffff else { return nil }
            value = (value << 8) | UInt32(byte)
        }
        return (modulusBytes, value)
    }

    /// The to-be-signed part of a minimal self-signed X.509 v3 certificate.
    static func tbsCertificate(
        pkcs1PublicKey: [UInt8],
        commonName name: String,
        serial: [UInt8],
        notBefore: Date,
        notAfter: Date
    ) -> [UInt8] {
        let algorithm = sequence([oid(sha256WithRSAEncryption), null])
        let subject = sequence([set([sequence([oid(commonName), utf8(name)])])])
        let subjectPublicKeyInfo = sequence([
            sequence([oid(rsaEncryption), null]),
            bitString(pkcs1PublicKey),
        ])
        return sequence([
            tlv(0xa0, integer([2])),              // [0] EXPLICIT version v3
            integer(serial),
            algorithm,
            subject,                              // issuer: self-signed
            sequence([utcTime(notBefore), utcTime(notAfter)]),
            subject,
            subjectPublicKeyInfo,
        ])
    }

    static func certificate(tbs: [UInt8], signature: [UInt8]) -> [UInt8] {
        sequence([
            tbs,
            sequence([oid(sha256WithRSAEncryption), null]),
            bitString(signature),
        ])
    }
}
