import CryptoKit
import Foundation
import QMIDAPI
import QMIKit
import SystemConfiguration

// Publishes each connected PDN as a State:-only network service (PLAN.md §5.1). configd's
// IPMonitor then elects the primary, installs default and scoped routes, and builds global and
// scoped resolvers. Every key is a temporary value of this process's SCDynamicStore session,
// so they disappear with the process.
//
// From configd's IPMonitor (ip_plugin.c):
// - PrimaryRank is read from the service entity State:/Network/Service/<id> (combined with a
//   Setup: rank if one exists; the stronger assertion wins).
// - A service that isn't in Setup:/Network/Global/IPv4 ServiceOrder gets the maximum index, so
//   without a PrimaryRank it ranks after Wi-Fi/Ethernet: that is the prefer-wifi policy.
// - IPv4 needs Router (or DestAddresses); without one the service is demoted to Last.
// - The interface's Link entity is only consulted for the expensive flag; utun needs none.
public final class ServicePublisher {
    private let store: SCDynamicStore
    private var published: Set<String> = []

    public init(name: String = "qmi-darwin") throws {
        guard let s = SCDynamicStoreCreate(nil, name as CFString, nil, nil) else {
            throw QMIHostError.transport("SCDynamicStoreCreate: \(String(cString: SCErrorString(SCError())))")
        }
        store = s
    }

    // Stable per PDN name, so configd/NWI see the same service across reconnects.
    public static func serviceID(for pdnName: String) -> String {
        let digest = Insecure.MD5.hash(data: Data("qmi-darwin:pdn:\(pdnName)".utf8))
        var b = Array(digest)
        b[6] = (b[6] & 0x0F) | 0x30        // version 3 (name-based, MD5)
        b[8] = (b[8] & 0x3F) | 0x80        // RFC 4122 variant
        return NSUUID(uuidBytes: b).uuidString
    }

    public static func serviceKey(_ id: String, _ entity: String? = nil) -> String {
        "State:/Network/Service/\(id)" + (entity.map { "/\($0)" } ?? "")
    }

    // Builds the service's entities from WDS runtime settings.
    public static func entities(pdnName: String, interface: String, settings s: WDS.RuntimeSettings,
                                policy: QMIDPolicy) -> [String: [String: Any]] {
        let id = serviceID(for: pdnName)
        var out: [String: [String: Any]] = [:]

        var service: [String: Any] = ["UserDefinedName": "Cellular (\(pdnName))"]
        if let rank = policy.primaryRank { service["PrimaryRank"] = rank }
        out[serviceKey(id)] = service

        if let a = s.ipv4Address {
            // utun is point-to-point: the peer is the WDS gateway (or our own address).
            let peer = (s.ipv4Gateway ?? a).description
            out[serviceKey(id, "IPv4")] = [
                "Addresses": [a.description],
                "DestAddresses": [peer],
                "Router": peer,
                "InterfaceName": interface,
            ]
        }
        if let p = s.ipv6Address {
            // Router fe80::, not the WDS gateway: the gateway is a global address in our /64,
            // which has no route on a point-to-point utun, so the kernel refuses the default
            // route when IPMonitor re-adds it (after a VPN hands primary back). fe80:: always
            // resolves through the utun's fe80::/64; the next hop doesn't matter on a utun.
            out[serviceKey(id, "IPv6")] = [
                "Addresses": [p.address.description],
                "PrefixLength": [Int(p.length)],
                "Router": "fe80::",
                "InterfaceName": interface,
            ]
        }
        let dns = s.ipv4DNS.map(\.description) + s.ipv6DNS.map(\.description)
        if !dns.isEmpty {
            out[serviceKey(id, "DNS")] = ["ServerAddresses": dns, "InterfaceName": interface]
        }
        return out
    }

    // Publishes (or replaces) a set of keys. New keys are added as temporary values; keys this
    // session already owns are updated in place (SCDynamicStore.h: a temporary key stays
    // temporary unless updated by another session). Keys previously published under the same
    // service but no longer present are removed.
    public func publish(_ entries: [String: [String: Any]], replacingPrefix prefix: String? = nil) throws {
        if let prefix {
            let stale = published.filter { $0.hasPrefix(prefix) && entries[$0] == nil }
            for k in stale {
                SCDynamicStoreRemoveValue(store, k as CFString)
                published.remove(k)
            }
        }
        // Service entity last, so IPMonitor sees the addresses when it learns of the service.
        let ordered = entries.keys.sorted { a, b in
            let aIsService = a.split(separator: "/").count == 4, bIsService = b.split(separator: "/").count == 4
            return aIsService == bIsService ? a < b : !aIsService
        }
        for key in ordered {
            let value = entries[key]! as CFDictionary
            let ok: Bool
            if published.contains(key) {
                ok = SCDynamicStoreSetValue(store, key as CFString, value)
            } else {
                ok = SCDynamicStoreAddTemporaryValue(store, key as CFString, value)
                    || (SCDynamicStoreRemoveValue(store, key as CFString)
                        && SCDynamicStoreAddTemporaryValue(store, key as CFString, value))
            }
            guard ok else {
                throw QMIHostError.transport("SCDynamicStore write \(key): \(String(cString: SCErrorString(SCError())))")
            }
            published.insert(key)
        }
    }

    // Removes every key this session published under prefix (e.g. one service).
    public func remove(prefix: String) {
        for k in published where k.hasPrefix(prefix) {
            SCDynamicStoreRemoveValue(store, k as CFString)
            published.remove(k)
        }
    }

    public func removeAll() {
        for k in published { SCDynamicStoreRemoveValue(store, k as CFString) }
        published.removeAll()
    }

    // MARK: Status keys for other apps (PLAN.md §5.4)

    public static let modemKey = "State:/Network/QMI/Modem"
    public static func pdnKey(_ name: String) -> String { "State:/Network/QMI/PDN/\(name)" }

    public static func pdnStatus(name: String, interface: String, muxID: UInt8, config: PDNConfig,
                                 settings s: WDS.RuntimeSettings, policy: QMIDPolicy) -> [String: Any] {
        var d: [String: Any] = [
            "ServiceID": serviceID(for: name),
            "InterfaceName": interface,
            "MuxID": Int(muxID),
            "State": "connected",
            "Policy": policy.rawValue,
        ]
        if let p = config.profile { d["Profile"] = Int(p) }
        if let apn = s.apn ?? config.apn { d["APN"] = apn }
        if let mtu = s.mtu { d["MTU"] = Int(mtu) }
        if let a = s.ipv4Address { d["IPv4Address"] = a.description }
        if let p = s.ipv6Address { d["IPv6Address"] = p.description }
        if !s.pcscfIPv4.isEmpty { d["PCSCFv4"] = s.pcscfIPv4.map(\.description) }
        if !s.pcscfIPv6.isEmpty { d["PCSCFv6"] = s.pcscfIPv6.map(\.description) }
        return d
    }
}

extension QMIDPolicy {
    // The service's PrimaryRank for IPMonitor; none ranks it after Wi-Fi/Ethernet.
    var primaryRank: String? {
        switch self {
        case .preferWifi: return nil
        case .preferCellular: return "First"
        case .lastResort: return "Last"
        case .never: return "Never"
        }
    }
}
