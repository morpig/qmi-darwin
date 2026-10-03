import Foundation

// Only the messages qmi-darwin uses (PLAN.md §4). IDs and TLV numbers follow the public QMI
// service definitions.

// MARK: - CTL

public enum CTL {
    public static let getVersionInfo: UInt16 = 0x0021
    public static let getClientID: UInt16 = 0x0022
    public static let releaseClientID: UInt16 = 0x0023
    public static let sync: UInt16 = 0x0027

    public struct ServiceVersion: Equatable {
        public var service: QMIService
        public var major: UInt16
        public var minor: UInt16
    }

    public static func getClientIDRequest(_ service: QMIService) -> [TLV] {
        [.u8(0x01, service.rawValue)]
    }

    public static func releaseClientIDRequest(_ service: QMIService, _ client: UInt8) -> [TLV] {
        [TLV(0x01, [service.rawValue, client])]
    }

    public static func parseVersions(_ m: QMIMessage) throws -> [ServiceVersion] {
        guard let v = m[tlv: 0x01] else { throw DecodeError.invalid("version info: no TLV 0x01") }
        var r = ByteReader(v)
        let count = Int(try r.u8("count"))
        return try (0..<count).map { _ in
            ServiceVersion(service: QMIService(rawValue: try r.u8()), major: try r.u16(), minor: try r.u16())
        }
    }

    public static func parseAllocatedClient(_ m: QMIMessage) throws -> (QMIService, UInt8) {
        guard let v = m[tlv: 0x01], v.count >= 2 else { throw DecodeError.invalid("client id: no TLV 0x01") }
        return (QMIService(rawValue: v[0]), v[1])
    }
}

// MARK: - WDA

public enum WDA {
    public static let setDataFormat: UInt16 = 0x0020
    public static let getDataFormat: UInt16 = 0x0021

    public enum LinkLayer: UInt32 { case ethernet = 1, rawIP = 2 }
    public enum Aggregation: UInt32 {
        case disabled = 0, tlp = 1, qcNCM = 2, mbim = 3, rndis = 4, qmap = 5, qmapV2 = 6,
             qmapV3 = 7, qmapV4 = 8, qmapV5 = 9
    }

    // Endpoint type in data-port TLVs.
    public static let endpointHSUSB: UInt32 = 2

    public struct Request {
        public var linkLayer: LinkLayer = .rawIP
        public var uplinkAggregation: Aggregation = .qmap
        public var downlinkAggregation: Aggregation = .qmap
        // Aggregation sizes are deliberately below what the modem grants: its maximums are
        // accepted but not sustained under load (DL 63 datagrams and UL 32 x 32 KB hang the
        // RM551E). Tested values and measurements: plans/datapath-tuning.md.
        public var downlinkMaxDatagrams: UInt32 = 32
        public var downlinkMaxSize: UInt32 = 31744          // the modem's own buffer size
        // Always sent: without them the modem grants 1 datagram per uplink transfer, so every
        // TCP ACK becomes its own USB transfer. During downloads the uplink is mostly ~60-byte
        // ACKs, so the datagram count decides how many share a transfer.
        public var uplinkMaxDatagrams: UInt32 = 32
        public var uplinkMaxSize: UInt32 = 16384
        // QMAP flow control (TLV 0x1A); nil leaves it out. The RM551E grants it off when absent.
        public var flowControl: Bool?
        public var endpointInterface: UInt32?

        public init(endpointInterface: UInt32?) { self.endpointInterface = endpointInterface }

        public var tlvs: [TLV] {
            var t: [TLV] = [
                .u8(0x10, 0),                                  // QoS format: off
                .u32(0x11, linkLayer.rawValue),
                .u32(0x12, uplinkAggregation.rawValue),
                .u32(0x13, downlinkAggregation.rawValue),
                .u32(0x15, downlinkMaxDatagrams),
                .u32(0x16, downlinkMaxSize)
            ]
            if let iface = endpointInterface {
                var w = ByteWriter(); w.u32(endpointHSUSB); w.u32(iface)
                t.append(TLV(0x17, w.bytes))
            }
            if let fc = flowControl { t.append(.u8(0x1A, fc ? 1 : 0)) }
            t.append(.u32(0x1B, uplinkMaxDatagrams))
            t.append(.u32(0x1C, uplinkMaxSize))
            return t
        }
    }

    // What the modem granted. Absent TLVs stay nil.
    public struct Granted: Equatable {
        public var qosFormat: Bool?
        public var linkLayer: UInt32?
        public var uplinkAggregation: UInt32?
        public var downlinkAggregation: UInt32?
        public var downlinkMaxDatagrams: UInt32?
        public var downlinkMaxSize: UInt32?
        public var uplinkMaxDatagrams: UInt32?
        public var uplinkMaxSize: UInt32?
        public var downlinkMinPadding: UInt32?
        public var flowControl: Bool?

        // Why the datapath can't run on this grant, or nil. QDModem speaks raw IP with QMAP v1
        // both ways and no QoS header. Absent uplink/QoS TLVs are taken as our request; only an
        // explicit other value is refused (link layer and downlink must be present).
        public var datapathProblem: String? {
            func show(_ v: UInt32?) -> String { v.map(String.init) ?? "absent" }
            if linkLayer != LinkLayer.rawIP.rawValue { return "link layer \(show(linkLayer)), not raw IP" }
            if downlinkAggregation != Aggregation.qmap.rawValue {
                return "downlink aggregation \(show(downlinkAggregation)), not QMAP"
            }
            if let ul = uplinkAggregation, ul != Aggregation.qmap.rawValue { return "uplink aggregation \(ul), not QMAP" }
            if qosFormat == true { return "QoS header on" }
            return nil
        }
    }

    public static func parseGranted(_ m: QMIMessage) -> Granted {
        func u32(_ t: UInt8) -> UInt32? { m[tlv: t].flatMap { var r = ByteReader($0); return try? r.u32() } }
        return Granted(
            qosFormat: m[tlv: 0x10].flatMap { $0.first.map { $0 != 0 } },
            linkLayer: u32(0x11), uplinkAggregation: u32(0x12), downlinkAggregation: u32(0x13),
            downlinkMaxDatagrams: u32(0x15), downlinkMaxSize: u32(0x16),
            uplinkMaxDatagrams: u32(0x17), uplinkMaxSize: u32(0x18), downlinkMinPadding: u32(0x1A),
            flowControl: m[tlv: 0x1B].flatMap { $0.first.map { $0 != 0 } })
    }
}

// MARK: - WDS

public enum WDS {
    public static let startNetworkInterface: UInt16 = 0x0020
    public static let stopNetworkInterface: UInt16 = 0x0021
    public static let getPacketServiceStatus: UInt16 = 0x0022   // also the indication
    public static let getRuntimeSettings: UInt16 = 0x002D
    public static let getProfileList: UInt16 = 0x002A
    public static let getProfileSettings: UInt16 = 0x002B
    public static let setIPFamily: UInt16 = 0x004D
    public static let bindMuxDataPort: UInt16 = 0x00A2
    public static let indicationRegister: UInt16 = 0x0003
    public static let ambrIndication: UInt16 = 0x011E
    public static let getAMBRInfo: UInt16 = 0x011F

    // APN-AMBR of the call the client carries, bits per second (Get AMBR Info and the AMBR
    // indication: TLV 0x10 uplink, 0x11 downlink, u64).
    public struct AMBR: Equatable {
        public var uplink: UInt64
        public var downlink: UInt64
        public init(uplink: UInt64, downlink: UInt64) { self.uplink = uplink; self.downlink = downlink }
    }

    public static func parseAMBR(_ m: QMIMessage) -> AMBR? {
        func u64(_ t: UInt8) -> UInt64? {
            guard let v = m[tlv: t], v.count == 8 else { return nil }
            return (0..<8).reduce(UInt64(0)) { $0 | UInt64(v[$1]) << (8 * UInt64($1)) }
        }
        guard let ul = u64(0x10), let dl = u64(0x11) else { return nil }
        return AMBR(uplink: ul, downlink: dl)
    }

    // Indication Register: report AMBR changes (TLV 0x3B) on this client.
    public static func ambrIndicationRequest() -> [TLV] { [.u8(0x3B, 1)] }

    public static func bindMuxDataPortRequest(interface: UInt32, muxID: UInt8) -> [TLV] {
        var ep = ByteWriter(); ep.u32(WDA.endpointHSUSB); ep.u32(interface)
        return [TLV(0x10, ep.bytes), .u8(0x11, muxID), .u32(0x13, 1)]   // client type 1 = tethered
    }

    public static func startRequest(profile: UInt8?, apn: String?, family: UInt8) -> [TLV] {
        var t: [TLV] = [.u8(0x19, family)]                 // IP family preference: 4 or 6
        if let apn { t.append(.string(0x14, apn)) }
        if let profile { t.append(.u8(0x31, profile)) }  // 3GPP profile index
        return t
    }

    public static func parseHandle(_ m: QMIMessage) -> UInt32? {
        m[tlv: 0x01].flatMap { var r = ByteReader($0); return try? r.u32() }
    }

    public struct CallEnd: CustomStringConvertible, Equatable {
        public var reason: UInt16?
        public var verboseType: UInt16?
        public var verboseReason: UInt16?

        public var isPermanent: Bool {
            guard let t = verboseType, let r = verboseReason else { return false }
            switch t {
            case 6: return WDS.permanent3GPPCauses.contains(r)
            // Internal: PDN IPv4 / IPv6 call disallowed (the modem refuses the family on this
            // PDN because the network granted only the other one). 209/211 "throttled" are
            // temporary and go through backoff.
            case 2: return r == 208 || r == 210
            default: return false
            }
        }

        // Rejections of the APN itself, not of one IP family: no family will do better.
        public var isAPNLevel: Bool {
            verboseType == 6 && verboseReason.map(WDS.apnLevel3GPPCauses.contains) == true
        }

        // Verbose call end reason types.
        static let verboseTypes: [UInt16: String] = [1: "MIP", 2: "internal", 3: "CM", 6: "3GPP", 7: "PPP", 8: "EHRPD", 9: "IPv6"]

        // The official name of the cause: TS 24.301 for 3GPP, the public QMI definitions for the others. nil when
        // the code isn't in the tables (then only the number is shown, nothing made up).
        public var name: String? {
            guard let t = verboseType, let r = verboseReason else { return nil }
            switch t {
            case 6: return WDS.esmCauses[r]
            case 2: return WDS.internalCauses[r]
            case 3: return WDS.cmCauses[r]
            default: return nil
            }
        }

        // "3GPP #33: Requested service option not subscribed", "internal #218: MMGSDI card
        // event"; without a verbose cause, the call end reason: "call end reason 1018: GSM/WCDMA
        // option unsubscribed".
        public var text: String {
            if let t = verboseType, let r = verboseReason {
                let code = "\(Self.verboseTypes[t] ?? "type \(t)") #\(r)"
                return name.map { "\(code): \($0)" } ?? code
            }
            let code = "call end reason \(reason.map(String.init) ?? "?")"
            return reason.flatMap { WDS.callEndReasons[$0] }.map { "\(code): \($0)" } ?? code
        }

        // For clients, apart: the type ("3GPP", "internal", "CM", …; "call end reason" when the
        // modem gave no verbose cause), the number and its name (nil when not in the tables).
        public var typeName: String { verboseType.map { Self.verboseTypes[$0] ?? "type \($0)" } ?? "call end reason" }
        public var code: UInt16? { verboseType != nil ? verboseReason : reason }
        public var codeName: String? { verboseType != nil ? name : reason.flatMap { WDS.callEndReasons[$0] } }

        // For the log: also the call end reason next to a verbose cause.
        public var description: String {
            guard verboseType != nil, verboseReason != nil, let r = reason else { return text }
            return "\(text) (call end reason \(r))"
        }
    }

    // 3GPP ESM causes (TS 24.301) that retrying won't fix: operator barred, unknown/missing APN,
    // authentication failed, rejected by the gateway or unspecified, option not
    // supported/subscribed, PDN type not allowed.
    public static let permanent3GPPCauses: Set<UInt16> = [8, 27, 29, 30, 31, 32, 33, 50, 51, 52]
    // The ones about the APN rather than an IP family: barred, unknown APN, authentication,
    // not supported, not subscribed.
    public static let apnLevel3GPPCauses: Set<UInt16> = [8, 27, 29, 32, 33]

    // ESM cause names, TS 24.301 section 9.9.4.4 / annex B.
    static let esmCauses: [UInt16: String] = [
        8: "Operator Determined Barring", 26: "Insufficient resources", 27: "Missing or unknown APN",
        28: "Unknown PDN type", 29: "User authentication failed",
        30: "Request rejected by Serving GW or PDN GW", 31: "Request rejected, unspecified",
        32: "Service option not supported", 33: "Requested service option not subscribed",
        34: "Service option temporarily out of order", 35: "PTI already in use", 36: "Regular deactivation",
        37: "EPS QoS not accepted", 38: "Network failure", 39: "Reactivation requested",
        41: "Semantic error in the TFT operation", 42: "Syntactical error in the TFT operation",
        43: "Invalid EPS bearer identity", 44: "Semantic errors in packet filter(s)",
        45: "Syntactical errors in packet filter(s)", 47: "PTI mismatch",
        49: "Last PDN disconnection not allowed", 50: "PDN type IPv4 only allowed",
        51: "PDN type IPv6 only allowed", 52: "Single address bearers only allowed",
        53: "ESM information not received", 54: "PDN connection does not exist",
        55: "Multiple PDN connections for a given APN not allowed",
        56: "Collision with network initiated request", 65: "Maximum number of EPS bearers reached",
        66: "Requested APN not supported in current RAT and PLMN combination", 81: "Invalid PTI value",
        95: "Semantically incorrect message", 96: "Invalid mandatory information",
        97: "Message type non-existent or not implemented", 98: "Message type not compatible with the protocol state",
        99: "Information element non-existent or not implemented", 100: "Conditional IE error",
        101: "Message not compatible with the protocol state", 111: "Protocol error, unspecified",
        112: "APN restriction value incompatible with active EPS bearer context",
        113: "Multiple accesses to a PDN connection not allowed",
    ]

    // Verbose type internal (the modem's own decisions).
    static let internalCauses: [UInt16: String] = [
        201: "error", 202: "call ended", 203: "unknown internal cause", 204: "unknown cause",
        205: "close in progress", 206: "network initiated termination", 207: "app preempted",
        208: "PDN IPv4 call disallowed", 209: "PDN IPv4 call throttled",
        210: "PDN IPv6 call disallowed", 211: "PDN IPv6 call throttled", 212: "modem restart",
        213: "PDP PPP not supported", 214: "unpreferred RAT", 215: "physical link close in progress",
        216: "APN pending handover", 217: "profile bearer incompatible", 218: "MMGSDI card event",
        219: "LPM or power down", 220: "APN disabled", 221: "MPIT expired",
        222: "IPv6 address transfer failed", 223: "TRAT swap failed", 224: "EHRPD to HRPD fallback",
        225: "mandatory APN disabled", 226: "MIP config failure", 227: "PDN inactivity timer expired",
        228: "max v4 connections", 229: "max v6 connections", 230: "APN mismatch",
    ]

    // Verbose type CM (call manager).
    static let cmCauses: [UInt16: String] = [
        2000: "client end", 2001: "no service", 2002: "fade", 2003: "release normal",
        2004: "access attempt in progress", 2005: "access failure", 2006: "redirection or handoff",
        2500: "offline", 2501: "emergency mode", 2502: "phone in use", 2503: "invalid mode",
        2504: "invalid SIM state", 2505: "no collocated HDR", 2506: "call control rejected",
        2507: "EMM detached PSM", 2508: "dual switch", 2509: "call manager", 2510: "invalid class3 APN",
    ]

    // Call end reason (TLV 0x10), shown when there is no verbose cause.
    static let callEndReasons: [UInt16: String] = [
        1: "generic unspecified", 2: "generic client end", 3: "generic no service",
        9: "generic close in progress", 10: "generic authentication failed", 11: "generic internal error",
        236: "generic call already present",
        1000: "GSM/WCDMA conference failed", 1001: "GSM/WCDMA incoming rejected", 1002: "GSM/WCDMA no service",
        1003: "GSM/WCDMA network end", 1004: "GSM/WCDMA LLC SNDCP failure",
        1005: "GSM/WCDMA insufficient resources", 1006: "GSM/WCDMA option temporarily out of order",
        1007: "GSM/WCDMA NSAPI already used", 1008: "GSM/WCDMA regular deactivation",
        1009: "GSM/WCDMA network failure", 1010: "GSM/WCDMA reattach required", 1011: "GSM/WCDMA protocol error",
        1012: "GSM/WCDMA operator determined barring", 1013: "GSM/WCDMA unknown APN",
        1014: "GSM/WCDMA unknown PDP", 1015: "GSM/WCDMA GGSN reject", 1016: "GSM/WCDMA activation reject",
        1017: "GSM/WCDMA option not supported", 1018: "GSM/WCDMA option unsubscribed",
        1019: "GSM/WCDMA QoS not accepted", 1020: "GSM/WCDMA TFT semantic error",
        1021: "GSM/WCDMA TFT syntax error", 1022: "GSM/WCDMA unknown PDP context",
        1023: "GSM/WCDMA filter semantic error", 1024: "GSM/WCDMA filter syntax error",
        1025: "GSM/WCDMA PDP without active TFT", 1026: "GSM/WCDMA invalid transaction ID",
        1027: "GSM/WCDMA message incorrect semantic", 1028: "GSM/WCDMA invalid mandatory info",
        1029: "GSM/WCDMA message type unsupported", 1030: "GSM/WCDMA message type noncompatible state",
    ]

    public static func parseCallEnd(_ m: QMIMessage) -> CallEnd {
        var e = CallEnd()
        if let v = m[tlv: 0x10] { var r = ByteReader(v); e.reason = try? r.u16() }
        if let v = m[tlv: 0x11] { var r = ByteReader(v); e.verboseType = try? r.u16(); e.verboseReason = try? r.u16() }
        return e
    }

    public struct SettingsMask: OptionSet {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let profileID = SettingsMask(rawValue: 1 << 0)
        public static let pdpType = SettingsMask(rawValue: 1 << 2)
        public static let apnName = SettingsMask(rawValue: 1 << 3)
        public static let dnsAddress = SettingsMask(rawValue: 1 << 4)
        public static let ipAddress = SettingsMask(rawValue: 1 << 8)
        public static let gatewayInfo = SettingsMask(rawValue: 1 << 9)
        public static let pcscfUsingPCO = SettingsMask(rawValue: 1 << 10)
        public static let pcscfServerList = SettingsMask(rawValue: 1 << 11)
        public static let mtu = SettingsMask(rawValue: 1 << 13)
        public static let ipFamily = SettingsMask(rawValue: 1 << 15)
        public static let all: SettingsMask = [.profileID, .pdpType, .apnName, .dnsAddress, .ipAddress,
                                               .gatewayInfo, .pcscfUsingPCO, .pcscfServerList, .mtu, .ipFamily]
    }

    public static func runtimeSettingsRequest(_ mask: SettingsMask = .all) -> [TLV] {
        [.u32(0x10, mask.rawValue)]
    }

    public struct RuntimeSettings: Equatable {
        public var apn: String?
        public var ipFamily: UInt8?
        public var mtu: UInt32?
        public var ipv4Address: IPv4?
        public var ipv4Gateway: IPv4?
        public var ipv4SubnetMask: IPv4?
        public var ipv4DNS: [IPv4] = []
        public var ipv6Address: IPv6Prefix?
        public var ipv6Gateway: IPv6Prefix?
        public var ipv6DNS: [IPv6] = []
        public var pcscfIPv4: [IPv4] = []
        public var pcscfIPv6: [IPv6] = []

        public init() {}
    }

    public static func parseRuntimeSettings(_ m: QMIMessage) -> RuntimeSettings {
        var s = RuntimeSettings()
        func v4(_ t: UInt8) -> IPv4? { m[tlv: t].flatMap(IPv4.init(qmi:)) }
        func v6(_ t: UInt8) -> IPv6? { m[tlv: t].flatMap { $0.count >= 16 ? IPv6(Array($0.prefix(16))) : nil } }
        func v6p(_ t: UInt8) -> IPv6Prefix? {
            m[tlv: t].flatMap { $0.count >= 17 ? IPv6Prefix(address: IPv6(Array($0.prefix(16))), length: $0[16]) : nil }
        }
        s.apn = m[tlv: 0x14].map { String(decoding: $0, as: UTF8.self) }
        s.ipFamily = m[tlv: 0x2B]?.first
        s.mtu = m[tlv: 0x29].flatMap { var r = ByteReader($0); return try? r.u32() }
        s.ipv4Address = v4(0x1E)
        s.ipv4Gateway = v4(0x20)
        s.ipv4SubnetMask = v4(0x21)
        s.ipv4DNS = [v4(0x15), v4(0x16)].compactMap { $0 }.filter { !$0.isZero }
        s.ipv6Address = v6p(0x25)
        s.ipv6Gateway = v6p(0x26)
        s.ipv6DNS = [v6(0x27), v6(0x28)].compactMap { $0 }.filter { !$0.isZero }
        if let v = m[tlv: 0x23] {
            var r = ByteReader(v)
            if let n = try? r.u8() {
                s.pcscfIPv4 = (0..<Int(n)).compactMap { _ in (try? r.take(4)).flatMap(IPv4.init(qmi:)) }
            }
        }
        if let v = m[tlv: 0x2E] {
            var r = ByteReader(v)
            if let n = try? r.u8() {
                s.pcscfIPv6 = (0..<Int(n)).compactMap { _ in (try? r.take(16)).map(IPv6.init) }
            }
        }
        return s
    }

    public struct PacketServiceStatus: Equatable {
        public var connection: UInt8          // 1 disconnected, 2 connected, 3 suspended, 4 authenticating
        public var reconfigurationRequired: Bool
        public var callEnd: CallEnd

        public var connectionName: String {
            [1: "disconnected", 2: "connected", 3: "suspended", 4: "authenticating"][connection] ?? "state \(connection)"
        }
    }

    public static func parsePacketServiceStatus(_ m: QMIMessage) -> PacketServiceStatus? {
        guard let v = m[tlv: 0x01], v.count >= 1 else { return nil }
        return PacketServiceStatus(connection: v[0], reconfigurationRequired: v.count > 1 && v[1] != 0,
                                   callEnd: parseCallEnd(m))
    }
}

// MARK: - NAS

public enum NAS {
    public static let registerIndications: UInt16 = 0x0003
    public static let getServingSystem: UInt16 = 0x0024     // also the Serving System indication
    public static let servingSystemEvents: TLV = .u8(0x13, 1)

    public struct ServingSystem: Equatable {
        public var registration: UInt8
        public var csAttached: Bool
        public var psAttached: Bool
        public var radioInterfaces: [UInt8]
        public var mcc: UInt16?
        public var mnc: UInt16?
        public var operatorName: String?

        public var registrationName: String {
            [0: "not-registered", 1: "registered", 2: "searching", 3: "denied", 4: "unknown"][registration]
                ?? "state \(registration)"
        }

        public static func radioName(_ r: UInt8) -> String {
            [0: "none", 1: "cdma1x", 2: "evdo", 4: "gsm", 5: "umts", 8: "lte", 9: "td-scdma", 12: "5gnr"][r]
                ?? "rat \(r)"
        }
    }

    // Get Home Network: the SIM's home PLMN (unchanged while roaming).
    public static let getHomeNetwork: UInt16 = 0x0025

    public struct HomeNetwork: Equatable {
        public var mcc: UInt16
        public var mnc: UInt16
        public var threeDigitMNC: Bool
        public var name: String?

        // "00101", "001001": MCC, then the MNC with 2 or 3 digits.
        public var mccmnc: String {
            String(format: "%03d", mcc) + String(format: threeDigitMNC ? "%03d" : "%02d", mnc)
        }
    }

    public static func parseHomeNetwork(_ m: QMIMessage) throws -> HomeNetwork {
        guard let v = m[tlv: 0x01] else { throw DecodeError.invalid("home network: no TLV 0x01") }
        var r = ByteReader(v)
        let mcc = try r.u16("mcc"), mnc = try r.u16("mnc")
        var name: String?
        if let len = try? r.u8(), let b = try? r.take(Int(len)), !b.isEmpty { name = String(decoding: b, as: UTF8.self) }
        // TLV 0x13: is-3GPP, MNC includes PCS digit (the 3-digit flag). Without it, only an MNC
        // above 99 tells.
        let pcs = m[tlv: 0x13].flatMap { $0.count >= 2 ? $0[1] != 0 : nil } ?? false
        return HomeNetwork(mcc: mcc, mnc: mnc, threeDigitMNC: pcs || mnc > 99, name: name)
    }

    // Operator names. The network sends its own names in EMM/MM Information (NITZ); Get
    // Operator Name Data reports them (TLV 0x14) and the Operator Name Data indication pushes
    // them when they arrive. Without NITZ, Get PLMN Name gives the modem's choice for an MCC/MNC
    // (SIM OPL/PNN or the firmware's operator table).
    public static let getOperatorNameData: UInt16 = 0x0039
    public static let operatorNameDataIndication: UInt16 = 0x003A
    public static let networkTimeIndication: UInt16 = 0x004C    // also sent on EMM Information
    public static let getPLMNName: UInt16 = 0x0044
    // Register Indications TLVs, each sent on its own (best effort): network time, and 0x22,
    // after which the modem sent Operator Name Data indications (tested on a Quectel 2c7c:0122).
    public static let networkTimeEvents: TLV = .u8(0x17, 1)
    public static let operatorNameEvents: TLV = .u8(0x22, 1)

    // Get Sys Info and its indication. Only the LTE emergency fields are read: whether the
    // network supports emergency bearers (EMC BS in the Attach/TAU Accept, TS 24.301; a UE
    // shouldn't request an emergency PDN without it) and whether emergency access is barred.
    // TLVs 0x39 / 0x3E in the response, 0x3A / 0x3F in the indication (survey of 2026-10-02).
    public static let getSysInfo: UInt16 = 0x004D
    public static let sysInfoIndication: UInt16 = 0x004E
    public static let sysInfoEvents: TLV = .u8(0x18, 1)

    public struct LTEEmergency: Equatable {
        public var bearers: Bool?           // nil: the message didn't say
        public var accessBarred: Bool?
        public init(bearers: Bool? = nil, accessBarred: Bool? = nil) {
            self.bearers = bearers
            self.accessBarred = accessBarred
        }
    }

    public static func parseLTEEmergency(_ m: QMIMessage) -> LTEEmergency {
        let ind = m.messageID == sysInfoIndication
        // A 4-byte enum: 0 no, 1 yes; 2 while not registered (seen during a SIM switch) and
        // anything else = unknown.
        func flag(_ t: UInt8) -> Bool? {
            guard let v = m[tlv: t], !v.isEmpty, v.count <= 4 else { return nil }
            switch v.reversed().reduce(UInt32(0), { $0 << 8 | UInt32($1) }) {
            case 0: return false
            case 1: return true
            default: return nil
            }
        }
        return LTEEmergency(bearers: flag(ind ? 0x3A : 0x39), accessBarred: flag(ind ? 0x3F : 0x3E))
    }

    public struct NetworkName: Equatable {
        public var longName: String?
        public var shortName: String?

        public init(longName: String? = nil, shortName: String? = nil) {
            self.longName = longName
            self.shortName = shortName
        }

        public var isEmpty: Bool { longName == nil && shortName == nil }
    }

    // TLV 0x14, NITZ information: encoding (0 packed GSM 7-bit, 1 UCS-2), country initials and
    // spare bits (3 bytes), then the long and the short name, each length + bytes.
    // nil when the network hasn't sent names (the TLV is absent, e.g. while detached).
    public static func parseNITZName(_ m: QMIMessage) -> NetworkName? {
        guard let v = m[tlv: 0x14] else { return nil }
        var r = ByteReader(v)
        guard let enc = try? r.u8(), (try? r.take(3)) != nil else { return nil }
        var n = NetworkName()
        if let len = try? r.u8(), let b = try? r.take(Int(len)) { n.longName = decodeNetworkName(b, encoding: enc, packed: true) }
        if let len = try? r.u8(), let b = try? r.take(Int(len)) { n.shortName = decodeNetworkName(b, encoding: enc, packed: true) }
        return n.isEmpty ? nil : n
    }

    // TLV 0x10, the SIM's Service Provider Name (EF_SPN): display condition, length, name as
    // stored on the SIM (8-bit GSM alphabet, or UCS-2 after a 0x80 byte).
    public static func parseSPN(_ m: QMIMessage) -> String? {
        guard let v = m[tlv: 0x10] else { return nil }
        var r = ByteReader(v)
        guard (try? r.u8()) != nil, let len = try? r.u8(), let b = try? r.take(Int(len)) else { return nil }
        let name = b.prefix { $0 != 0xFF }
        if name.first == 0x80 { return decodeNetworkName(Array(name.dropFirst()), encoding: 1, packed: false) }
        return decodeNetworkName(Array(name), encoding: 0, packed: false)
    }

    // The SIM's own name for a PLMN: TLV 0x11 (EF_OPL: count, then per entry the PLMN as 6
    // characters, "00101F", "D" matching any digit; LAC range; PNN record number) points into
    // TLV 0x12 (EF_PNN: count, then per record encoding, 2 bytes country initials/spare bits,
    // long and short name, each length + bytes). Without an OPL entry, PNN record 1 names the
    // home PLMN (TS 31.102). The LAC range is not checked. PNN records are taken in order, so
    // record N is entry N (the modem leaves out empty records; seen with record 1 only).
    public static func parseSIMPLMNName(_ m: QMIMessage, mccmnc: String, home: Bool) -> NetworkName? {
        var names: [NetworkName] = []
        if let v = m[tlv: 0x12] {
            var r = ByteReader(v)
            let count = (try? r.u16()) ?? 0
            for _ in 0..<count {
                guard let enc = try? r.u8(), (try? r.take(2)) != nil,
                      let ll = try? r.u8(), let lb = try? r.take(Int(ll)),
                      let sl = try? r.u8(), let sb = try? r.take(Int(sl)) else { break }
                names.append(NetworkName(longName: decodeNetworkName(lb, encoding: enc, packed: true),
                                         shortName: decodeNetworkName(sb, encoding: enc, packed: true)))
            }
        }
        var record: Int? = home ? 1 : nil
        if let v = m[tlv: 0x11] {
            var r = ByteReader(v)
            let count = (try? r.u16()) ?? 0
            for _ in 0..<count {
                guard let p = try? r.take(6), (try? r.take(4)) != nil, let rec = try? r.u8() else { break }
                if plmnMatches(p, mccmnc) { record = Int(rec); break }
            }
        }
        guard let record, record >= 1, record <= names.count, !names[record - 1].isEmpty else { return nil }
        return names[record - 1]
    }

    // "00101F" / "001D1F" against "00101"; 3-digit MNCs have no F.
    static func plmnMatches(_ pattern: [UInt8], _ mccmnc: String) -> Bool {
        let p = pattern.filter { $0 != UInt8(ascii: "F") && $0 != UInt8(ascii: "f") }
        let m = Array(mccmnc.utf8)
        guard p.count == m.count else { return false }
        return zip(p, m).allSatisfy { $0 == $1 || $0 == UInt8(ascii: "D") || $0 == UInt8(ascii: "d") }
    }

    public static func plmnNameRequest(mcc: UInt16, mnc: UInt16) -> [TLV] {
        var w = ByteWriter()
        w.u16(mcc)
        w.u16(mnc)
        return [TLV(0x01, w.bytes)]
    }

    // Get PLMN Name TLV 0x10, 3GPP EONS PLMN Name: SPN (encoding, length, bytes), then the short
    // and the long name, each encoding, country initials, spare bits, length, bytes. Encoding 0
    // arrives unpacked here, one character per byte.
    public static func parsePLMNName(_ m: QMIMessage) throws -> NetworkName {
        guard let v = m[tlv: 0x10] else { throw DecodeError.invalid("plmn name: no TLV 0x10") }
        var r = ByteReader(v)
        _ = try r.u8("spn encoding")
        _ = try r.take(Int(try r.u8()), "spn")
        var n = NetworkName()
        for long in [false, true] {
            guard let enc = try? r.u8(), (try? r.take(2)) != nil,
                  let len = try? r.u8(), let b = try? r.take(Int(len)) else { break }
            let s = decodeNetworkName(b, encoding: enc, packed: false)
            if long { n.longName = s } else { n.shortName = s }
        }
        return n
    }

    static func decodeNetworkName(_ b: [UInt8], encoding: UInt8, packed: Bool) -> String? {
        guard !b.isEmpty else { return nil }
        let s: String
        if encoding == 1 {
            let units = stride(from: 0, to: b.count - 1, by: 2).map { UInt16(b[$0]) << 8 | UInt16(b[$0 + 1]) }
            s = String(decoding: units, as: UTF16.self)
        } else if packed {
            s = gsm7Unpacked(b)
        } else {
            s = String(b.map { Character(Unicode.Scalar($0)) })
        }
        // A "name" without letters is the MCC/MNC as text ("001 01", from Get PLMN Name for a
        // PLMN the modem has no name for): no name.
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return t.contains(where: \.isLetter) ? t : nil
    }

    // Packed GSM 7-bit default alphabet (TS 23.038), basic set; escapes and the rest as "?".
    // Seven spare bits at the end would read as one extra "@" (0), so a final 0 is dropped.
    static func gsm7Unpacked(_ b: [UInt8]) -> String {
        let table = Array("@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞ\u{1b}ÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?"
                          + "¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà")
        var septets: [Int] = []
        for i in 0..<(b.count * 8 / 7) {
            let bit = i * 7, byte = bit / 8, shift = bit % 8
            var c = Int(b[byte]) >> shift
            if shift > 1, byte + 1 < b.count { c |= Int(b[byte + 1]) << (8 - shift) }
            septets.append(c & 0x7f)
        }
        if b.count * 8 % 7 == 0, septets.last == 0 { septets.removeLast() }
        return String(septets.map { $0 == 0x1b ? "?" : table[$0] })
    }

    public static func parseServingSystem(_ m: QMIMessage) throws -> ServingSystem {
        guard let v = m[tlv: 0x01] else { throw DecodeError.invalid("serving system: no TLV 0x01") }
        var r = ByteReader(v)
        let reg = try r.u8(), cs = try r.u8(), ps = try r.u8()
        _ = try r.u8()                                           // selected network
        let n = Int(try r.u8())
        let rats = try r.take(n)
        var s = ServingSystem(registration: reg, csAttached: cs == 1, psAttached: ps == 1, radioInterfaces: rats)
        if let p = m[tlv: 0x12] {
            var pr = ByteReader(p)
            s.mcc = try? pr.u16()
            s.mnc = try? pr.u16()
            if let len = try? pr.u8(), let name = try? pr.take(Int(len)) {
                s.operatorName = String(decoding: name, as: UTF8.self)
            }
        }
        return s
    }
}

// MARK: - DMS

public enum DMS {
    public static let getIDs: UInt16 = 0x0025
    public static let getRevision: UInt16 = 0x0023
    public static let uimGetICCID: UInt16 = 0x003C

    // ICCID as ASCII digits.
    public static func parseICCID(_ m: QMIMessage) -> String? {
        m[tlv: 0x01].map { String(decoding: $0, as: UTF8.self) }.flatMap(ICCID.normalize)
    }

    public static func parseRevision(_ m: QMIMessage) -> String? {
        m[tlv: 0x01].map { String(decoding: $0, as: UTF8.self) }
    }

    public static func parseIMEI(_ m: QMIMessage) -> String? {
        m[tlv: 0x11].map { String(decoding: $0, as: UTF8.self) }
    }
}

// MARK: - UIM

public enum UIM {
    public static let getCardStatus: UInt16 = 0x002F
    public static let readTransparent: UInt16 = 0x0020

    // Read Transparent of EF_ICCID (2FE2 under the MF) on the card in slot 1.
    public static let readICCIDRequest: [TLV] = [
        TLV(0x01, [0x06, 0x00]),                       // session: card on slot 1, no AID
        TLV(0x02, [0xE2, 0x2F, 0x02, 0x00, 0x3F]),     // file 2FE2, path 3F00
        TLV(0x03, [0x00, 0x00, 0x00, 0x00]),           // offset 0, length 0 (whole file)
    ]

    public static func parseICCID(_ m: QMIMessage) -> String? {
        guard let v = m[tlv: 0x11], v.count > 2 else { return nil }
        return ICCID.fromBCD(Array(v.dropFirst(2)))
    }

    public struct Card: Equatable {
        public var state: UInt8                  // 0 absent, 1 present, 2 error
        public var applications: [(type: UInt8, state: UInt8)]

        public static func == (a: Card, b: Card) -> Bool {
            a.state == b.state && a.applications.map { [$0.type, $0.state] } == b.applications.map { [$0.type, $0.state] }
        }

        public var stateName: String { [0: "absent", 1: "present", 2: "error"][state] ?? "state \(state)" }

        // Application state 7 = ready.
        public var isReady: Bool { state == 1 && applications.contains { $0.state == 7 } }
    }

    public static func parseCardStatus(_ m: QMIMessage) throws -> [Card] {
        guard let v = m[tlv: 0x10] else { throw DecodeError.invalid("card status: no TLV 0x10") }
        var r = ByteReader(v)
        _ = try r.take(8, "primary/secondary indexes")
        let cards = Int(try r.u8("cards"))
        var out: [Card] = []
        for _ in 0..<cards {
            let state = try r.u8("card state")
            _ = try r.take(4, "upin")                   // upin state, retries, puk retries, error code
            let apps = Int(try r.u8("apps"))
            var list: [(UInt8, UInt8)] = []
            for _ in 0..<apps {
                let type = try r.u8("app type"), appState = try r.u8("app state")
                _ = try r.take(4, "perso")              // perso state, feature, retries, unblock retries
                let aidLen = Int(try r.u8("aid len"))
                _ = try r.take(aidLen, "aid")
                _ = try r.take(7, "pins")               // upin replaces, pin1 x3, pin2 x3
                list.append((type, appState))
            }
            out.append(Card(state: state, applications: list))
        }
        return out
    }
}

// MARK: - ICCID

public enum ICCID {
    // EF_ICCID: BCD, low nibble first, F = padding.
    public static func fromBCD(_ bytes: [UInt8]) -> String? {
        var s = ""
        for b in bytes {
            for n in [b & 0x0F, b >> 4] where n < 10 { s.append(Character(String(n))) }
        }
        return normalize(s)
    }

    // Digits only, 18–22 long (some modems append F padding or a stray letter).
    public static func normalize(_ s: String) -> String? {
        let d = s.filter(\.isASCII).filter(\.isNumber)
        return (18...22).contains(d.count) ? d : nil
    }
}

// MARK: - Addresses

// QMI carries IPv4 addresses as little-endian u32 whose most significant byte is the first
// octet, so the wire bytes are the octets in reverse.
public struct IPv4: Equatable, Hashable, CustomStringConvertible {
    public var octets: [UInt8]

    public init(_ octets: [UInt8]) { self.octets = octets }

    public init?(qmi bytes: [UInt8]) {
        guard bytes.count >= 4 else { return nil }
        octets = Array(bytes.prefix(4).reversed())
    }

    public var isZero: Bool { octets.allSatisfy { $0 == 0 } }
    public var description: String { octets.map(String.init).joined(separator: ".") }

    public var prefixLength: Int {
        octets.reduce(0) { $0 + $1.nonzeroBitCount }
    }
}

public struct IPv6: Equatable, Hashable, CustomStringConvertible {
    public var bytes: [UInt8]

    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    public var isZero: Bool { bytes.allSatisfy { $0 == 0 } }

    public var description: String {
        var addr = in6_addr()
        withUnsafeMutableBytes(of: &addr) { $0.copyBytes(from: bytes.prefix(16)) }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &addr, &buf, socklen_t(buf.count)) != nil else { return bytes.hex }
        return String(cString: buf)
    }
}

public struct IPv6Prefix: Equatable, Hashable, CustomStringConvertible {
    public var address: IPv6
    public var length: UInt8

    public init(address: IPv6, length: UInt8) {
        self.address = address
        self.length = length
    }
    public var description: String { "\(address)/\(length)" }
}
