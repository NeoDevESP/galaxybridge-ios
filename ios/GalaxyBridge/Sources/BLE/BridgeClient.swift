import CoreBluetooth
import Foundation
import os

/// The iPhone side of the private bridge: a `CBCentralManager` that keeps a
/// connection to the watch's GATT server.
///
/// Three decisions here are what make it survive real use:
///
/// 1. `CBCentralManagerOptionRestoreIdentifierKey` plus the `bluetooth-central`
///    background mode let iOS relaunch the app into the background when the
///    watch reconnects. Without it the link only works while the app is open.
/// 2. `connect(_:)` is left outstanding forever. iOS keeps a pending connect
///    across range loss, so walking away and coming back reconnects with no
///    scanning and no battery cost. The scan runs *alongside* it rather than
///    instead of it: Android advertises from a resolvable private address that
///    rotates, so a saved identifier can name an address the watch no longer
///    uses, and waiting on it alone waits forever.
/// 3. Nothing is polled. Everything is event-driven, because Apple's guidance
///    is that a Bluetooth wake-up should do a short burst of work and return;
///    an app that keeps traffic alive to avoid suspension gets killed instead.
@MainActor
final class BridgeClient: NSObject, ObservableObject {

    @Published private(set) var isConnected = false
    @Published private(set) var isScanning = false
    @Published private(set) var mtu = 23
    @Published private(set) var lastError: String?
    @Published private(set) var keyFingerprint: String?
    /// What happened to the last code the user entered, in plain words.
    @Published private(set) var pairingStatus: String?
    @Published private(set) var media = MediaState(playing: false)
    @Published private(set) var telemetry: Telemetry?
    @Published private(set) var watchHello: Hello?
    /// The watch's workout while it records; cleared when updates stop.
    @Published private(set) var liveWorkout: WorkoutLive?
    private var liveWorkoutAt = Date.distantPast

    /// Called with a fully reassembled, decrypted message.
    var onMessage: ((MessageType, Data) -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?
    private var ctrlCharacteristic: CBCharacteristic?

    private let inbound = Reassembler()
    private var txCrypto: SessionCrypto?
    private var rxCrypto: SessionCrypto?
    private var seq: UInt16 = 0
    private var pendingWrites: [Data] = []
    private var scanDeadline: Timer?
    /// Peripherals with an outstanding connect. CoreBluetooth releases a
    /// peripheral nobody retains, which silently cancels the connect with it.
    private var candidates: [UUID: CBPeripheral] = [:]

    private let log = Logger(subsystem: "dev.galaxybridge.companion", category: "ble")
    private let defaults = UserDefaults.standard

    private var pairingCode: String? {
        get { defaults.string(forKey: "pairingCode") }
        set { defaults.set(newValue, forKey: "pairingCode") }
    }

    private var knownPeripheralID: UUID? {
        get { defaults.string(forKey: "peripheralID").flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: "peripheralID") }
    }

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: "dev.galaxybridge.central",
                CBCentralManagerOptionShowPowerAlertKey: true,
            ]
        )
    }

    // MARK: - Public API

    func setPairingCode(_ code: String) {
        pairingCode = code
        keyFingerprint = nil
        // A new code invalidates the derived key, so the control blob is read
        // again. If the watch has not been found yet there is nothing to read
        // from, and the UI has to say so instead of swallowing the tap.
        if let peripheral, let ctrlCharacteristic {
            lastError = nil
            pairingStatus = "Checking the code with the watch…"
            peripheral.readValue(for: ctrlCharacteristic)
        } else if peripheral == nil {
            pairingStatus = "Code saved. Waiting to find the watch over Bluetooth."
            start()
        } else {
            pairingStatus = "Code saved. Still discovering the watch's services."
        }
    }

    func start() {
        guard central.state == .poweredOn else { return }
        lastError = nil

        // Always scan, even with a saved identifier. retrievePeripherals hands
        // back a CBPeripheral for an identifier it has never seen on the air,
        // so returning early here left the app sitting on a pending connect to
        // a watch whose advertising address had since rotated, never looking
        // for the real one. A silent, permanent failure to connect.
        // Restarted, not just begun: a scan already running has reported the
        // watch once and will not report it again.
        if !isConnected { restartScan() }
        armKnownWatches()
    }

    /// Pending connects cost nothing, so fire one at every candidate and let
    /// whichever is real win the race. Includes a watch iOS is already linked
    /// to for notifications, which never shows up in a scan.
    private func armKnownWatches() {
        guard central.state == .poweredOn else { return }
        var known: [CBPeripheral] = central.retrieveConnectedPeripherals(
            withServices: [CBUUID(string: BridgeUUID.service)]
        )
        if let knownPeripheralID {
            known += central.retrievePeripherals(withIdentifiers: [knownPeripheralID])
        }
        for candidate in known where candidate.state != .connected {
            connect(candidate)
        }
    }

    /// Clears the saved watch and starts over: the escape hatch for a stale
    /// identifier, which the user otherwise has no way to get rid of.
    func forgetWatch() {
        knownPeripheralID = nil
        for candidate in candidates.values {
            central.cancelPeripheralConnection(candidate)
        }
        candidates.removeAll()
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        isConnected = false
        mtu = 23
        txCrypto = nil
        rxCrypto = nil
        keyFingerprint = nil
        inbound.reset()
        pairingStatus = "Looking for the watch from scratch."
        start()
    }

    private func beginScan() {
        guard !isScanning else { return }
        Breadcrumbs.drop("bt: scan started")
        isScanning = true
        central.scanForPeripherals(
            withServices: [CBUUID(string: BridgeUUID.service)],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        // A scan that finds nothing looks identical to a scan that was never
        // started, so after 25 seconds say so and name what to check.
        scanDeadline?.invalidate()
        scanDeadline = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isConnected, self.central.state == .poweredOn else { return }
                self.lastError = "No watch found in 25 s. Check that the watch status line shows ADV ok. If it does and this keeps happening, tap Forget this watch: a saved address goes stale when the watch rotates it."
                // Restart the scan rather than let it run on. With duplicates
                // filtered, iOS reports each watch once per scan: if that one
                // connect attempt failed (the watch was still starting up after
                // a restart) the scan never mentions it again and the app sat
                // on "Searching" for good.
                self.restartScan()
                self.armKnownWatches()
            }
        }
    }

    private func restartScan() {
        Breadcrumbs.drop("bt: restarting scan")
        if isScanning {
            central.stopScan()
            isScanning = false
        }
        beginScan()
    }

    func stop() {
        scanDeadline?.invalidate()
        if isScanning {
            central.stopScan()
            isScanning = false
        }
        for candidate in candidates.values {
            central.cancelPeripheralConnection(candidate)
        }
        candidates.removeAll()
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    func send(_ type: MessageType, payload: Data) {
        guard let peripheral, let rxCharacteristic else {
            log.debug("send dropped: not connected")
            return
        }
        guard var crypto = txCrypto else {
            // No session, no key. Sending in the clear would be refused by the
            // watch and would leak whatever this message carries.
            log.debug("no session yet, dropping \(String(describing: type), privacy: .public)")
            return
        }
        guard let body = try? crypto.seal(payload) else {
            log.error("seal failed for \(String(describing: type), privacy: .public)")
            return
        }
        txCrypto = crypto

        seq = seq &+ 1
        // One ATT packet per frame. The .withResponse limit is 512 whatever
        // the MTU, which made iOS fall back to long (prepared) writes for
        // every big fragment: slower, and older watch builds could not
        // reassemble them. The .withoutResponse limit is the real MTU - 3.
        // Never above 512: an attribute value cannot be longer, whatever the
        // MTU, and the watch would reject the frame.
        let maxPayload = max(
            20,
            min(peripheral.maximumWriteValueLength(for: .withoutResponse), 512) - Frame.headerSize
        )
        for frame in Frame.fragment(
            type: type,
            seq: seq,
            payload: body,
            maxPayload: maxPayload,
            encrypted: true
        ) {
            peripheral.writeValue(frame, for: rxCharacteristic, type: .withResponse)
        }
    }

    func sendTimeSync() {
        let sync = TimeSync(
            epochMillis: Int64(Date().timeIntervalSince1970 * 1000),
            monotonicNanos: Int64(DispatchTime.now().uptimeNanoseconds),
            timeZoneId: TimeZone.current.identifier
        )
        send(.timeSync, payload: BridgeCoder.encode(sync))
    }

    func ack(cursor: Int64) {
        var payload = Data(count: 8)
        let value = UInt64(bitPattern: cursor)
        for index in 0..<8 {
            payload[index] = UInt8((value >> (8 * UInt64(index))) & 0xFF)
        }
        send(.ack, payload: payload)
    }

    /// "start:STRENGTH", "pause", "resume" or "stop".
    func controlWatchWorkout(_ command: String) {
        send(.workoutControl, payload: Data(command.utf8))
        if command == "stop" { liveWorkout = nil }
    }

    func sendHealthConfig(_ config: HealthConfig) {
        send(.healthConfig, payload: BridgeCoder.encode(config))
    }

    // MARK: - Internals

    /// Issues a pending connect. The peripheral is only adopted once the
    /// connection lands, in didConnect, so several candidates can race without
    /// one of them pretending to be the live link.
    private func connect(_ candidate: CBPeripheral) {
        candidates[candidate.identifier] = candidate
        candidate.delegate = self
        // No timeout: the pending connect is what gives free reconnection.
        central.connect(candidate, options: [
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: false,
        ])
    }

    /// Control blob: version (1) + pairing salt (16) + session nonce (16).
    ///
    /// The long-term key comes from the code and the salt and never changes
    /// while the pairing lasts, which is why its fingerprint is what both
    /// screens show. The traffic key is that key bound to this session's nonce,
    /// so a reconnect gets unrelated keys and the counters can safely restart.
    private func handleControlBlob(_ data: Data) {
        let expected = 1 + SessionCrypto.saltSize + SessionCrypto.sessionNonceSize
        guard data.count >= expected else {
            pairingStatus = "The watch sent \(data.count) bytes instead of \(expected). Reinstall the watch app: this build speaks a newer handshake."
            return
        }
        let base = data.startIndex
        let protocolVersion = data[base]
        let salt = data.subdata(in: (base + 1)..<(base + 1 + SessionCrypto.saltSize))
        let nonce = data.subdata(in: (base + 1 + SessionCrypto.saltSize)..<(base + expected))

        guard let code = pairingCode, code.count == 6 else {
            Breadcrumbs.drop("bt: no pairing code set, handshake stopped")
            pairingStatus = "Enter the 6-digit code shown on the watch."
            return
        }
        Breadcrumbs.drop("control blob read, deriving keys")
        let longTerm = SessionCrypto.deriveKey(pairingCode: code, salt: salt)
        let session = SessionCrypto.deriveSessionKey(longTermKey: longTerm, sessionNonce: nonce)
        txCrypto = SessionCrypto(key: session, directionTag: SessionCrypto.tagPhoneToWatch)
        rxCrypto = SessionCrypto(key: session, directionTag: SessionCrypto.tagWatchToPhone)
        keyFingerprint = SessionCrypto.fingerprint(longTerm)
        pairingStatus = "Key ready. It must match the key shown on the watch."
        lastError = nil
        log.info("protocol v\(protocolVersion, privacy: .public), key \(self.keyFingerprint ?? "-", privacy: .public)")

        if let peripheral, let txCharacteristic {
            peripheral.setNotifyValue(true, for: txCharacteristic)
        }
        Breadcrumbs.drop("keys ready, sending hello")
        sendHello()
        sendTimeSync()
    }

    private func sendHello() {
        let hello = Hello(
            role: "phone",
            model: UIDeviceModel.identifier,
            osVersion: UIDeviceModel.systemVersion,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
            capabilities: ["pim.contacts", "pim.calendar", "healthkit"],
            pairingId: knownPeripheralID?.uuidString ?? "unknown"
        )
        send(.hello, payload: BridgeCoder.encode(hello))
    }

    /// `allowPlaintext` is true only for the sensor-stream characteristic,
    /// which carries raw waveforms and is unencrypted for throughput.
    private func dispatch(_ value: Data, allowPlaintext: Bool = false) {
        guard let (header, body) = inbound.offer(value), let type = header.type else { return }
        let plaintext: Data
        if header.flags & Frame.flagEncrypted != 0 {
            guard let crypto = rxCrypto, let opened = try? crypto.open(body) else {
                log.error("decrypt failed for \(String(describing: type), privacy: .public)")
                pairingStatus = "The watch's messages will not decrypt. The codes do not match."
                Breadcrumbs.drop("bt: decrypt FAILED for \(String(describing: type))")
                return
            }
            plaintext = opened
        } else if allowPlaintext {
            plaintext = body
        } else {
            log.error("rejected an unencrypted \(String(describing: type), privacy: .public)")
            return
        }

        switch type {
        case .hello:
            watchHello = BridgeCoder.decode(Hello.self, from: plaintext)
        case .mediaState:
            if let state = BridgeCoder.decode(MediaState.self, from: plaintext) { media = state }
        case .telemetry:
            telemetry = BridgeCoder.decode(Telemetry.self, from: plaintext)
        case .workoutLive:
            liveWorkout = BridgeCoder.decode(WorkoutLive.self, from: plaintext)
            liveWorkoutAt = Date()
            // Updates come every 5 s; 20 s of silence means it ended or the
            // link went, and stale numbers must not stay on screen.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self, Date().timeIntervalSince(self.liveWorkoutAt) >= 19 else { return }
                self.liveWorkout = nil
            }
        case .ping:
            send(.pong, payload: Data())
        default:
            break
        }

        onMessage?(type, plaintext)
    }
}

// MARK: - CBCentralManagerDelegate

extension BridgeClient: @preconcurrency CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Breadcrumbs.drop("bt: iPhone Bluetooth state \(central.state.rawValue)")
        switch central.state {
        case .poweredOn:
            lastError = nil
            start()
        case .unauthorized:
            lastError = "Bluetooth permission denied in Settings"
        case .poweredOff:
            resetLink()
            lastError = "Bluetooth is off"
        default:
            resetLink()
        }
    }

    /// Bluetooth went away on the iPhone. iOS stops the scan and drops every
    /// connection without calling the delegate for either, so forget them
    /// here; otherwise "scanning" stayed true and the scan was never started
    /// again when Bluetooth came back.
    private func resetLink() {
        scanDeadline?.invalidate()
        isScanning = false
        isConnected = false
        peripheral = nil
        candidates.removeAll()
        rxCharacteristic = nil
        txCharacteristic = nil
        ctrlCharacteristic = nil
        txCrypto = nil
        rxCrypto = nil
        mtu = 23
        inbound.reset()
    }

    /// iOS relaunched the app for a Bluetooth event: adopt the restored
    /// peripherals instead of scanning from scratch.
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        log.info("restored \(restored.count, privacy: .public) peripheral(s)")
        Breadcrumbs.drop("bt: relaunched by iOS, \(restored.count) restored, states \(restored.map { $0.state.rawValue })")
        if let first = restored.first {
            first.delegate = self
            if first.state == .connected {
                // Only a live link is adopted. A restored pending connect is
                // just a candidate: adopting it made the app look busy with
                // a watch that was not there, and the scan was never retried.
                peripheral = first
                isConnected = true
                first.discoverServices([CBUUID(string: BridgeUUID.service)])
            } else {
                connect(first)
            }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        log.info("discovered \(peripheral.identifier.uuidString, privacy: .public) rssi=\(RSSI.intValue)")
        Breadcrumbs.drop("bt: watch seen \(peripheral.identifier.uuidString.prefix(4)) rssi \(RSSI.intValue)")
        lastError = nil
        // The scan keeps running until a connection lands: stopping here meant
        // a failed connect left the app with neither a link nor a scan.
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Breadcrumbs.drop("bt: connected to the watch \(peripheral.identifier.uuidString.prefix(4))")
        self.peripheral = peripheral
        knownPeripheralID = peripheral.identifier
        isConnected = true
        lastError = nil
        inbound.reset()
        mtu = peripheral.maximumWriteValueLength(for: .withoutResponse) + 3

        scanDeadline?.invalidate()
        if isScanning {
            central.stopScan()
            isScanning = false
        }
        // Drop the other racers so none of them wakes up later and confuses this.
        for (id, candidate) in candidates where id != peripheral.identifier {
            central.cancelPeripheralConnection(candidate)
            candidates[id] = nil
        }
        peripheral.discoverServices([CBUUID(string: BridgeUUID.service)])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        log.error("connect failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
        Breadcrumbs.drop("bt: connect FAILED \(peripheral.identifier.uuidString.prefix(4)): \(error?.localizedDescription ?? "unknown")")
        // Keep scanning rather than hammering an address that may be gone.
        candidates[peripheral.identifier] = nil
        // A fresh scan, so the watch is reported again: the running one has
        // already reported it and filters it out from now on.
        restartScan()
        // And put the pending connect back on the saved watch shortly: the
        // scan alone cannot run while the app is suspended, the pending
        // connect can.
        if peripheral.identifier == knownPeripheralID {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !self.isConnected else { return }
                self.armKnownWatches()
            }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard peripheral.identifier == self.peripheral?.identifier else {
            candidates[peripheral.identifier] = nil
            return
        }
        isConnected = false
        inbound.reset()
        txCrypto = nil
        rxCrypto = nil
        mtu = 23
        self.peripheral = nil
        rxCharacteristic = nil
        txCharacteristic = nil
        ctrlCharacteristic = nil
        log.info("disconnected: \(error?.localizedDescription ?? "clean", privacy: .public)")
        Breadcrumbs.drop("bt: disconnected: \(error?.localizedDescription ?? "clean")")
        // Re-arm the pending connect so the watch reconnects without a scan
        // even from a suspended state, and scan in parallel in case its
        // advertising address has rotated meanwhile.
        connect(peripheral)
        beginScan()
    }
}

// MARK: - CBPeripheralDelegate

extension BridgeClient: @preconcurrency CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Breadcrumbs.drop("services discovered")
        guard let service = peripheral.services?.first(where: {
            $0.uuid == CBUUID(string: BridgeUUID.service)
        }) else {
            // Typical after the watch restarts: iOS relinks to it for
            // notifications before the watch app has opened its service. The
            // link is ours now, so nothing would ever trigger another look;
            // keep checking until the service shows up.
            lastError = "Bridge service not found on the watch yet; retrying"
            Breadcrumbs.drop("bt: bridge service not on the watch yet, retrying in 4 s")
            retryDiscovery(on: peripheral)
            return
        }
        peripheral.discoverCharacteristics(
            [
                CBUUID(string: BridgeUUID.rx),
                CBUUID(string: BridgeUUID.tx),
                CBUUID(string: BridgeUUID.ctrl),
                CBUUID(string: BridgeUUID.stream),
            ],
            for: service
        )
    }

    /// The watch rebuilt its GATT server (Bluetooth restarted on it) while
    /// iOS kept the link: the old characteristics are gone, so start the
    /// handshake again instead of writing into a void.
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        // When the bridge service is *added* (it did not exist at discovery
        // time) it is not in the invalidated list, so also rediscover whenever
        // the handshake is not complete.
        let bridgeChanged = invalidatedServices.contains(where: { $0.uuid == CBUUID(string: BridgeUUID.service) })
        guard bridgeChanged || rxCharacteristic == nil || txCrypto == nil else { return }
        log.info("watch bridge service changed, rediscovering")
        Breadcrumbs.drop("bt: watch services changed, rediscovering")
        txCrypto = nil
        rxCrypto = nil
        rxCharacteristic = nil
        txCharacteristic = nil
        ctrlCharacteristic = nil
        inbound.reset()
        peripheral.discoverServices([CBUUID(string: BridgeUUID.service)])
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid.uuidString.uppercased() {
            case BridgeUUID.rx:
                rxCharacteristic = characteristic
            case BridgeUUID.tx:
                // Notifications are enabled once the session keys exist, in
                // handleControlBlob; before that nothing could be decrypted.
                txCharacteristic = characteristic
            case BridgeUUID.ctrl:
                ctrlCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
            case BridgeUUID.stream:
                peripheral.setNotifyValue(true, for: characteristic)
            default:
                break
            }
        }
        if error != nil || ctrlCharacteristic == nil || rxCharacteristic == nil {
            retryDiscovery(on: peripheral)
        }
    }

    /// Looks for the bridge service again in a few seconds, for as long as this
    /// is still the live link and the handshake has not happened.
    private func retryDiscovery(on peripheral: CBPeripheral) {
        let id = peripheral.identifier
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, let live = self.peripheral, live.identifier == id,
                  live.state == .connected, self.txCrypto == nil,
                  self.pairingCode?.count == 6 else { return }
            live.discoverServices([CBUUID(string: BridgeUUID.service)])
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if error != nil, characteristic.uuid.uuidString.uppercased() == BridgeUUID.ctrl {
            // The control read failed (the watch was still setting up): try
            // the whole discovery again rather than wait forever.
            Breadcrumbs.drop("bt: control read FAILED: \(error?.localizedDescription ?? "?")")
            retryDiscovery(on: peripheral)
            return
        }
        guard let value = characteristic.value else { return }
        switch characteristic.uuid.uuidString.uppercased() {
        case BridgeUUID.ctrl:
            handleControlBlob(value)
        case BridgeUUID.stream:
            dispatch(value, allowPlaintext: true)
        default:
            dispatch(value)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            log.error("write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Small shim so the BLE layer does not import UIKit everywhere.
enum UIDeviceModel {
    static var identifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return machine
    }

    static var systemVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }
}
