import Foundation

// WDS profile management (PLAN.md §4.2 item 4, "APN sync"). TLV numbers from the public
// QMI WDS definitions (common profile fields, APN type mask).
extension WDS {
    public static let createProfile: UInt16 = 0x0027
    public static let modifyProfile: UInt16 = 0x0028
    public static let deleteProfile: UInt16 = 0x0029
    public static let getAutoconnectSettings: UInt16 = 0x0034
    public static let setAutoconnectSettings: UInt16 = 0x0051
    public static let getLTEAttachPDNList: UInt16 = 0x0094
    public static let setLTEAttachPDNList: UInt16 = 0x0093
    public static let getLTEAttachParameters: UInt16 = 0x0085
    public static let configureProfileEventList: UInt16 = 0x00A7
    public static let profileChanged: UInt16 = 0x00A8

    public static let profileType3GPP: UInt8 = 0

    public enum PDPType: UInt8, CustomStringConvertible {
        case ipv4 = 0, ppp = 1, ipv6 = 2, ipv4v6 = 3, nonIP = 4
        public var description: String { ["ipv4", "ppp", "ipv6", "ipv4v6", "non-ip"][Int(rawValue)] }

        public init(families: [UInt8]) {
            self = families == [4] ? .ipv4 : families == [6] ? .ipv6 : .ipv4v6
        }
    }

    // Bitmask: none 0, PAP 1, CHAP 2, PAP-or-CHAP 3.
    public enum Authentication: UInt8, CustomStringConvertible {
        case none = 0, pap = 1, chap = 2, papOrChap = 3
        public var description: String { ["none", "pap", "chap", "pap-chap"][Int(rawValue)] }

        public init?(name: String) {
            switch name.lowercased() {
            case "none": self = .none
            case "pap": self = .pap
            case "chap": self = .chap
            case "pap-chap", "pap_chap", "both": self = .papOrChap
            default: return nil
            }
        }
    }

    public struct APNTypeMask: OptionSet, Equatable {
        public let rawValue: UInt64
        public init(rawValue: UInt64) { self.rawValue = rawValue }
        public static let `default` = APNTypeMask(rawValue: 1 << 0)
        public static let ims = APNTypeMask(rawValue: 1 << 1)
        public static let mms = APNTypeMask(rawValue: 1 << 2)
        public static let dun = APNTypeMask(rawValue: 1 << 3)
        public static let supl = APNTypeMask(rawValue: 1 << 4)
        public static let ia = APNTypeMask(rawValue: 1 << 8)
        public static let emergency = APNTypeMask(rawValue: 1 << 9)
        public static let ut = APNTypeMask(rawValue: 1 << 10)

        private static let all: [(APNTypeMask, String)] = [(.default, "default"), (.ims, "ims"), (.mms, "mms"), (.dun, "dun"),
                                                           (.supl, "supl"), (.ia, "ia"), (.emergency, "emergency"), (.ut, "ut")]

        // From the names `names` prints; nil if one is unknown.
        public init?(names: [String]) {
            var m = APNTypeMask()
            for n in names {
                guard let t = Self.all.first(where: { $0.1 == n.lowercased() })?.0 else { return nil }
                m.insert(t)
            }
            self = m
        }

        public var names: [String] {
            let all = Self.all
            let known = all.filter { contains($0.0) }.map(\.1)
            let rest = rawValue & ~all.reduce(0) { $0 | $1.0.rawValue }
            return known + (rest != 0 ? [String(format: "0x%llx", rest)] : [])
        }
    }

    // The subset of a 3GPP profile qmi-darwin reads and writes. nil = not present / don't touch.
    public struct Profile: Equatable {
        public var index: UInt8
        public var name: String?
        public var pdpType: PDPType?
        public var apn: String?
        public var username: String?
        public var password: String?
        public var authentication: Authentication?
        public var pcscfUsingPCO: Bool?
        public var pcscfUsingDHCP: Bool?
        public var imcn: Bool?
        public var apnType: APNTypeMask?
        public var apnDisabled: Bool?
        public var roamingDisallowed: Bool?
        public var contextNumber: UInt8?     // PDP context number (TLV 0x25) = the AT cid

        public init(index: UInt8) { self.index = index }

        // TLVs for Create/Modify Profile carrying every non-nil field.
        public var settingTLVs: [TLV] {
            var t: [TLV] = []
            if let name { t.append(.string(0x10, name)) }
            if let pdpType { t.append(.u8(0x11, pdpType.rawValue)) }
            if let apn { t.append(.string(0x14, apn)) }
            if let username { t.append(.string(0x1B, username)) }
            if let password { t.append(.string(0x1C, password)) }
            if let authentication { t.append(.u8(0x1D, authentication.rawValue)) }
            if let pcscfUsingPCO { t.append(.u8(0x1F, pcscfUsingPCO ? 1 : 0)) }
            if let pcscfUsingDHCP { t.append(.u8(0x21, pcscfUsingDHCP ? 1 : 0)) }
            if let imcn { t.append(.u8(0x22, imcn ? 1 : 0)) }
            if let apnDisabled { t.append(.u8(0x2F, apnDisabled ? 1 : 0)) }
            if let roamingDisallowed { t.append(.u8(0x3E, roamingDisallowed ? 1 : 0)) }
            if let contextNumber { t.append(.u8(0x25, contextNumber)) }
            if let apnType {
                var w = ByteWriter()
                w.u32(UInt32(truncatingIfNeeded: apnType.rawValue))
                w.u32(UInt32(truncatingIfNeeded: apnType.rawValue >> 32))
                t.append(TLV(0xDD, w.bytes))
            }
            return t
        }

        // Fields of `want` that differ from self (only fields `want` sets).
        public func differences(from want: Profile) -> [String] {
            var d: [String] = []
            func cmp<T: Equatable>(_ name: String, _ a: T?, _ b: T?) {
                if let b, a != b { d.append("\(name): \(a.map { "\($0)" } ?? "unset") → \(b)") }
            }
            // An absent string TLV and an empty one are the same setting (empty APN = network
            // default), and so are an absent auth TLV and auth none.
            if let wa = want.apn, (apn ?? "").lowercased() != wa.lowercased() {
                d.append("apn: \(apn.map { "\"\($0)\"" } ?? "unset") → \"\(wa)\"")
            }
            cmp("pdp-type", pdpType, want.pdpType)
            if let wu = want.username, (username ?? "") != wu { d.append("username: \"\(username ?? "")\" → \"\(wu)\"") }
            if let wp = want.password, (password ?? "") != wp { d.append("password") }
            cmp("auth", authentication ?? Authentication.none, want.authentication)
            cmp("pcscf-pco", pcscfUsingPCO, want.pcscfUsingPCO)
            cmp("imcn", imcn, want.imcn)
            if let wt = want.apnType, !(apnType ?? []).isSuperset(of: wt) {
                d.append("apn-type: \((apnType ?? []).names.joined(separator: "+")) → \(wt.names.joined(separator: "+"))")
            }
            cmp("apn-disabled", apnDisabled, want.apnDisabled)
            return d
        }

        public var summary: String {
            var s = "\(index): apn \"\(apn ?? "")\" \(pdpType.map { "\($0)" } ?? "?")"
            if let n = name, !n.isEmpty { s += " name \"\(n)\"" }
            if let a = authentication, a != .none { s += " auth \(a) user \"\(username ?? "")\"" }
            if pcscfUsingPCO == true { s += " pcscf-pco" }
            if pcscfUsingDHCP == true { s += " pcscf-dhcp" }
            if imcn == true { s += " imcn" }
            if let t = apnType, !t.isEmpty { s += " type \(t.names.joined(separator: "+"))" }
            if apnDisabled == true { s += " DISABLED" }
            if roamingDisallowed == true { s += " no-roaming" }
            return s
        }
    }

    public static func profileListRequest() -> [TLV] { [.u8(0x10, profileType3GPP)] }

    public static func parseProfileList(_ m: QMIMessage) throws -> [(index: UInt8, name: String)] {
        guard let v = m[tlv: 0x01] else { return [] }
        var r = ByteReader(v)
        let n = Int(try r.u8("count"))
        return try (0..<n).compactMap { _ in
            let type = try r.u8(), index = try r.u8()
            let len = Int(try r.u8())
            let name = String(decoding: try r.take(len), as: UTF8.self)
            return type == profileType3GPP ? (index, name) : nil
        }
    }

    public static func profileIdentifier(_ index: UInt8) -> TLV { TLV(0x01, [profileType3GPP, index]) }

    public static func parseProfile(_ m: QMIMessage, index: UInt8) -> Profile {
        var p = Profile(index: index)
        func str(_ t: UInt8) -> String? { m[tlv: t].map { String(decoding: $0, as: UTF8.self) } }
        func flag(_ t: UInt8) -> Bool? { m[tlv: t]?.first.map { $0 != 0 } }
        p.name = str(0x10)
        p.pdpType = m[tlv: 0x11]?.first.flatMap(PDPType.init(rawValue:))
        p.apn = str(0x14)
        p.username = str(0x1B)
        p.password = str(0x1C)
        p.authentication = m[tlv: 0x1D]?.first.flatMap(Authentication.init(rawValue:))
        p.pcscfUsingPCO = flag(0x1F)
        p.pcscfUsingDHCP = flag(0x21)
        p.imcn = flag(0x22)
        p.apnDisabled = flag(0x2F)
        p.roamingDisallowed = flag(0x3E)
        p.contextNumber = m[tlv: 0x25]?.first
        if let v = m[tlv: 0xDD], v.count >= 8 {
            var r = ByteReader(v)
            if let lo = try? r.u32(), let hi = try? r.u32() { p.apnType = APNTypeMask(rawValue: UInt64(hi) << 32 | UInt64(lo)) }
        }
        return p
    }

    public static func parseCreatedProfileIndex(_ m: QMIMessage) -> UInt8? {
        guard let v = m[tlv: 0x01], v.count >= 2 else { return nil }
        return v[1]
    }

    // Extended error (TLV 0xE0), e.g. why a profile write was refused.
    public static func parseExtendedError(_ m: QMIMessage) -> UInt16? {
        m[tlv: 0xE0].flatMap { var r = ByteReader($0); return try? r.u16() }
    }

    public enum AutoconnectSetting: UInt8, CustomStringConvertible {
        case disabled = 0, enabled = 1, paused = 2
        public var description: String { ["disabled", "enabled", "paused"][Int(rawValue)] }
    }

    public static func parseAutoconnect(_ m: QMIMessage) -> AutoconnectSetting? {
        m[tlv: 0x01]?.first.flatMap(AutoconnectSetting.init(rawValue:))
    }

    public static func parseAttachPDNList(_ m: QMIMessage) -> (current: [UInt16], pending: [UInt16]) {
        func list(_ t: UInt8) -> [UInt16] {
            guard let v = m[tlv: t] else { return [] }
            var r = ByteReader(v)
            guard let n = try? r.u8() else { return [] }
            return (0..<Int(n)).compactMap { _ in try? r.u16() }
        }
        return (list(0x10), list(0x11))
    }

    // The default bearer as attached: its APN (the network's choice when the attach profile's
    // APN is empty), IP type, and whether an over-the-air attach was performed.
    public struct AttachParameters: Equatable {
        public var apn: String?
        public var ipType: UInt8?
        public var otaAttach: Bool?
    }

    public static func parseAttachParameters(_ m: QMIMessage) -> AttachParameters {
        AttachParameters(apn: m[tlv: 0x10].map { String(decoding: $0, as: UTF8.self) },
                         ipType: m[tlv: 0x11]?.first,
                         otaAttach: m[tlv: 0x12]?.first.map { $0 != 0 })
    }

    // Set LTE Attach PDN List: profile indexes, first = the attach profile.
    public static func attachPDNListRequest(_ indexes: [UInt16]) -> [TLV] {
        var w = ByteWriter()
        w.u8(UInt8(indexes.count))
        for i in indexes { w.u16(i) }
        return [TLV(0x01, w.bytes)]
    }

    public static func profileEventRegistration(_ indexes: [UInt8]) -> [TLV] {
        [TLV(0x10, [UInt8(indexes.count)] + indexes.flatMap { [profileType3GPP, $0] })]
    }

    public static func parseProfileChanged(_ m: QMIMessage) -> (index: UInt8, event: UInt8)? {
        guard let v = m[tlv: 0x10], v.count >= 3 else { return nil }
        return (v[1], v[2])
    }
}
