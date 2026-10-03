import Foundation
import QMIDAPI
import QMIKit

// qmid configuration (PLAN.md §8.1), /Library/Application Support/qmi-darwin/qmid.json:
//
// {
//   "pdns": [
//     { "name": "internet", "role": "internet", "apn": "internet", "family": "ipv4v6",
//       "policy": "prefer-wifi", "autoconnect": true },
//     { "name": "ims", "role": "ims", "apn": "ims", "family": "ipv6",
//       "policy": "never", "autoconnect": true }
//   ]
// }
//
// The config is the source of truth for the modem's profiles (APN sync): qmid finds the
// profile for each PDN (by "profile" index if given, else by APN, ignoring case), creates it
// if missing, and rewrites it if it differs. PDNs are always started by profile index, so they
// are visible to AT (+CGDCONT/+CGACT).
//
// role      internet | ims | other (default: internet for a PDN named internet, ims for ims)
//           ims → profile gets pcscf-pco + imcn + APN type ims (needed for P-CSCF);
//           internet → APN type default, and it is the LTE attach APN unless "attach": false.
// attach    the LTE attach profile (the default bearer) is kept on this PDN's APN, so the
//           PDN reuses the attach bearer instead of opening a second one. Changing it makes
//           the modem re-attach (brief loss of all PDNs). If the modem's attach profile is
//           pinned by another PDN, the attach PDN gets its own profile and the modem's LTE
//           attach list is pointed at it.
// username / password / auth (none | pap | chap | pap-chap): written to the profile.
// apnType   APN type names for the profile (default, ims, mms, dun, supl, ia, emergency, ut);
//           replaces the role's (ims → ims, internet → default; other roles leave it as it is).
// redial    false: one-shot. Dialled only by connect; a failed dial or a drop qmid wasn't asked
//           for leaves it idle and not wanted (no backoff, no blocked state), and connect while
//           not attached fails at once. Implies autoconnect false. Default true.
// maxUptime seconds a one-shot PDN stays up; qmid then hangs up. connect on the connected
//           PDN starts the time again.
// Mux IDs are assigned in order: 0x81, 0x82, ...
//
// Modem (top level, both optional): "vendorIDs": ["1234"] adds USB vendor IDs to the known
// modem makers (QMIDevice.knownVendorIDs); "interface": 4 picks the QMI interface by number
// when its descriptor doesn't identify it (QDModem.m, isQMIInterface).
//
// carriers (optional): per-SIM settings for the attach PDN (the default internet bearer) only;
// every other PDN (IMS included) stays as configured on every SIM.
//
//   "carriers": [
//     { "name": "Example", "mccmnc": ["00101"], "apn": "internet" },
//     { "name": "Travel eSIM", "iccid": ["8900"], "apn": "travel" },
//     { "name": "Corp", "mccmnc": ["99999"], "apn": "corp", "username": "u", "password": "p", "auth": "chap" }
//   ]
//
// qmid reads the SIM's home MCC/MNC and ICCID; the most specific matching entry wins (an ICCID
// prefix beats an MCC/MNC, a longer prefix a shorter one, then the first in the file). Its apn,
// username, password and auth replace the attach PDN's; what it leaves out is cleared (no
// credentials, empty APN). With no match the attach PDN's own settings apply, and without an
// "apn" that is an empty APN: the network picks the default bearer. With "carriers" absent,
// nothing changes per SIM. Until the SIM is known the attach profile is left as it is.
public struct QMIDConfig: Codable, Equatable {
    public struct PDN: Codable, Equatable {
        public var name: String
        public var profile: Int?
        public var apn: String?
        public var family: String?          // ipv4, ipv6, ipv4v6 (default)
        public var policy: String?          // ServicePublisher.Policy raw value
        public var autoconnect: Bool?
        public var role: String?
        public var attach: Bool?
        public var username: String?
        public var password: String?
        public var auth: String?
        public var apnType: [String]? = nil
        public var redial: Bool? = nil
        public var maxUptime: Int? = nil

        public var oneShot: Bool { redial == false }
        public var autoconnects: Bool { autoconnect ?? !oneShot }
        public var apnTypeMask: WDS.APNTypeMask? { apnType.flatMap(WDS.APNTypeMask.init(names:)) }

        public var effectiveRole: String { role ?? (name == "internet" || name == "ims" ? name : "other") }
        public var isAttach: Bool { attach ?? (effectiveRole == "internet") }

        public var families: [UInt8] {
            switch family ?? "ipv4v6" {
            case "ipv4": return [4]
            case "ipv6": return [6]
            default: return [4, 6]
            }
        }
    }

    public var interface: Int?              // QMI USB interface number; default: found by its descriptor
    // USB vendor IDs (4 hex digits, "2c7c") to look for besides the known modem makers, tried
    // first (QMIDevice.knownVendorIDs).
    public var vendorIDs: [String]? = nil
    // Batched utun I/O (private sendmsg_x/recvmsg_x), default on. false forces one system
    // call per packet, e.g. if a macOS update breaks batching in a way qmid can't detect.
    public var utunBatch: Bool? = nil
    // Stand-in feth interface while internet is up, for apps that ignore utun interfaces
    // (LinkAnchor.swift). Default on.
    public var linkAnchor: Bool? = nil
    public var pdns: [PDN]
    public var carriers: [Carrier]? = nil

    public struct Carrier: Codable, Equatable {
        public var name: String
        public var mccmnc: [String]?        // home PLMN, "00101" / "001001"
        public var iccid: [String]?         // ICCID prefixes
        public var apn: String?             // absent or "": the network's default
        public var username: String?
        public var password: String?
        public var auth: String?
    }

    // Which carrier entry the SIM matches, and by what (for status: "iccid 8900", "mccmnc 00101").
    public func carrier(for sim: SIMIdentity) -> (carrier: Carrier, matchedBy: String)? {
        var best: (carrier: Carrier, matchedBy: String, score: Int)?
        for c in carriers ?? [] {
            var hit: (String, Int)?
            if let id = sim.iccid, let p = (c.iccid ?? []).filter({ id.hasPrefix($0) }).max(by: { $0.count < $1.count }) {
                hit = ("iccid \(p)", 100 + p.count)
            } else if let m = sim.mccmnc, (c.mccmnc ?? []).contains(m) {
                hit = ("mccmnc \(m)", 1)
            }
            if let (how, score) = hit, score > (best?.score ?? 0) { best = (c, how, score) }
        }
        return best.map { ($0.carrier, $0.matchedBy) }
    }

    // Enough is known of the SIM to choose its attach settings: a carrier matched, or the home
    // MCC/MNC was read and matched nothing. An ICCID alone that matches nothing is not enough,
    // since an "mccmnc" entry may still match once Get Home Network answers (it fails while the
    // modem registers).
    public func identifies(_ sim: SIMIdentity?) -> Bool {
        guard let sim else { return false }
        return sim.mccmnc != nil || carrier(for: sim) != nil
    }

    // The PDNs as they apply to this SIM: the attach PDN takes the matching carrier's settings
    // (see "carriers" above); a SIM not (fully) identified leaves the attach profile untouched.
    public func resolvedPDNs(for sim: SIMIdentity?) -> [PDN] {
        guard carriers != nil else { return pdns }
        return pdns.map { p in
            guard p.isAttach else { return p }
            var q = p
            guard let sim, identifies(sim) else {
                q.apn = nil; q.username = nil; q.password = nil; q.auth = nil
                return q
            }
            if let c = carrier(for: sim)?.carrier {
                q.apn = c.apn; q.username = c.username; q.password = c.password; q.auth = c.auth
            }
            q.apn = q.apn ?? ""
            q.username = q.username ?? ""
            q.password = q.password ?? ""
            q.auth = q.auth ?? (q.username!.isEmpty ? "none" : "pap-chap")
            return q
        }
    }

    public static let defaultPath = "/Library/Application Support/qmi-darwin/qmid.json"

    public static let builtIn = QMIDConfig(interface: nil, pdns: [
        PDN(name: "internet", profile: 1, apn: nil, family: "ipv4v6", policy: "prefer-wifi", autoconnect: true,
            role: nil, attach: nil, username: nil, password: nil, auth: nil),
        PDN(name: "ims", profile: 2, apn: nil, family: "ipv6", policy: "never", autoconnect: true,
            role: nil, attach: nil, username: nil, password: nil, auth: nil),
    ])

    public static func decode(_ data: Data) throws -> QMIDConfig {
        let c: QMIDConfig
        do { c = try JSONDecoder().decode(QMIDConfig.self, from: data) } catch {
            throw QMIHostError.transport("config: \(error)")
        }
        try c.validate()
        return c
    }

    public func encoded() -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(self)) ?? Data()
    }

    public static func load(path: String = defaultPath) throws -> QMIDConfig {
        guard FileManager.default.fileExists(atPath: path) else { return builtIn }
        let c = try JSONDecoder().decode(QMIDConfig.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try c.validate()
        return c
    }

    // vendorIDs as numbers; nil entries are rejected by validate().
    public var usbVendorIDs: [UInt16] {
        (vendorIDs ?? []).compactMap { $0.count == 4 ? UInt16($0, radix: 16) : nil }
    }

    public func validate() throws {
        for v in vendorIDs ?? [] where v.count != 4 || UInt16(v, radix: 16) == nil {
            throw QMIHostError.transport("config: vendorID \(v) is not 4 hex digits")
        }
        var names = Set<String>()
        for p in pdns {
            guard !p.name.isEmpty, names.insert(p.name).inserted else { throw QMIHostError.transport("config: duplicate or empty PDN name \(p.name)") }
            guard p.profile != nil || p.apn != nil else { throw QMIHostError.transport("config: \(p.name) needs profile or apn") }
            if let pr = p.profile, !(1...255).contains(pr) { throw QMIHostError.transport("config: \(p.name) profile out of range") }
            if let pol = p.policy, ServicePublisher.Policy(rawValue: pol) == nil { throw QMIHostError.transport("config: \(p.name) bad policy \(pol)") }
            if let a = p.auth, WDS.Authentication(name: a) == nil { throw QMIHostError.transport("config: \(p.name) bad auth \(a)") }
            if let t = p.apnType, WDS.APNTypeMask(names: t) == nil {
                throw QMIHostError.transport("config: \(p.name) bad apnType \(t.joined(separator: ", "))")
            }
            if p.oneShot, p.autoconnect == true {
                throw QMIHostError.transport("config: \(p.name) can't autoconnect with redial false")
            }
            if let m = p.maxUptime {
                guard m > 0 else { throw QMIHostError.transport("config: \(p.name) maxUptime must be positive") }
                guard p.oneShot else { throw QMIHostError.transport("config: \(p.name) maxUptime needs redial false") }
            }
        }
        let pinned = pdns.compactMap(\.profile)
        guard Set(pinned).count == pinned.count else { throw QMIHostError.transport("config: two PDNs pin the same profile") }
        guard pdns.filter(\.isAttach).count <= 1 else { throw QMIHostError.transport("config: only one PDN can be the attach PDN") }
        guard pdns.count <= 8 else { throw QMIHostError.transport("config: at most 8 PDNs") }
        if let carriers {
            guard pdns.contains(where: \.isAttach) else { throw QMIHostError.transport("config: carriers need an attach PDN") }
            for c in carriers {
                func bad(_ why: String) -> Error { QMIHostError.transport("config: carrier \(c.name.isEmpty ? "(no name)" : c.name): \(why)") }
                guard !c.name.isEmpty else { throw bad("needs a name") }
                guard !(c.mccmnc ?? []).isEmpty || !(c.iccid ?? []).isEmpty else { throw bad("needs mccmnc or iccid") }
                for m in c.mccmnc ?? [] where !(5...6).contains(m.count) || !m.allSatisfy(\.isASCII) || !m.allSatisfy(\.isNumber) {
                    throw bad("mccmnc \(m) is not 5 or 6 digits")
                }
                for i in c.iccid ?? [] where !(1...22).contains(i.count) || !i.allSatisfy(\.isASCII) || !i.allSatisfy(\.isNumber) {
                    throw bad("iccid prefix \(i) is not 1–22 digits")
                }
                if let a = c.auth, WDS.Authentication(name: a) == nil { throw bad("bad auth \(a)") }
            }
        }
    }
}

// The SIM as qmid identifies it: home MCC/MNC (NAS Get Home Network) and ICCID.
public struct SIMIdentity: Equatable {
    public var mccmnc: String?
    public var iccid: String?

    public init(mccmnc: String? = nil, iccid: String? = nil) {
        self.mccmnc = mccmnc
        self.iccid = iccid
    }

    // A fresh read over the last known identity. Same card (or ICCID unreadable): a field that
    // couldn't be read keeps its last value, since Get Home Network fails while the modem
    // re-registers. A different ICCID is a different SIM and takes the read as is.
    public func merged(over last: SIMIdentity?) -> SIMIdentity {
        guard let last, iccid == nil || iccid == last.iccid else { return self }
        return SIMIdentity(mccmnc: mccmnc ?? last.mccmnc, iccid: iccid ?? last.iccid)
    }

    // Last 4 digits: enough to tell SIMs apart in status and logs.
    public var iccidSuffix: String? { iccid.map { "…" + String($0.suffix(4)) } }

    public var description: String {
        [mccmnc.map { $0.count == 6 ? "\($0.prefix(3))-\($0.suffix(3))" : "\($0.prefix(3))-\($0.suffix(2))" }, iccidSuffix]
            .compactMap { $0 }.joined(separator: " ")
    }
}

// The XPC API (QMIDControl, QMIDEvents, keys) lives in the QMIDAPI target.
