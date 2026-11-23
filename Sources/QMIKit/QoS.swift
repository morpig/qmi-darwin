import Foundation

// QMI QoS service: the bearers of a PDN (default bearer QCI, dedicated bearers with their
// rates and packet filters). Formats and findings in docs/QMI-bearers.md.
//
// Dedicated bearers come from Event Report indications (0x0001): every create or modify
// report carries the whole bearer, both directions' filters included, in a compact nested
// format (undocumented; decoded from live captures). Get QoS Info (0x0033) has the same data in
// 149-byte records, but the modem drops answers over ~4 KB, which a busy bearer passes; it is
// only used for the default bearer's QCI (QoS ID 0, ~180 bytes).
public enum QoS {
    public static let eventReport: UInt16 = 0x0001           // Set Event Report, and the indication
    public static let getGrantedQoS: UInt16 = 0x0025
    public static let setClientIPPref: UInt16 = 0x002A
    public static let bindDataPort: UInt16 = 0x002B
    public static let getQoSInfo: UInt16 = 0x0033
    public static let getQoSIDs: UInt16 = 0x0036

    public static func bindDataPortRequest(interface: UInt32, muxID: UInt8) -> [TLV] {
        [TLV(0x10, WDA.endpoint(interface: interface)), .u8(0x11, muxID)]
    }

    public static func clientIPPrefRequest(family: UInt8) -> [TLV] { [.u8(0x01, family)] }

    // Event Reports for every flow of the bound call (global flow reporting).
    public static func eventReportRequest() -> [TLV] { [.u8(0x10, 1)] }

    // Get QoS Info, Get Granted QoS: TLV 0x01 = QoS ID.
    public static func qosIDRequest(_ id: UInt32) -> [TLV] { [.u32(0x01, id)] }

    // MARK: Values

    // Bits per second; nil where the network didn't set the value.
    public struct Bitrates: Equatable {
        public var max: UInt64?
        public var guaranteed: UInt64?
        public init(max: UInt64? = nil, guaranteed: UInt64? = nil) { self.max = max; self.guaranteed = guaranteed }
    }

    // One direction of a flow (Tx = uplink, Rx = downlink).
    public struct Flow: Equatable {
        public var qci: UInt32?
        public var rates = Bitrates()
        public init(qci: UInt32? = nil, rates: Bitrates = Bitrates()) { self.qci = qci; self.rates = rates }
    }

    public struct Prefix: Equatable, CustomStringConvertible {
        public var address: String
        public var length: Int
        public init(address: String, length: Int) { self.address = address; self.length = length }
        public var description: String { "\(address)/\(length)" }
    }

    public struct PacketFilter: Equatable {
        public var id: UInt8                  // 3GPP packet filter identifier, 0–15
        public var precedence: UInt16
        public var ipVersion: UInt8           // 4 or 6
        public var source: Prefix?
        public var destination: Prefix?
        public var ipProtocol: UInt8?         // 6 TCP, 17 UDP, …
        public var sourcePorts: ClosedRange<UInt16>?
        public var destinationPorts: ClosedRange<UInt16>?

        public init(id: UInt8, precedence: UInt16, ipVersion: UInt8) {
            self.id = id; self.precedence = precedence; self.ipVersion = ipVersion
        }
    }

    public struct Bearer: Equatable {
        public var qosID: UInt32
        public var uplink = Flow()
        public var downlink = Flow()
        public var uplinkFilters: [PacketFilter] = []
        public var downlinkFilters: [PacketFilter] = []
        public var networkInitiated: Bool?
        public var bearerID: UInt8?           // as the modem reports it (not a plain 3GPP EBI)

        public init(qosID: UInt32) { self.qosID = qosID }

        public var qci: UInt32? { uplink.qci ?? downlink.qci }
    }

    // MARK: Queries

    public static func parseQoSIDs(_ m: QMIMessage) -> [UInt32] {
        var r = ByteReader(m[tlv: 0x10] ?? [])
        return r.partialList { try $0.u32() }
    }

    // Get Granted QoS: 0x11 / 0x12 uplink / downlink granted flow, nested (see parseFlow).
    // Small, so it works for any bearer; it carries no filters.
    public static func parseGrantedQoS(_ m: QMIMessage, qosID: UInt32) -> Bearer {
        var b = Bearer(qosID: qosID)
        b.uplink = m[tlv: 0x11].map(parseFlow) ?? Flow()
        b.downlink = m[tlv: 0x12].map(parseFlow) ?? Flow()
        return b
    }

    // The default bearer's QCI from Get QoS Info for QoS ID 0: flow record 0x11 (77 bytes,
    // u64 valid mask first, LTE QCI as the last u32 when mask bit 14 is set), else 5G QCI 0x16.
    public static func parseDefaultQCI(_ m: QMIMessage) -> UInt32? {
        if let f = m[tlv: 0x11], f.count >= 77 {
            var mask = ByteReader(f), qci = ByteReader(f, offset: 73)
            if try! mask.u32() & 0x4000 != 0 { return try! qci.u32() }
        }
        return m.u32(tlv: 0x16)
    }

    // MARK: Event Report

    // One flow of an Event Report: TLV 0x10 per flow, holding nested TLVs: 0x10 = qos_id u32,
    // new u8, state u8 (1 activated, 2 modified, 3 deleted, 4 suspended, 5/6 flow control);
    // 0x11 / 0x12 uplink / downlink granted flow; 0x13 / 0x14 uplink / downlink filters (each
    // filter a nested 0x10); 0x15 flow type (1 = network-initiated); 0x16 bearer ID.
    public struct Report: Equatable {
        public var qosID: UInt32
        public var state: UInt8
        public var bearer: Bearer?            // the whole bearer, on activated / modified

        public var isDeleted: Bool { state == 3 }
        public var changesBearer: Bool { state >= 1 && state <= 3 }
    }

    public static func parseEventReport(_ m: QMIMessage) -> [Report] {
        m.tlvs.filter { $0.type == 0x10 }.compactMap { t in
            let inner = nested(t.value).valuesByType
            guard let head = inner[0x10], head.count >= 6 else { return nil }
            var r = ByteReader(head)
            let id = try! r.u32(), state = head[5]
            var report = Report(qosID: id, state: state)
            guard state == 1 || state == 2 else { return report }
            var b = Bearer(qosID: id)
            b.uplink = inner[0x11].map(parseFlow) ?? Flow()
            b.downlink = inner[0x12].map(parseFlow) ?? Flow()
            b.uplinkFilters = inner[0x13].map(parseFilters) ?? []
            b.downlinkFilters = inner[0x14].map(parseFilters) ?? []
            b.networkInitiated = inner[0x15]?.first.map { $0 == 1 }
            b.bearerID = inner[0x16]?.first
            report.bearer = b
            return report
        }
    }

    // A granted flow: a nested 0x10 flow spec holding 0x20 max + guaranteed bps (two u64),
    // or 0x12 (two u32) on older firmware, and 0x1F QCI (u8). A zero rate is "not set".
    static func parseFlow(_ v: [UInt8]) -> Flow {
        guard let spec = nested(v).first(where: { $0.type == 0x10 })?.value else { return Flow() }
        let t = nested(spec).valuesByType
        var f = Flow()
        if let v = t[0x20], v.count >= 16 {
            var r = ByteReader(v)
            f.rates = Bitrates(max: nonzero(try! r.u64()), guaranteed: nonzero(try! r.u64()))
        } else if let v = t[0x12], v.count >= 8 {
            var r = ByteReader(v)
            f.rates = Bitrates(max: nonzero(UInt64(try! r.u32())), guaranteed: nonzero(UInt64(try! r.u32())))
        }
        f.qci = t[0x1F]?.first.map(UInt32.init)
        return f
    }

    // Each filter a nested 0x10: 0x23 ID (u8 + a per-view byte), 0x22 precedence u16, 0x11 IP
    // version, 0x12 / 0x13 IPv4 src / dst (addr + mask), 0x16 / 0x17 IPv6 src / dst (addr +
    // prefix), 0x14 protocol, 0x1B / 0x1C TCP src / dst port + range, 0x1D / 0x1E UDP.
    // Unknown nested types are skipped.
    static func parseFilters(_ v: [UInt8]) -> [PacketFilter] {
        nested(v).filter { $0.type == 0x10 }.compactMap { parseFilter($0.value) }
            .sorted { $0.precedence < $1.precedence }
    }

    static func parseFilter(_ v: [UInt8]) -> PacketFilter? {
        let t = nested(v).valuesByType
        var p = ByteReader(t[0x22] ?? [])
        guard let version = t[0x11]?.first, version == 4 || version == 6,
              let id = t[0x23]?.first, let precedence = try? p.u16() else { return nil }
        var f = PacketFilter(id: id, precedence: precedence, ipVersion: version)
        if let a = t[0x12], a.count == 8 { f.source = v4Prefix(a, 0) }
        if let a = t[0x13], a.count == 8 { f.destination = v4Prefix(a, 0) }
        if let a = t[0x16], a.count == 17 { f.source = v6Prefix(a, 0) }
        if let a = t[0x17], a.count == 17 { f.destination = v6Prefix(a, 0) }
        if let p = t[0x14]?.first, p != 0 { f.ipProtocol = p }
        let (src, dst): (UInt8, UInt8) = f.ipProtocol == 17 ? (0x1D, 0x1E) : (0x1B, 0x1C)
        if let a = t[src], a.count == 4 { f.sourcePorts = portRange(a, 0) }
        if let a = t[dst], a.count == 4 { f.destinationPorts = portRange(a, 0) }
        return f
    }

    // MARK: Bytes

    static func nested(_ v: [UInt8]) -> [TLV] { TLV.decodePartialList(v) }

    private static func nonzero(_ v: UInt64) -> UInt64? { v == 0 ? nil : v }

    // Port and range, u16 each (4 bytes).
    private static func portRange(_ b: [UInt8], _ o: Int) -> ClosedRange<UInt16> {
        var r = ByteReader(b, offset: o)
        let port = try! r.u16(), range = try! r.u16()
        return port...(port &+ range < port ? .max : port + range)
    }

    // IPv4 address and netmask, both u32 little-endian (8 bytes).
    private static func v4Prefix(_ b: [UInt8], _ o: Int) -> Prefix {
        var mask = ByteReader(b, offset: o + 4)
        return Prefix(address: IPv4(qmi: Array(b[o..<o + 4]))!.description, length: try! mask.u32().nonzeroBitCount)
    }

    // IPv6 address (16 bytes, network order) and prefix length.
    private static func v6Prefix(_ b: [UInt8], _ o: Int) -> Prefix {
        Prefix(address: IPv6(Array(b[o..<o + 16])).description, length: Int(b[o + 16]))
    }
}
