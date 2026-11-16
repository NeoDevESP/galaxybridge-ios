import Foundation

/// Mirror of `dev.galaxybridge.shared` on the Kotlin side. The two files must
/// stay byte-compatible; `docs/PROTOCOL.md` is the contract and the Swift and
/// Kotlin tests cover the same vectors.
enum BridgeUUID {
    static let service = "5A6B0001-9C4E-4B5E-9E1F-2D7A3C8F0001"
    static let rx = "5A6B0002-9C4E-4B5E-9E1F-2D7A3C8F0001"
    static let tx = "5A6B0003-9C4E-4B5E-9E1F-2D7A3C8F0001"
    static let ctrl = "5A6B0004-9C4E-4B5E-9E1F-2D7A3C8F0001"
    static let stream = "5A6B0005-9C4E-4B5E-9E1F-2D7A3C8F0001"
}

enum MessageType: UInt8, Sendable {
    case hello = 0x01
    case ack = 0x02
    case nack = 0x03
    case timeSync = 0x04
    case ping = 0x05
    case pong = 0x06
    case healthBatch = 0x10
    case workout = 0x11
    case sensor = 0x12
    case healthConfig = 0x13
    case ecg = 0x14
    case workoutAck = 0x15
    case workoutControl = 0x16
    case workoutLive = 0x17
    case contacts = 0x20
    case calendar = 0x21
    case syncRequest = 0x22
    case notifAction = 0x30
    case mediaState = 0x31
    case callState = 0x32
    case locate = 0x33
    case log = 0x40
    case telemetry = 0x41
}

/// 8-byte little-endian header, identical to `Frame.kt`.
struct Frame: Sendable {
    static let version: UInt8 = 1
    static let headerSize = 8
    static let flagFirst: UInt8 = 0x01
    static let flagLast: UInt8 = 0x02
    static let flagEncrypted: UInt8 = 0x04
    static let flagNeedsAck: UInt8 = 0x08

    struct Header: Sendable {
        let version: UInt8
        let type: MessageType?
        let seq: UInt16
        let flags: UInt8
        let length: UInt16
    }

    static func encode(type: MessageType, seq: UInt16, payload: Data, flags: UInt8) -> Data {
        var out = Data(capacity: headerSize + payload.count)
        out.append(version)
        out.append(type.rawValue)
        out.append(UInt8(seq & 0xFF))
        out.append(UInt8((seq >> 8) & 0xFF))
        out.append(flags)
        out.append(0)
        let length = UInt16(payload.count)
        out.append(UInt8(length & 0xFF))
        out.append(UInt8((length >> 8) & 0xFF))
        out.append(payload)
        return out
    }

    /// Splits `payload` so each frame body fits in `maxPayload` bytes.
    static func fragment(
        type: MessageType,
        seq: UInt16,
        payload: Data,
        maxPayload: Int,
        encrypted: Bool
    ) -> [Data] {
        precondition(maxPayload > 0)
        let encFlag: UInt8 = encrypted ? flagEncrypted : 0
        guard !payload.isEmpty else {
            return [encode(type: type, seq: seq, payload: payload, flags: flagFirst | flagLast | encFlag)]
        }
        var frames: [Data] = []
        var offset = 0
        while offset < payload.count {
            let end = min(offset + maxPayload, payload.count)
            var flags = encFlag
            if offset == 0 { flags |= flagFirst }
            if end == payload.count { flags |= flagLast }
            frames.append(
                encode(type: type, seq: seq, payload: payload.subdata(in: offset..<end), flags: flags)
            )
            offset = end
        }
        return frames
    }

    static func header(_ data: Data) -> Header? {
        guard data.count >= headerSize else { return nil }
        let bytes = [UInt8](data)
        let length = UInt16(bytes[6]) | (UInt16(bytes[7]) << 8)
        guard data.count >= headerSize + Int(length) else { return nil }
        return Header(
            version: bytes[0],
            type: MessageType(rawValue: bytes[1]),
            seq: UInt16(bytes[2]) | (UInt16(bytes[3]) << 8),
            flags: bytes[4],
            length: length
        )
    }

    static func payload(_ data: Data) -> Data {
        guard let header = header(data) else { return Data() }
        return data.subdata(in: headerSize..<(headerSize + Int(header.length)))
    }
}

/// Reassembles fragmented frames; one instance per direction.
final class Reassembler {
    private var partial: [UInt16: Data] = [:]

    func offer(_ data: Data) -> (Frame.Header, Data)? {
        guard let header = Frame.header(data) else { return nil }
        let body = Frame.payload(data)
        if header.flags & Frame.flagFirst != 0 && header.flags & Frame.flagLast != 0 {
            return (header, body)
        }
        if header.flags & Frame.flagFirst != 0 {
            partial[header.seq] = Data()
        }
        partial[header.seq, default: Data()].append(body)
        guard header.flags & Frame.flagLast != 0 else { return nil }
        let complete = partial.removeValue(forKey: header.seq) ?? Data()
        return (header, complete)
    }

    func reset() {
        partial.removeAll()
    }
}

// MARK: - Payload models

enum Metric: String, Codable, Sendable, CaseIterable {
    case steps = "STEPS"
    case heartRate = "HEART_RATE"
    case activeEnergy = "ACTIVE_ENERGY"
    case distance = "DISTANCE"
    case floors = "FLOORS"
    case spo2 = "SPO2"
    case sleep = "SLEEP"
    case restingHeartRate = "RESTING_HR"
    case hrv = "HRV"
    case skinTemperature = "SKIN_TEMP"
    case bodyFat = "BODY_FAT"
    case skeletalMuscle = "SKELETAL_MUSCLE"
    case bodyWater = "BODY_WATER"
    case bmr = "BMR"
    case respiratoryRate = "RESPIRATORY_RATE"
}

struct Hello: Codable, Sendable {
    var protocolVersion: Int = Int(Frame.version)
    var role: String
    var model: String
    var osVersion: String
    var appVersion: String
    var capabilities: [String]
    var pairingId: String

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case role, model, osVersion, appVersion, capabilities, pairingId
    }
}

struct TimeSync: Codable, Sendable {
    var epochMillis: Int64
    var monotonicNanos: Int64
    var timeZoneId: String
}

struct HealthSample: Codable, Sendable, Identifiable {
    var metric: Metric
    var value: Double
    var start: Int64
    var end: Int64
    var uid: String

    var id: String { uid }
}

/// A metric's running total for the local day starting at `dayStart`, as the
/// watch counts it. Samples are increments; this lets the phone fill a gap.
struct DayTotal: Codable, Sendable {
    var metric: Metric
    var value: Double
    var dayStart: Int64
    var at: Int64
}

struct HealthBatch: Codable, Sendable {
    var samples: [HealthSample]
    var cursor: Int64
    var dayTotals: [DayTotal] = []

    init(samples: [HealthSample], cursor: Int64, dayTotals: [DayTotal] = []) {
        self.samples = samples
        self.cursor = cursor
        self.dayTotals = dayTotals
    }

    /// A sample of a metric this build does not know yet is skipped rather
    /// than failing the whole batch, so a newer watch app never stalls sync.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cursor = try container.decode(Int64.self, forKey: .cursor)
        samples = try container.decode([Lossy<HealthSample>].self, forKey: .samples).compactMap(\.value)
        // Older watch builds send no totals; unknown metrics are skipped.
        dayTotals = (try? container.decode([Lossy<DayTotal>].self, forKey: .dayTotals))?.compactMap(\.value) ?? []
    }
}

struct Lossy<Wrapped: Decodable & Sendable>: Decodable, Sendable {
    let value: Wrapped?

    init(from decoder: Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}

struct HealthConfig: Codable, Sendable {
    var enabled: [Metric]
    var flushInterval: Int
    var continuousHeartRate: Bool
    var profile: WatchBodyProfile?
    var sleepStages: Bool = true
}

/// What the watch's body composition sensor needs to know about the wearer.
struct WatchBodyProfile: Codable, Sendable {
    var heightCm: Double
    var weightKg: Double
    /// "male" or "female".
    var sex: String
    var age: Int
}

/// A 30-second single-lead ECG from the watch, at `sampleRate` Hz.
struct EcgRecord: Codable, Sendable, Identifiable {
    var uid: String
    var start: Int64
    var durationMs: Int64
    var sampleRate: Int
    var microvolts: [Int]
    var averageHeartRate: Double?
    /// "regular", "irregular" or "inconclusive".
    var rhythm: String
    var beats: Int

    var id: String { uid }
    var date: Date { Date(timeIntervalSince1970: Double(start) / 1000) }
}

struct GeoPoint: Codable, Sendable {
    var lat: Double
    var lon: Double
    var alt: Double?
    var t: Int64
    var hAcc: Double?
}

struct WorkoutSummary: Codable, Sendable {
    var uid: String
    var type: String
    var start: Int64
    var end: Int64
    var activeEnergyKcal: Double
    var distanceMeters: Double
    var avgHeartRate: Double?
    var maxHeartRate: Double?
    var route: [GeoPoint]?
    /// Time actually exercising, pauses excluded. Nil from older watch builds.
    var activeDurationMs: Int64?
    /// Heart rate every 10 s while recording.
    var heartRateTrace: [Int]?
}

struct Contact: Codable, Sendable {
    var id: String
    var name: String
    var phones: [String]
    var emails: [String]
    var favourite: Bool
}

struct ContactPage: Codable, Sendable {
    var page: Int
    var totalPages: Int
    var contacts: [Contact]
    var revision: Int64
}

struct CalendarEventDTO: Codable, Sendable {
    var id: String
    var title: String
    var location: String?
    var start: Int64
    var end: Int64
    var allDay: Bool
    var calendarName: String?
}

struct CalendarPage: Codable, Sendable {
    var page: Int
    var totalPages: Int
    var events: [CalendarEventDTO]
    var revision: Int64
}

struct MediaState: Codable, Sendable {
    var app: String?
    var title: String?
    var artist: String?
    var album: String?
    var playing: Bool
    var elapsed: Double?
    var duration: Double?
    var volume: Double?
}

struct CallStateDTO: Codable, Sendable {
    var state: String
    var caller: String?
    var at: Int64
}

/// The watch's running workout, every 5 s while it records.
struct WorkoutLive: Codable, Sendable, Equatable {
    var kind: String
    var activeMs: Int64
    var heartRate: Int
    var energyKcal: Double
    var distanceMeters: Double
    var paused: Bool
}

struct Telemetry: Codable, Sendable {
    var watchBatteryPct: Int?
    var phoneBatteryPct: Int?
    var rssi: Int?
    var mtu: Int?
    var ancsConnected: Bool
    var queuedHealthRows: Int
    var at: Int64
}

enum BridgeCoder {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        return encoder
    }()

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? decoder.decode(type, from: data)
    }

    static func encode<T: Encodable>(_ value: T) -> Data {
        (try? encoder.encode(value)) ?? Data()
    }
}
