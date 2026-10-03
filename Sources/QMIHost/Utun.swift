import Foundation
import QMIDatapath
import QMIKit

// One utun per PDN. Addresses are set with ifconfig for now (M3/M4 "set by hand");
// NetConfig moves to ioctls (PLAN.md §5.6) in M5.
public final class Utun {
    public let name: String
    // -1 once closed: the number may already belong to another descriptor by then.
    public private(set) var fd: Int32
    public private(set) var maxPendingResult: Int32 = 0
    private var routes: [[String]] = []
    private var ipv6: IPv6Prefix?          // the WDS address configured, replaced when WDS reports another

    public init() throws {
        var buf = [CChar](repeating: 0, count: 16)
        let fd = qd_utun_open(&buf)
        guard fd >= 0 else {
            let e = errno
            throw QMIHostError.open("utun: \(String(cString: strerror(e)))\(e == EPERM ? " (needs root)" : "")")
        }
        self.fd = fd
        self.name = String(cString: buf)
        maxPendingResult = qd_utun_set_max_pending(fd, 512)
    }

    deinit { close() }

    // Idempotent. Detach the mux from QDModem first: its read source must be gone before the fd is.
    public func close() {
        guard fd >= 0 else { return }
        for r in routes.reversed() {
            var del = r
            del[1] = "delete"
            _ = try? Self.run("/sbin/route", del)
        }
        routes.removeAll()
        let old = fd
        fd = -1
        Darwin.close(old)
    }

    public func configure(_ s: WDS.RuntimeSettings) throws {
        if let a = s.ipv4Address {
            // Point-to-point: the peer is the WDS gateway, or our own address if none.
            let peer = s.ipv4Gateway ?? a
            try Self.run("/sbin/ifconfig", [name, "inet", "\(a)", "\(peer)", "netmask", "255.255.255.255", "up"])
        }
        for args in Self.ipv6Commands(name, old: ipv6, new: s.ipv6Address) {
            try Self.run("/sbin/ifconfig", args)
        }
        ipv6 = s.ipv6Address
        if let mtu = s.mtu, mtu >= 1280, mtu <= 2000 {
            try Self.run("/sbin/ifconfig", [name, "mtu", "\(mtu)"])
        }
    }

    // An IPv6 address is added as an alias: a new one replaces the previous WDS address (and
    // its prefix route) rather than joining it, and one WDS no longer reports is removed, so the
    // utun matches the published service; the link-local address is left alone.
    static func ipv6Commands(_ name: String, old: IPv6Prefix?, new: IPv6Prefix?) -> [[String]] {
        guard new != old else { return [] }
        var cmds: [[String]] = []
        if let old { cmds.append([name, "inet6", "\(old.address)", "delete"]) }
        if let new { cmds.append([name, "inet6", "\(new.address)", "prefixlen", "\(new.length)", "alias"]) }
        return cmds
    }

    // Host route through this utun, removed on close.
    public func addHostRoute(_ host: String) throws {
        let inet6 = host.contains(":")
        let args = ["-n", "add", inet6 ? "-inet6" : "-inet", "-host", host, "-interface", name]
        try Self.run("/sbin/route", args)
        routes.append(args)
    }

    // Scoped default routes, so sockets bound with IP_BOUND_IF (curl --interface) use this utun.
    public func addScopedDefault(inet6: Bool) throws {
        let args = ["-n", "add", inet6 ? "-inet6" : "-inet", "-ifscope", name, "default", "-interface", name]
        try Self.run("/sbin/route", args)
        routes.append(args)
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw QMIHostError.transport("\(path) \(args.joined(separator: " ")): \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return out
    }
}
