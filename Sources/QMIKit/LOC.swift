import Foundation

// Location service (QMI LOC, 0x10). A request's response only says it was accepted; the answer
// comes as an indication with the same message ID on the same client, its TLV 0x01 a status
// (IndicationStatus). Those reply indications need no Register Events; the ones the modem sends
// on its own (positions, satellites, engine state, …) do. Numbers as checked on the RM551E
// (LOC 2.175), which follows Qualcomm's IDL where it differs from libqmi; see docs/QMI-loc.md.
public enum LOC {
    public static let registerEvents: UInt16 = 0x0021
    public static let injectPredictedOrbitsData: UInt16 = 0x0035   // NotSupported on the RM551E
    public static let getPredictedOrbitsDataSource: UInt16 = 0x0036
    public static let getPredictedOrbitsDataValidity: UInt16 = 0x0037
    public static let injectXTRAData: UInt16 = 0x00A7

    // Inject parts carry at most this many bytes.
    public static let maxPartSize = 1024

    public struct IndicationStatus: RawRepresentable, Hashable, CustomStringConvertible {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let success = IndicationStatus(rawValue: 0)
        public static let engineBusy = IndicationStatus(rawValue: 4)

        static let names = ["success", "general failure", "unsupported", "invalid parameter",
                            "engine busy", "phone offline", "timeout"]
        public var description: String {
            Int(rawValue) < Self.names.count ? Self.names[Int(rawValue)] : "status \(rawValue)"
        }
    }

    // TLV 0x01 of a reply indication.
    public static func indicationStatus(_ m: QMIMessage) -> IndicationStatus? {
        u32(m[tlv: 0x01]).map(IndicationStatus.init(rawValue:))
    }

    // MARK: - XTRA (predicted orbits)

    public struct XTRAValidity: Equatable {
        public var start: Date
        public var hours: Int
        public var expires: Date { start.addingTimeInterval(TimeInterval(hours) * 3600) }

        public init(start: Date, hours: Int) {
            self.start = start
            self.hours = hours
        }
    }

    // Get Predicted Orbits Data Validity indication, TLV 0x10: start (u64, Unix seconds; the
    // same time AT+QGPSXTRADATA shows), duration (u16, hours). nil without data.
    public static func parseValidity(_ m: QMIMessage) -> XTRAValidity? {
        guard let v = m[tlv: 0x10], v.count >= 10 else { return nil }
        var r = ByteReader(v)
        guard let lo = try? r.u32(), let hi = try? r.u32(), let hours = try? r.u16() else { return nil }
        let start = UInt64(hi) << 32 | UInt64(lo)
        guard start > 0, hours > 0 else { return nil }
        return XTRAValidity(start: Date(timeIntervalSince1970: TimeInterval(start)), hours: Int(hours))
    }

    public struct XTRASource: Equatable {
        public var maxFileSize: Int?
        public var maxPartSize: Int?
        public var servers: [String]

        public init(maxFileSize: Int? = nil, maxPartSize: Int? = nil, servers: [String]) {
            self.maxFileSize = maxFileSize
            self.maxPartSize = maxPartSize
            self.servers = servers
        }
    }

    // Get Predicted Orbits Data Source indication: 0x10 max file and part size (u32, u32; the
    // RM551E leaves it out), 0x11 servers (u8 count, then u8 length + URL each). The RM520N
    // accepts the request and never sends this indication.
    public static func parseSource(_ m: QMIMessage) -> XTRASource {
        var s = XTRASource(servers: [])
        if let v = m[tlv: 0x10], v.count >= 8 {
            var r = ByteReader(v)
            s.maxFileSize = (try? r.u32()).map { Int($0) }
            s.maxPartSize = (try? r.u32()).map { Int($0) }
        }
        if let v = m[tlv: 0x11], !v.isEmpty {
            var r = ByteReader(v)
            let n = (try? r.u8()) ?? 0
            for _ in 0..<n {
                guard let len = try? r.u8(), let b = try? r.take(Int(len)) else { break }
                s.servers.append(String(decoding: b, as: UTF8.self))
            }
        }
        return s
    }

    // The requests that inject `data` with `message` (injectXTRAData or
    // injectPredictedOrbitsData): 0x01 total size, 0x02 total parts, 0x03 part number (from 1),
    // 0x04 the part (u16 length, then the bytes); 0x0035 also takes 0x10 format, 0 = XTRA.
    // Empty when there is nothing to send or more parts than a u16 counts.
    public static func injectRequests(_ data: [UInt8], message: UInt16, partSize: Int = maxPartSize) -> [[TLV]] {
        let size = max(1, min(partSize, maxPartSize))
        let total = (data.count + size - 1) / size
        guard !data.isEmpty, total <= Int(UInt16.max), data.count <= Int(UInt32.max) else { return [] }
        return (0..<total).map { i in
            let part = data[(i * size)..<min(data.count, (i + 1) * size)]
            var w = ByteWriter()
            w.u16(UInt16(part.count))
            w.append(Array(part))
            var tlvs: [TLV] = [.u32(0x01, UInt32(data.count)), .u16(0x02, UInt16(total)),
                               .u16(0x03, UInt16(i + 1)), TLV(0x04, w.bytes)]
            if message == injectPredictedOrbitsData { tlvs.append(.u32(0x10, 0)) }
            return tlvs
        }
    }

    // Inject indication: the status, 0x10 the part it answers. The last part's also carries
    // 0x11 (u64; 0x1F on the RM551E, 0x1B on the RM520N: apparently the constellations used).
    public static func injectedPart(_ m: QMIMessage) -> Int? {
        guard let v = m[tlv: 0x10], v.count >= 2 else { return nil }
        return Int(UInt16(v[0]) | UInt16(v[1]) << 8)
    }

    // MARK: - Sessions

    public static let start: UInt16 = 0x0022
    public static let stop: UInt16 = 0x0023
    public static let positionReport: UInt16 = 0x0024
    public static let satelliteInfo: UInt16 = 0x0025
    public static let nmea: UInt16 = 0x0026
    public static let engineState: UInt16 = 0x002B
    public static let fixSessionState: UInt16 = 0x002C

    public struct EventMask: OptionSet, Hashable {
        public let rawValue: UInt64
        public init(rawValue: UInt64) { self.rawValue = rawValue }
        public static let position = EventMask(rawValue: 1 << 0)
        public static let satellites = EventMask(rawValue: 1 << 1)
        public static let nmea = EventMask(rawValue: 1 << 2)
        public static let engineState = EventMask(rawValue: 1 << 7)
        public static let fixSessionState = EventMask(rawValue: 1 << 8)
    }

    // Start: 0x01 session ID, 0x10 recurrence (1 periodic), 0x12 intermediate reports (1 on),
    // 0x13 minimum interval between reports (ms). Releasing the client ends the session too.
    public static func startRequest(session: UInt8 = 1, intervalMs: UInt32) -> [TLV] {
        [.u8(0x01, session), .u32(0x10, 1), .u32(0x12, 1), .u32(0x13, intervalMs)]
    }

    public static func stopRequest(session: UInt8 = 1) -> [TLV] { [.u8(0x01, session)] }

    // Inject UTC Time: 0x01 UTC (u64 ms), 0x02 its uncertainty (u32 ms). Answered by an
    // indication. The modem can hold a wrong clock, flagged unknown in the position reports,
    // and can't use XTRA until it has the right one.
    public static let injectUTCTime: UInt16 = 0x0038

    public static func injectUTCTimeRequest(_ date: Date, uncertaintyMs: UInt32) -> [TLV] {
        var w = ByteWriter()
        let ms = UInt64(max(0, date.timeIntervalSince1970 * 1000))
        w.u32(UInt32(truncatingIfNeeded: ms))
        w.u32(UInt32(truncatingIfNeeded: ms >> 32))
        return [TLV(0x01, w.bytes), .u32(0x02, uncertaintyMs)]
    }

    // Inject Position: a rough position for the engine to start its search from. Accepted on
    // the RM551E (indication status 0); the position reports don't show it, the search uses it.
    // No timestamp TLV: the time goes in with Inject UTC Time.
    public static let injectPosition: UInt16 = 0x0039

    public enum PositionSource: UInt32 { case gnss = 0, cellID = 1, enhancedCellID = 2, wifi = 3, terrestrial = 4, hybrid = 5, other = 6 }

    // `uncertainty`: circular, m; `confidence`: % (1–99); reliability "medium" (3).
    public static func injectPositionRequest(latitude: Double, longitude: Double, uncertainty: Float,
                                             confidence: UInt8 = 68, source: PositionSource = .cellID) -> [TLV] {
        func f64(_ type: UInt8, _ v: Double) -> TLV {
            var w = ByteWriter(); w.u32(UInt32(v.bitPattern & 0xffff_ffff)); w.u32(UInt32(v.bitPattern >> 32)); return TLV(type, w.bytes)
        }
        return [f64(0x10, latitude), f64(0x11, longitude), .u32(0x12, uncertainty.bitPattern),
                .u8(0x13, confidence), .u32(0x14, 3), .u32(0x1D, source.rawValue)]
    }

    // Engine State: TLV 0x01 is the state (1 on, 2 off), not a status.
    public static func parseEngineOn(_ m: QMIMessage) -> Bool? {
        u32(m[tlv: 0x01]).flatMap { $0 == 1 ? true : $0 == 2 ? false : nil }
    }

    // NMEA: TLV 0x01, the sentence.
    public static func parseNMEA(_ m: QMIMessage) -> String? {
        m[tlv: 0x01].map { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    // Constellations as numbered in Qualcomm's IDL (libqmi's list differs from 4 on).
    public static func systemName(_ raw: UInt32) -> String? {
        [1: "gps", 2: "galileo", 3: "sbas", 5: "glonass", 6: "beidou", 7: "qzss", 8: "navic"][raw]
    }

    // Signal type mask (Qualcomm's IDL). Seen on the RM551E: GPS L1 C/A and L5, BeiDou B1I,
    // B1C and B2a, QZSS L1 C/A and L5.
    static let signals: [(bit: UInt64, name: String)] = [
        (0x1, "L1"), (0x2, "L1C"), (0x4, "L2C"), (0x8, "L5"),                     // GPS
        (0x10, "G1"), (0x20, "G2"),                                              // GLONASS
        (0x40, "E1"), (0x80, "E5a"), (0x100, "E5b"),                             // Galileo
        (0x200, "B1I"), (0x400, "B1C"), (0x800, "B2I"), (0x1000, "B2a"),          // BeiDou
        (0x2000, "L1"), (0x4000, "L1S"), (0x8000, "L2C"), (0x10000, "L5"),        // QZSS
        (0x20000, "L1"), (0x40000, "L5"), (0x80000, "B2a"),                       // SBAS, NavIC, BeiDou B2a Q
    ]

    public static func signalName(_ mask: UInt64) -> String? {
        signals.first { mask & $0.bit != 0 }?.name
    }

    public struct Satellite: Equatable {
        public var system: UInt32
        public var id: UInt16                 // GPS 1–32, GLONASS 65–96, QZSS 193–, BeiDou 201–, Galileo 301–
        public var signal: UInt64?            // signal type mask (one bit)
        public var tracking: Bool             // status 3; 2 is searching
        public var elevation: Float?
        public var azimuth: Float?
        public var cn0: Float?                // dB-Hz
    }

    // GNSS SV Info: TLV 0x11 (29-byte entries; the RM551E) or 0x10 (28 bytes, libqmi),
    // u8 count first; 0x12 the signal type of each entry, in the same order (u8 count, u64 each).
    // Entry: valid mask u32 (bit 5 elevation, 6 azimuth, 7 C/N0), system u32, ID u16, health u8,
    // status u32, navigation data u8, elevation, azimuth, C/N0 (floats). Idle ones are left out.
    public static func parseSatellites(_ m: QMIMessage) -> [Satellite] {
        let (list, size) = m[tlv: 0x11].map { ($0, 29) } ?? m[tlv: 0x10].map { ($0, 28) } ?? ([], 28)
        guard let n = list.first else { return [] }
        let types = u64s(m[tlv: 0x12])
        var out: [Satellite] = []
        for i in 0..<Int(n) {
            let o = 1 + i * size
            guard o + 28 <= list.count else { break }
            var r = ByteReader(list, offset: o)
            guard let valid = try? r.u32(), let system = try? r.u32(), let id = try? r.u16(),
                  (try? r.u8()) != nil, let status = try? r.u32(), (try? r.u8()) != nil else { break }
            guard status == 2 || status == 3 else { continue }
            func float(_ at: Int, _ bit: UInt32) -> Float? {
                guard valid & bit != 0 else { return nil }
                return Float(bitPattern: (0..<4).reduce(UInt32(0)) { $0 | UInt32(list[o + at + $1]) << (8 * UInt32($1)) })
            }
            out.append(Satellite(system: system, id: id, signal: i < types.count ? types[i] : nil, tracking: status == 3,
                                 elevation: float(16, 1 << 5), azimuth: float(20, 1 << 6), cn0: float(24, 1 << 7)))
        }
        return out
    }

    public struct Position: Equatable {
        public var status: UInt32             // 0 fix, 1 intermediate (coarse, e.g. cell based), else failed
        public var latitude: Double?
        public var longitude: Double?
        public var horizontalAccuracy: Float? // m, circular
        public var altitude: Float?           // m above the WGS-84 ellipsoid
        public var altitudeMSL: Float?        // m above mean sea level
        public var verticalAccuracy: Float?
        public var speed: Float?              // m/s, horizontal
        public var verticalSpeed: Float?
        public var heading: Float?            // degrees from true north
        public var time: Date?                // the modem's UTC; see timeKnown
        public var timeSource: UInt32?        // 0 invalid, 13 unknown, 7 navigation solution, …
        public var technology: UInt32?        // mask: 1 satellite, 2 cellular, 4 Wi-Fi, 8 sensors, …
        public var used: [(id: UInt16, signal: UInt64?)] = []

        // Whether `time` can be believed. Before its first fix a modem reported a UTC 12 h off,
        // source "unknown"; a fix's own time is always good.
        public var timeKnown: Bool {
            status == 0 || (timeSource.map { $0 != 0 && $0 != 13 } ?? false)
        }

        public static func == (a: Position, b: Position) -> Bool {
            a.status == b.status && a.latitude == b.latitude && a.longitude == b.longitude
                && a.horizontalAccuracy == b.horizontalAccuracy && a.altitude == b.altitude
                && a.altitudeMSL == b.altitudeMSL && a.verticalAccuracy == b.verticalAccuracy
                && a.speed == b.speed && a.verticalSpeed == b.verticalSpeed && a.heading == b.heading
                && a.time == b.time && a.timeSource == b.timeSource && a.technology == b.technology
                && a.used.map(\.id) == b.used.map(\.id) && a.used.map(\.signal) == b.used.map(\.signal)
        }
    }

    // Position Report: 0x01 session status, 0x10 latitude, 0x11 longitude (doubles), 0x12
    // horizontal uncertainty, 0x18 speed, 0x1A / 0x1B altitude (ellipsoid / sea level), 0x1C
    // vertical uncertainty, 0x1F vertical speed, 0x20 heading (floats), 0x23 technology mask,
    // 0x25 UTC (u64 ms), 0x29 time source, 0x2C satellites used (u8 count, u16 IDs; once per signal), 0x37 their
    // signal types (u8 count, u64 each).
    public static func parsePosition(_ m: QMIMessage) -> Position? {
        guard let status = u32(m[tlv: 0x01]) else { return nil }
        func f(_ t: UInt8) -> Float? { u32(m[tlv: t]).map(Float.init(bitPattern:)) }
        func d(_ t: UInt8) -> Double? { m[tlv: t].flatMap { $0.count >= 8 ? Double(bitPattern: u64($0)) : nil } }
        var p = Position(status: status)
        p.latitude = d(0x10)
        p.longitude = d(0x11)
        p.horizontalAccuracy = f(0x12)
        p.speed = f(0x18)
        p.altitude = f(0x1A)
        p.altitudeMSL = f(0x1B)
        p.verticalAccuracy = f(0x1C)
        p.verticalSpeed = f(0x1F)
        p.heading = f(0x20)
        p.technology = u32(m[tlv: 0x23])
        p.time = m[tlv: 0x25].flatMap { $0.count >= 8 ? Date(timeIntervalSince1970: TimeInterval(u64($0)) / 1000) : nil }
        p.timeSource = u32(m[tlv: 0x29])
        if let v = m[tlv: 0x2C], let n = v.first {
            let types = u64s(m[tlv: 0x37])
            var r = ByteReader(v, offset: 1)
            for i in 0..<Int(n) {
                guard let id = try? r.u16() else { break }
                p.used.append((id, i < types.count ? types[i] : nil))
            }
        }
        return p
    }

    static func u64(_ v: [UInt8]) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(v[$1]) << (8 * UInt64($1)) }
    }

    // A u8 count, then that many u64.
    static func u64s(_ v: [UInt8]?) -> [UInt64] {
        guard let v, let n = v.first else { return [] }
        return (0..<Int(n)).compactMap { i in
            let o = 1 + i * 8
            return o + 8 <= v.count ? u64(Array(v[o..<(o + 8)])) : nil
        }
    }

    // MARK: - Events

    // Register Events: 0x01 the event mask (u64), 0x11 client type. The RM551E refuses the
    // request (InvalidArgument) without client type 1. Each call replaces the client's mask.
    public static func registerEventsRequest(_ events: EventMask) -> [TLV] { registerEventsRequest(events.rawValue) }

    public static func registerEventsRequest(_ mask: UInt64) -> [TLV] {
        var w = ByteWriter()
        w.u32(UInt32(truncatingIfNeeded: mask))
        w.u32(UInt32(truncatingIfNeeded: mask >> 32))
        return [TLV(0x01, w.bytes), .u32(0x11, 1)]
    }

    static func u32(_ v: [UInt8]?) -> UInt32? {
        guard let v, v.count >= 4 else { return nil }
        var r = ByteReader(v)
        return try? r.u32()
    }
}
