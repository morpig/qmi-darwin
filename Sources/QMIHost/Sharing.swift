import Darwin
import Foundation
import SystemConfiguration

// macOS Internet Sharing over a PDN (config "sharing", plans/hotspot.md).
//
// Internet Sharing only offers configured network services (Setup:) as its source, and qmid's
// services are State:-only. So qmid adds a Setup: service with the same ID its State: entries
// use (ServicePublisher.serviceID(for:)): type Ethernet, no IPv4/IPv6/DNS settings, linked
// into the current set but not into ServiceOrder (so service ranking stays as before). System
// Settings › Network doesn't show it; Internet Sharing does, and while the PDN is up its
// configd plugin finds the PDN's interface through State:/Network/Service/<id> (InterfaceName),
// starts the access point and NATs on the utun. The DeviceName stored here is informational:
// the plugin doesn't use it, so the service is not rewritten when the utun's number changes.
//
// The service stays while qmid is stopped (so Internet Sharing keeps it selected); it goes when
// "sharing" is removed from the config, or on removeAll() (QMIDControl.prepareUninstall).
// Services qmid added carry the key `markerKey` with the PDN name.
//
// The rest reads com.apple.nat.plist (what Internet Sharing is set to) and, after an outage
// made Internet Sharing turn itself off, turns it back on (Manager.updateSharing).
public final class Sharing {
    public static let markerKey = "QMIDarwinPDN"
    static let natPrefsID = "com.apple.nat.plist"

    // What Internet Sharing is set to (com.apple.nat.plist "NAT").
    public struct NAT: Equatable {
        public var enabled = false
        public var source: String?              // PrimaryService: the source service's ID
        public var sharedTo: [String] = []      // SharingDevices: "en0", …
        public var subnet = "192.168.2.0"       // SharingNetworkNumberStart
        public var mask = "255.255.255.0"       // SharingNetworkMask

        init() {}

        init(_ d: [String: Any]?) {
            guard let d else { return }
            enabled = (d["Enabled"] as? NSNumber)?.boolValue ?? false
            source = d["PrimaryService"] as? String
            sharedTo = d["SharingDevices"] as? [String] ?? []
            if let s = d["SharingNetworkNumberStart"] as? String { subnet = s }
            if let m = d["SharingNetworkMask"] as? String { mask = m }
        }
    }

    private let nat: SCPreferences
    private let onNATChange: () -> Void

    // onNATChange runs on queue whenever com.apple.nat.plist is committed or applied.
    public init(queue: DispatchQueue, onNATChange: @escaping () -> Void) throws {
        guard let p = SCPreferencesCreate(nil, "qmid-sharing" as CFString, Self.natPrefsID as CFString) else {
            throw QMIHostError.systemConfiguration("SCPreferencesCreate \(Self.natPrefsID)")
        }
        nat = p
        self.onNATChange = onNATChange
        var ctx = SCPreferencesContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        SCPreferencesSetCallback(p, { _, _, info in
            guard let info else { return }
            Unmanaged<Sharing>.fromOpaque(info).takeUnretainedValue().onNATChange()
        }, &ctx)
        SCPreferencesSetDispatchQueue(p, queue)
    }

    deinit { SCPreferencesSetDispatchQueue(nat, nil) }

    public func readNAT() -> NAT {
        SCPreferencesSynchronize(nat)
        return NAT(SCPreferencesGetValue(nat, "NAT" as CFString) as? [String: Any])
    }

    // Turns Internet Sharing back on with its current settings (as the Sharing settings'
    // switch does); its configd plugin follows the file.
    public func enableNAT() throws {
        guard SCPreferencesLock(nat, true) else { throw QMIHostError.systemConfiguration("lock \(Self.natPrefsID)") }
        defer { SCPreferencesUnlock(nat) }
        SCPreferencesSynchronize(nat)
        guard var d = SCPreferencesGetValue(nat, "NAT" as CFString) as? [String: Any] else {
            throw QMIHostError.failed("\(Self.natPrefsID) has no NAT settings")
        }
        d["Enabled"] = 1
        guard SCPreferencesSetValue(nat, "NAT" as CFString, d as CFDictionary),
              SCPreferencesCommitChanges(nat), SCPreferencesApplyChanges(nat) else {
            throw QMIHostError.systemConfiguration("write \(Self.natPrefsID)")
        }
    }

    // MARK: Setup: service

    // The service dictionary qmid writes under /NetworkServices/<id>.
    static func serviceEntity(pdn: String, device: String) -> [String: Any] {
        let name = "Cellular (\(pdn))"
        return [
            "UserDefinedName": name,
            "Interface": ["DeviceName": device, "Hardware": "Ethernet", "Type": "Ethernet", "UserDefinedName": name],
            markerKey: pdn,
        ]
    }

    // The entity needs no rewrite: same name and type, ours. DeviceName may differ.
    static func isCurrent(_ existing: [String: Any]?, pdn: String) -> Bool {
        guard let e = existing, e[markerKey] as? String == pdn,
              e["UserDefinedName"] as? String == "Cellular (\(pdn))",
              let i = e["Interface"] as? [String: Any], i["Type"] as? String == "Ethernet",
              e["IPv4"] == nil, e["IPv6"] == nil else { return false }
        return true
    }

    // Makes sure the service for `pdn` exists and is linked into the current set; removes
    // services qmid added for other PDNs. Returns what it changed, for the log (nil: nothing).
    @discardableResult
    public static func ensureService(id: String, pdn: String, device: String) throws -> String? {
        try withPrefs { p in
            var changes: [String] = removeOthers(p, keep: id)
            let path = "/NetworkServices/\(id)"
            // The ID is derived from qmid's name for the PDN, so a service under it is qmid's
            // even without the marker (one added by hand while testing): it is rewritten.
            let existing = SCPreferencesPathGetValue(p, path as CFString) as? [String: Any]
            if !isCurrent(existing, pdn: pdn) {
                guard SCPreferencesPathSetValue(p, path as CFString, serviceEntity(pdn: pdn, device: device) as CFDictionary) else {
                    throw QMIHostError.systemConfiguration("write \(path)")
                }
                changes.append(existing == nil ? "added" : "repaired")
            }
            guard let set = SCPreferencesGetValue(p, "CurrentSet" as CFString) as? String else {
                throw QMIHostError.failed("no current network set")
            }
            let link = "\(set)/Network/Service/\(id)"
            if SCPreferencesPathGetLink(p, link as CFString) as String? != path {
                guard SCPreferencesPathSetLink(p, link as CFString, path as CFString) else { throw QMIHostError.systemConfiguration("link \(link)") }
                changes.append("linked into \(set)")
            }
            return changes.isEmpty ? nil : changes.joined(separator: ", ")
        }
    }

    // Removes every service qmid added. Returns the number removed.
    @discardableResult
    public static func removeAll() throws -> Int {
        try withPrefs { p in removeOthers(p, keep: nil).count }
    }

    // Services carrying markerKey other than `keep`: unlinked from every set, then removed.
    private static func removeOthers(_ p: SCPreferences, keep: String?) -> [String] {
        let services = SCPreferencesGetValue(p, "NetworkServices" as CFString) as? [String: Any] ?? [:]
        let ours = services.compactMap { id, v -> String? in
            (v as? [String: Any])?[markerKey] != nil && id != keep ? id : nil
        }
        guard !ours.isEmpty else { return [] }
        let sets = (SCPreferencesGetValue(p, "Sets" as CFString) as? [String: Any] ?? [:]).keys
        for id in ours {
            for s in sets {
                let link = "/Sets/\(s)/Network/Service/\(id)"
                if SCPreferencesPathGetValue(p, link as CFString) != nil { SCPreferencesPathRemoveValue(p, link as CFString) }
            }
            SCPreferencesPathRemoveValue(p, "/NetworkServices/\(id)" as CFString)
        }
        return ours.map { "removed \($0)" }
    }

    // Runs body with the network preferences locked; commits and applies if it changed anything.
    private static func withPrefs<T>(_ body: (SCPreferences) throws -> T) throws -> T {
        guard let p = SCPreferencesCreate(nil, "qmid" as CFString, nil) else { throw QMIHostError.systemConfiguration("open network preferences") }
        guard SCPreferencesLock(p, true) else { throw QMIHostError.systemConfiguration("lock network preferences") }
        defer { SCPreferencesUnlock(p) }
        let result = try body(p)
        if hasChanges(p) {
            guard SCPreferencesCommitChanges(p), SCPreferencesApplyChanges(p) else { throw QMIHostError.systemConfiguration("save network preferences") }
        }
        return result
    }

    // SCPreferences has no public "dirty" query: compare with a fresh read of the file.
    private static func hasChanges(_ p: SCPreferences) -> Bool {
        guard let fresh = SCPreferencesCreate(nil, "qmid-check" as CFString, nil) else { return true }
        for key in ["NetworkServices", "Sets"] {
            let a = SCPreferencesGetValue(p, key as CFString) as? NSDictionary
            let b = SCPreferencesGetValue(fresh, key as CFString) as? NSDictionary
            if a != b { return true }
        }
        return false
    }

    // MARK: The shared network

    // The interface Internet Sharing serves its clients on: a bridge with an IPv4 address in
    // the sharing subnet (bridge100 by default). nil while it isn't running.
    public static func bridge(for n: NAT) -> String? {
        guard let net = inet(n.subnet), let mask = inet(n.mask) else { return nil }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("bridge") else { continue }
            let a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            if a & mask == net & mask { return name }
        }
        return nil
    }

    // Devices on the shared network: unicast IPv4 neighbours (ARP entries that expire) on it.
    public static func clients(on interface: String) -> Int {
        let index = if_nametoindex(interface)
        guard index != 0 else { return 0 }
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return 0 }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return 0 }
        var macs = Set<[UInt8]>()
        buf.withUnsafeBytes { raw in
            var off = 0
            while off + MemoryLayout<rt_msghdr>.size <= len {
                let rtm = raw.loadUnaligned(fromByteOffset: off, as: rt_msghdr.self)
                defer { off += Int(rtm.rtm_msglen) }
                guard rtm.rtm_msglen > 0 else { off = len; return }
                guard rtm.rtm_index == UInt16(index), rtm.rtm_rmx.rmx_expire != 0 else { continue }
                // rt_msghdr, then sockaddr_in (destination), then sockaddr_dl (gateway).
                let end = off + Int(rtm.rtm_msglen)
                var sa = off + MemoryLayout<rt_msghdr>.size
                guard sa < end, end <= len else { continue }
                let dstLen = Int(raw[sa])
                sa += dstLen > 0 ? (dstLen + 3) & ~3 : 4
                guard sa + 8 <= end else { continue }
                let nlen = Int(raw[sa + 5]), alen = Int(raw[sa + 6])     // sdl_nlen, sdl_alen
                let mac = sa + 8 + nlen
                guard alen == 6, mac + 6 <= end, raw[mac] & 1 == 0 else { continue }
                macs.insert(Array(raw[mac..<(mac + 6)]))
            }
        }
        return macs.count
    }

    static func inet(_ s: String) -> UInt32? {
        var a = in_addr()
        return inet_pton(AF_INET, s, &a) == 1 ? a.s_addr : nil
    }
}
