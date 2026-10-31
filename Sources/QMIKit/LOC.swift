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
    }

    // Get Predicted Orbits Data Source indication: 0x10 max file and part size (u32, u32; the
    // RM551E leaves it out), 0x11 servers (u8 count, then u8 length + URL each).
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
    // 0x11 (u64; 0x1F on the RM551E, apparently the constellations the data covers).
    public static func injectedPart(_ m: QMIMessage) -> Int? {
        guard let v = m[tlv: 0x10], v.count >= 2 else { return nil }
        return Int(UInt16(v[0]) | UInt16(v[1]) << 8)
    }

    // MARK: - Events

    // Register Events: 0x01 the event mask (u64), 0x11 client type. The RM551E refuses the
    // request (InvalidArgument) without client type 1. Each call replaces the client's mask.
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
