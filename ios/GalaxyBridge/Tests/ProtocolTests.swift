import XCTest

/// These mirror `ProtocolTest.kt`: if one side changes the wire format, one of
/// the two suites fails instead of the link quietly breaking on a real device.
///
/// The protocol sources are compiled into this bundle directly, so the suite
/// runs without launching the app.
final class ProtocolTests: XCTestCase {

    func testSingleFrameRoundTrip() throws {
        let payload = Data("hello watch".utf8)
        let frames = Frame.fragment(type: .hello, seq: 7, payload: payload, maxPayload: 180, encrypted: false)
        XCTAssertEqual(frames.count, 1)
        let result = Reassembler().offer(frames[0])
        let unwrapped = try XCTUnwrap(result)
        XCTAssertEqual(unwrapped.0.type, .hello)
        XCTAssertEqual(unwrapped.0.seq, 7)
        XCTAssertEqual(unwrapped.1, payload)
    }

    func testFragmentedFramesReassemble() throws {
        let payload = Data((0..<500).map { UInt8($0 % 251) })
        let frames = Frame.fragment(
            type: .healthBatch,
            seq: 42,
            payload: payload,
            maxPayload: 180,
            encrypted: false
        )
        XCTAssertEqual(frames.count, 3)
        let reassembler = Reassembler()
        XCTAssertNil(reassembler.offer(frames[0]))
        XCTAssertNil(reassembler.offer(frames[1]))
        let result = try XCTUnwrap(reassembler.offer(frames[2]))
        XCTAssertEqual(result.1, payload)
    }

    func testTruncatedFrameIsRejected() {
        let frames = Frame.fragment(
            type: .ping,
            seq: 1,
            payload: Data(count: 40),
            maxPayload: 180,
            encrypted: false
        )
        XCTAssertNil(Frame.header(frames[0].prefix(20)))
    }

    func testCryptoRoundTrip() throws {
        let salt = Data((0..<16).map(UInt8.init))
        let key = SessionCrypto.deriveKey(pairingCode: "418293", salt: salt)
        var tx = SessionCrypto(key: key, directionTag: SessionCrypto.tagWatchToPhone)
        let rx = SessionCrypto(key: key, directionTag: SessionCrypto.tagWatchToPhone)
        let plain = Data("steps=1234".utf8)
        XCTAssertEqual(try rx.open(try tx.seal(plain)), plain)
        XCTAssertEqual(try rx.open(try tx.seal(plain)), plain)
    }

    /// The derived key must match the Kotlin side for the same code and salt.
    func testKeyDerivationIsDeterministic() {
        let salt = Data((0..<16).map(UInt8.init))
        let first = SessionCrypto.deriveKey(pairingCode: "000000", salt: salt)
        let second = SessionCrypto.deriveKey(pairingCode: "000000", salt: salt)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 32)
        XCTAssertNotEqual(first, SessionCrypto.deriveKey(pairingCode: "000001", salt: salt))
    }

    func testHealthBatchDecoding() throws {
        let json = """
        {"samples":[{"metric":"STEPS","value":1234.0,"start":1,"end":2,"uid":"abc"}],"cursor":9}
        """
        let batch = try XCTUnwrap(BridgeCoder.decode(HealthBatch.self, from: Data(json.utf8)))
        XCTAssertEqual(batch.cursor, 9)
        XCTAssertEqual(batch.samples.first?.metric, .steps)
        XCTAssertEqual(batch.samples.first?.value, 1234.0)
    }
}

/// Cross-platform key agreement.
///
/// `ProtocolTest.kt` asserts these same bytes. Two suites that only check
/// themselves can agree on a wrong answer; a shared known-answer vector is what
/// proves the watch and the phone derive the same key.
final class KeyDerivationTests: XCTestCase {

    func testLongTermAndSessionKeysMatchTheSharedVector() {
        let salt = Data((0..<16).map(UInt8.init))
        let session = Data((16..<32).map(UInt8.init))
        let longTerm = SessionCrypto.deriveKey(pairingCode: "418293", salt: salt)
        XCTAssertEqual(
            longTerm.map { String(format: "%02x", $0) }.joined(),
            "4c573483598ef328facd02192212cfd85444e6b83639d44475486f60687d0529"
        )
        XCTAssertEqual(SessionCrypto.fingerprint(longTerm), "12CF62FD")
        XCTAssertEqual(
            SessionCrypto.deriveSessionKey(longTermKey: longTerm, sessionNonce: session)
                .map { String(format: "%02x", $0) }.joined(),
            "a23a102cb3635cefc293410827bccd72f96f7c7f75f9d84c80293883ec89f63f"
        )
    }

    func testANewSessionNonceGivesAnUnrelatedKey() {
        let longTerm = SessionCrypto.deriveKey(pairingCode: "418293", salt: Data(count: 16))
        let first = SessionCrypto.deriveSessionKey(
            longTermKey: longTerm,
            sessionNonce: Data(repeating: 1, count: 16)
        )
        let second = SessionCrypto.deriveSessionKey(
            longTermKey: longTerm,
            sessionNonce: Data(repeating: 2, count: 16)
        )
        XCTAssertEqual(first.count, 32)
        XCTAssertNotEqual(first, second)
    }
}

/// The big-integer and curve code behind a future ADB client.
///
/// `docs/ADB_FROM_IOS.md` explains why the client is not finished. These parts
/// are the ones worth proving correct now, against BoringSSL's own output,
/// rather than discovering they were wrong on a watch much later.
final class Spake2Tests: XCTestCase {

    private func hex(_ text: String) -> [UInt8] { EdwardsPoint.bytes(hex: text) }

    func testBigIntegerModuloAndShift() {
        let value = BigUInt(hex: "ffffffffffffffffffffffff")
        XCTAssertEqual(value.mod(BigUInt(1000)).lowWord, 335)
        XCTAssertEqual((BigUInt(1) << 64).bitWidth, 65)
        XCTAssertEqual(((BigUInt(1) << 64) >> 64), BigUInt.one)
        XCTAssertEqual((BigUInt(hex: "0100000000") - BigUInt.one).bitWidth, 32)
    }

    func testPointsRoundTripThroughTheirEncoding() throws {
        let encodedM = "5ada7e4bf6ddd9adb6626d32131c6b5c51a1e347a3478f53cfcf441b88eed12e"
        let point = try XCTUnwrap(EdwardsPoint(encoded: hex(encodedM)))
        XCTAssertEqual(point.encoded.map { String(format: "%02x", $0) }.joined(), encodedM)
        // Adding a point to its own negation must give the identity.
        XCTAssertEqual(point.adding(point.negated).encoded, EdwardsPoint.identity.encoded)
    }

    /// The `aosp-adb-names` exchange from BoringSSL's deterministic harness,
    /// with the names `adb pair client` and `adb pair server` that adbd uses.
    func testMatchesTheBoringSSLVectorForAdbNames() throws {
        var alice = Spake2(
            role: .alice,
            myName: hex("616462207061697220636c69656e7400"),
            theirName: hex("61646220706169722073657276657200")
        )
        var entropy = [UInt8](repeating: 0, count: 64)
        entropy[0] = 1
        let message = alice.generateMessage(password: hex("353135313039"), random: entropy)
        XCTAssertEqual(
            message.map { String(format: "%02x", $0) }.joined(),
            "1876811ed2c78beb885abcfeee9174e822e056d67474d7f924e5c019d087dc71"
        )
        let key = try XCTUnwrap(
            alice.processMessage(hex("e814a51e5e1032ce32bd9e47f74fb58a42f02b61b355e062a36836dbd8de35c5"))
        )
        XCTAssertEqual(
            key.map { String(format: "%02x", $0) }.joined(),
            "5c1a3ba6d4176e4f1cce1b33d22d10ea5c94078c35d6adde6b01365f0df35d1f"
                + "50b7a5ad6910bfc17295e5d1969e502a6141cdc5c7e2cc99b238d786c9275865"
        )
    }

    func testRejectsAMessageThatIsNotAPoint() {
        var context = Spake2(role: .alice, myName: [], theirName: [])
        _ = context.generateMessage(password: [1], random: [UInt8](repeating: 7, count: 64))
        XCTAssertNil(context.processMessage([UInt8](repeating: 0x42, count: 31)))
    }

    /// Android's public key format, with the Montgomery constants it expects.
    func testAdbPublicKeyStructure() {
        var modulus = [UInt8](repeating: 0, count: 256)
        for index in 0..<256 { modulus[index] = UInt8((index * 37 + 11) & 0xff) }
        modulus[0] |= 0x80
        modulus[255] |= 1
        let blob = AdbPublicKey.structure(modulusBigEndian: modulus, exponent: 65537)
        XCTAssertEqual(blob.count, 524)
        XCTAssertEqual(Array(blob[0...3]), [64, 0, 0, 0])
        XCTAssertEqual(Array(blob[4...7]).map { String(format: "%02x", $0) }.joined(), "293eb917")
        XCTAssertEqual(
            Array(blob[520...523]).map { String(format: "%02x", $0) }.joined(),
            "01000100"
        )
    }
}
