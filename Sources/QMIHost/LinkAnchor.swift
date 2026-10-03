import Darwin
import Foundation

// A stand-in interface for software that ignores utun interfaces when deciding whether the Mac
// has a network. Tailscale's macOS network monitor skips every "utun*" interface, so with Wi-Fi
// off it sees no link and stays offline although the default route (our utun) works.
//
// While an internet PDN is up, qmid keeps a feth interface up with an address per family the
// PDN has: 192.0.0.8/32 (the IPv4 dummy address, RFC 7600) and a fixed ULA /128 (RFC 4193;
// counts as usable IPv6 for such checks, unlike 100::/64). Host routes only: no default route,
// DNS or network service, so nothing is routed through it; apps still use the default route
// (the utun). "linkAnchor": false in qmid.json turns it off.
public enum LinkAnchor {
    public static let name = "feth7626"
    static let ipv4 = "192.0.0.8"
    static let ipv6 = "fdd8:1c41:77ae::8"            // random global ID, fixed

    public static var exists: Bool { if_nametoindex(name) != 0 }

    // Brings the interface to exactly these families; removes it when neither is wanted.
    public static func set(v4: Bool, v6: Bool) throws {
        guard v4 || v6 else { down(); return }
        let ifconfig = "/sbin/ifconfig"
        if !exists {
            _ = try Utun.run(ifconfig, [name, "create"])
            _ = try? Utun.run(ifconfig, [name, "inet6", "-ifdisabled"])
        }
        let (has4, has6) = current()
        if v4, !has4 { _ = try Utun.run(ifconfig, [name, "inet", ipv4, "netmask", "255.255.255.255", "alias"]) }
        if !v4, has4 { _ = try? Utun.run(ifconfig, [name, "inet", ipv4, "-alias"]) }
        if v6, !has6 { _ = try Utun.run(ifconfig, [name, "inet6", ipv6, "prefixlen", "128", "alias"]) }
        if !v6, has6 { _ = try? Utun.run(ifconfig, [name, "inet6", ipv6, "-alias"]) }
        _ = try Utun.run(ifconfig, [name, "up"])
    }

    public static func down() {
        guard exists else { return }
        _ = try? Utun.run("/sbin/ifconfig", [name, "destroy"])
    }

    // Which of our two addresses the interface has now.
    static func current() -> (v4: Bool, v6: Bool) {
        guard let out = try? Utun.run("/sbin/ifconfig", [name]) else { return (false, false) }
        return (out.contains("inet \(ipv4) "), out.contains("inet6 \(ipv6) "))
    }
}
