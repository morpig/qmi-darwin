import Foundation
import QMIDAPI
import QMIDatapath
import QMIHost
import QMIKit

// qmictl: M1–M4 tool. probe and status need no root; connect does (utun, ifconfig, route).

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
usage (through qmid):
  qmictl status
  qmictl connect NAME | disconnect NAME
  qmictl policy NAME prefer-wifi|prefer-cellular|last-resort|never
  qmictl reload
  qmictl restart                            qmid exits cleanly; launchd starts it again
  qmictl events                             stream qmid's events (Ctrl-C to stop)
  qmictl log [--level L] [--no-history]     qmid's log: recent lines, then live (L: debug = QMI trace)
  qmictl config get | config set FILE       read / replace qmid.json (validated, applied)
  qmictl sync                               APN sync report: PDN ↔ modem profile, autoconnect, attach

usage (direct to the modem; stop qmid first):
  qmictl probe        [--iface N] [--vendor HEX]... [-v]
  qmictl modem-status [--iface N] [-v]
  qmictl profiles     [--iface N] [-v]     modem profiles, autoconnect, LTE attach PDN list
  qmictl plmn-name    [--iface N] [-v]     operator long/short name: network (NITZ) and modem's own
  qmictl profile-write INDEX|new KEY=VALUE...   create/modify a profile; keys: apn, pdp
                      (ipv4|ipv6|ipv4v6), user, pass, auth (none|pap|chap|pap-chap),
                      pcscf-pco, pcscf-dhcp, imcn, disabled (0|1), type (default,ims,...)
  qmictl run --pdn NAME:PROFILE:MUX[:FAMILIES[:POLICY]] [--pdn ...] [--iface N]
             [--publish] [--route HOST]... [--scoped] [--stats SECONDS] [--dry-run] [-v]
             [--no-batch] [--fc-test SECONDS] [--stall-test SECONDS] [--flow-control]

  PROFILE   3GPP profile index (AT+CGDCONT cid), or apn=NAME
  MUX       QMAP mux id, e.g. 0x81
  FAMILIES  4, 6 or 46 (default 46)
  POLICY    prefer-wifi | prefer-cellular | last-resort | never
            (default: never for a PDN named ims, prefer-wifi otherwise)
  --iface   QMI USB interface number (default: found by its descriptor)
  --vendor  extra USB vendor ID to look for, e.g. 1234 (known modem makers are built in)
  --publish publish each PDN as a network service in SCDynamicStore
  --route   host route via the first PDN's utun (removed on exit)
  --scoped  scoped default routes via each utun (for IP_BOUND_IF / curl --interface)
  --dry-run QMI bring-up only (data format, bind, start, runtime settings), no utun, no root
  --no-batch  one utun system call per packet (qmid's "utunBatch": false), for comparisons
  --fc-test   toggle a simulated QMAP flow-disable/enable on every PDN each SECONDS; uplink
              must stop while disabled (watch with --stats)
  --stall-test  clear a stall on the bulk IN pipe each SECONDS (aborts every posted read);
              in_posted_now must return to 32 (watch with --stats)
  --flow-control  ask the modem for QMAP flow control in Set Data Format (experimental)
"""

struct Options {
    var command = ""
    var iface: Int?
    var vendors: [UInt16] = []
    var verbose = false
    var pdns: [PDNConfig] = []
    var routes: [String] = []
    var scoped = false
    var statsInterval: Double = 0
    var dryRun = false
    var publish = false
    var noBatch = false
    var fcTest: Double = 0
    var stallTest: Double = 0
    var flowControl = false
    var policies: [String: ServicePublisher.Policy] = [:]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("qmictl: \(message)\n".utf8))
    exit(1)
}

func parsePDN(_ spec: String) -> PDNConfig {
    let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 3 else { fail("bad --pdn \(spec)") }
    var profile: UInt8?
    var apn: String?
    if parts[1].hasPrefix("apn=") { apn = String(parts[1].dropFirst(4)) }
    else if let p = UInt8(parts[1]) { profile = p }
    else { fail("bad profile in \(spec)") }
    let muxText = parts[2].lowercased()
    guard let mux = muxText.hasPrefix("0x") ? UInt8(muxText.dropFirst(2), radix: 16) : UInt8(muxText) else {
        fail("bad mux in \(spec)")
    }
    let fam = parts.count > 3 ? parts[3] : "46"
    let families: [UInt8] = fam == "4" ? [4] : fam == "6" ? [6] : [4, 6]
    return PDNConfig(name: parts[0], profile: profile, apn: apn, muxID: mux, families: families)
}

func parseOptions() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    guard !args.isEmpty else { print(usage); exit(2) }
    o.command = args.removeFirst()
    while !args.isEmpty {
        let a = args.removeFirst()
        func value() -> String {
            guard !args.isEmpty else { fail("\(a) needs a value") }
            return args.removeFirst()
        }
        switch a {
        case "--iface": o.iface = Int(value())
        case "--vendor":
            let v = value()
            guard v.count == 4, let id = UInt16(v, radix: 16) else { fail("bad vendor ID \(v) (4 hex digits)") }
            o.vendors.append(id)
        case "-v", "--verbose": o.verbose = true
        case "--pdn":
            let spec = value()
            let pdn = parsePDN(spec)
            o.pdns.append(pdn)
            let parts = spec.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count > 4 {
                guard let p = ServicePublisher.Policy(rawValue: String(parts[4])) else { fail("bad policy in \(spec)") }
                o.policies[pdn.name] = p
            } else {
                o.policies[pdn.name] = pdn.name == "ims" ? .never : .preferWifi
            }
        case "--route": o.routes.append(value())
        case "--scoped": o.scoped = true
        case "--dry-run": o.dryRun = true
        case "--publish": o.publish = true
        case "--stats": o.statsInterval = Double(value()) ?? 0
        case "--no-batch": o.noBatch = true
        case "--fc-test": o.fcTest = Double(value()) ?? 0
        case "--stall-test": o.stallTest = Double(value()) ?? 0
        case "--flow-control": o.flowControl = true
        case "-h", "--help": print(usage); exit(0)
        default: fail("unknown option \(a)\n\(usage)")
        }
    }
    return o
}

func openDevice(_ o: Options) -> QMIDevice {
    let dev: QMIDevice
    do { dev = try QMIDevice.open(interface: o.iface, vendorIDs: QMIDevice.vendorIDs(extra: o.vendors)) } catch { fail("\(error)") }
    if o.verbose { dev.trace = { print("  \($0)") } }
    let m = dev.modem
    print(String(format: "modem %04x:%04x, QMI interface %d, bulk in 0x%02x/%d out 0x%02x/%d, interrupt 0x%02x",
                 m.vendorID, m.productID, m.interfaceNumber, m.bulkInAddress, m.bulkInMaxPacketSize,
                 m.bulkOutAddress, m.bulkOutMaxPacketSize, m.interruptAddress))
    do { try dev.sync() } catch { fail("CTL sync: \(error)") }
    return dev
}

// MARK: - probe (M1)

func probe(_ o: Options) {
    let dev = openDevice(o)
    defer { dev.close() }
    do {
        let versions = try dev.versions()
        print("services (\(versions.count)):")
        for v in versions.sorted(by: { $0.service.rawValue < $1.service.rawValue }) {
            print("  \(v.service.name.padding(toLength: 6, withPad: " ", startingAt: 0)) \(v.major).\(v.minor)")
        }
        let wds = try dev.allocateClient(.wds)
        print("WDS client \(wds.id) allocated")
        wds.release()
        print("WDS client \(wds.id) released")
    } catch {
        fail("\(error)")
    }
}

// MARK: - status (M2)

func status(_ o: Options) {
    let dev = openDevice(o)
    defer { dev.close() }
    func section<T>(_ name: String, _ body: () throws -> T) -> T? {
        do { return try body() } catch { print("\(name): \(error)"); return nil }
    }
    if let dms = section("dms", { try dev.allocateClient(.dms) }) {
        if let r = section("revision", { try dms.request(DMS.getRevision) }) { print("firmware: \(DMS.parseRevision(r) ?? "?")") }
        if let r = section("ids", { try dms.request(DMS.getIDs) }) { print("imei:     \(DMS.parseIMEI(r) ?? "?")") }
        dms.release()
    }
    if let uim = section("uim", { try dev.allocateClient(.uim) }) {
        if let r = section("card status", { try uim.request(UIM.getCardStatus) }),
           let cards = section("card status", { try UIM.parseCardStatus(r) }) {
            for (i, c) in cards.enumerated() {
                let apps = c.applications.map { "type \($0.type) state \($0.state)" }.joined(separator: ", ")
                print("sim \(i):    \(c.stateName), \(c.isReady ? "ready" : "not ready") [\(apps)]")
            }
        }
        uim.release()
    }
    if let nas = section("nas", { try dev.allocateClient(.nas) }) {
        if let r = section("serving system", { try nas.request(NAS.getServingSystem) }),
           let s = section("serving system", { try NAS.parseServingSystem(r) }) {
            let rats = s.radioInterfaces.map(NAS.ServingSystem.radioName).joined(separator: "+")
            let plmn = s.mcc.map { "\($0)-\(String(format: "%02d", s.mnc ?? 0))" } ?? "?"
            print("network:  \(s.registrationName), ps \(s.psAttached ? "attached" : "detached"), rat \(rats.isEmpty ? "none" : rats), plmn \(plmn) \(s.operatorName ?? "")")
        }
        nas.release()
    }
}

// MARK: - plmn-name

func plmnName(_ o: Options) {
    let dev = openDevice(o)
    defer { dev.close() }
    do {
        let nas = try dev.allocateClient(.nas)
        defer { nas.release() }
        let s = try NAS.parseServingSystem(try nas.request(NAS.getServingSystem))
        guard let mcc = s.mcc, let mnc = s.mnc else { fail("no current PLMN (\(s.registrationName))") }
        print("serving:  \(s.registrationName), plmn \(mcc)-\(mnc), description \"\(s.operatorName ?? "")\"")
        let d = try nas.request(NAS.getOperatorNameData)
        let r = try nas.request(NAS.getPLMNName, NAS.plmnNameRequest(mcc: mcc, mnc: mnc))
        if o.verbose {
            for t in d.tlvs where t.type != 0x02 { print(String(format: "  0x0039 0x%02x: ", t.type) + t.value.hex) }
            for t in r.tlvs where t.type != 0x02 { print(String(format: "  0x0044 0x%02x: ", t.type) + t.value.hex) }
        }
        let nitz = NAS.parseNITZName(d), table = try NAS.parsePLMNName(r)
        print("network:  long \"\(nitz?.longName ?? "-")\", short \"\(nitz?.shortName ?? "-")\" (NITZ)")
        print("modem:    long \"\(table.longName ?? "-")\", short \"\(table.shortName ?? "-")\" (Get PLMN Name)")
    } catch {
        fail("\(error)")
    }
}

// MARK: - profiles

func profiles(_ o: Options) {
    let dev = openDevice(o)
    defer { dev.close() }
    do {
        let wds = try dev.allocateClient(.wds)
        defer { wds.release() }
        let list = try WDS.parseProfileList(try wds.request(WDS.getProfileList, WDS.profileListRequest()))
        print("3GPP profiles (\(list.count)):")
        for entry in list {
            let r = try wds.request(WDS.getProfileSettings, [WDS.profileIdentifier(entry.index)])
            print("  " + WDS.parseProfile(r, index: entry.index).summary)
            if o.verbose {
                for t in r.tlvs where t.type != 0x02 { print(String(format: "      0x%02x: ", t.type) + t.value.hex) }
            }
        }
        if let r = try? wds.request(WDS.getAutoconnectSettings) {
            print("autoconnect: \(WDS.parseAutoconnect(r).map { "\($0)" } ?? "?")\(r[tlv: 0x10].map { ", roaming \($0.first ?? 0)" } ?? "")")
        } else {
            print("autoconnect: not supported")
        }
        if let r = try? wds.request(WDS.getLTEAttachPDNList) {
            let l = WDS.parseAttachPDNList(r)
            print("lte attach pdn list: current \(l.current) pending \(l.pending)")
        } else {
            print("lte attach pdn list: not supported")
        }
    } catch {
        fail("\(error)")
    }
}

func profileWrite(_ args: [String]) {
    guard args.count >= 2 else { fail("profile-write INDEX|new KEY=VALUE...") }
    let isNew = args[0] == "new"
    guard isNew || UInt8(args[0]) != nil else { fail("bad index \(args[0])") }
    var p = WDS.Profile(index: UInt8(args[0]) ?? 0)
    for kv in args.dropFirst() {
        let parts = kv.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { fail("bad \(kv)") }
        let (k, v) = (parts[0], parts[1])
        func bool() -> Bool { v == "1" || v == "true" || v == "yes" }
        switch k {
        case "apn": p.apn = v
        case "pdp": p.pdpType = v == "ipv4" ? .ipv4 : v == "ipv6" ? .ipv6 : .ipv4v6
        case "user": p.username = v
        case "pass": p.password = v
        case "auth": guard let a = WDS.Authentication(name: v) else { fail("bad auth \(v)") }; p.authentication = a
        case "pcscf-pco": p.pcscfUsingPCO = bool()
        case "pcscf-dhcp": p.pcscfUsingDHCP = bool()
        case "imcn": p.imcn = bool()
        case "disabled": p.apnDisabled = bool()
        case "type":
            var m: WDS.APNTypeMask = []
            for t in v.split(separator: ",") {
                switch t {
                case "default": m.insert(.default)
                case "ims": m.insert(.ims)
                case "mms": m.insert(.mms)
                case "dun": m.insert(.dun)
                case "supl": m.insert(.supl)
                case "ia": m.insert(.ia)
                case "emergency": m.insert(.emergency)
                case "ut": m.insert(.ut)
                default: fail("bad type \(t)")
                }
            }
            p.apnType = m
        default: fail("unknown key \(k)")
        }
    }
    var o = Options()
    o.verbose = CommandLine.arguments.contains("-v")
    let dev = openDevice(o)
    defer { dev.close() }
    do {
        let wds = try dev.allocateClient(.wds)
        defer { wds.release() }
        let r: QMIMessage
        if isNew {
            r = try wds.request(WDS.createProfile, [.u8(0x01, WDS.profileType3GPP)] + p.settingTLVs)
            p.index = WDS.parseCreatedProfileIndex(r) ?? 0
            print("created profile \(p.index)")
        } else {
            r = try wds.request(WDS.modifyProfile, [WDS.profileIdentifier(p.index)] + p.settingTLVs)
            print("modified profile \(p.index)")
        }
        let now = try wds.request(WDS.getProfileSettings, [WDS.profileIdentifier(p.index)])
        print("  " + WDS.parseProfile(now, index: p.index).summary)
    } catch let e as QMIHostError {
        if case .protocolError(_, let m) = e, let x = WDS.parseExtendedError(m) { fail("\(e) (extended error \(x))") }
        fail("\(e)")
    } catch {
        fail("\(error)")
    }
}

// MARK: - connect (M3/M4)

func describe(_ s: WDS.RuntimeSettings) -> [String] {
    var out: [String] = []
    if let a = s.ipv4Address { out.append("ipv4 \(a)/\(s.ipv4SubnetMask?.prefixLength ?? 32) gw \(s.ipv4Gateway.map(String.init(describing:)) ?? "-")") }
    if let a = s.ipv6Address { out.append("ipv6 \(a) gw \(s.ipv6Gateway.map(String.init(describing:)) ?? "-")") }
    let dns = s.ipv4DNS.map(\.description) + s.ipv6DNS.map(\.description)
    if !dns.isEmpty { out.append("dns \(dns.joined(separator: " "))") }
    let pcscf = s.pcscfIPv4.map(\.description) + s.pcscfIPv6.map(\.description)
    if !pcscf.isEmpty { out.append("p-cscf \(pcscf.joined(separator: " "))") }
    if let m = s.mtu { out.append("mtu \(m)") }
    if let apn = s.apn { out.append("apn \(apn)") }
    return out
}

final class Connection {
    let dev: QMIDevice
    var sessions: [(PDNSession, Utun)] = []
    var wda: QMIClient?
    var publisher: ServicePublisher?
    var tornDown = false
    var lastStats: [NSNumber: [String: NSNumber]] = [:]
    var lastStatsTime = Date()

    init(dev: QMIDevice) { self.dev = dev }

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        publisher?.removeAll()
        for (s, u) in sessions {
            dev.modem.detachMux(s.config.muxID)
            s.disconnect()
            u.close()
        }
        wda?.release()
        dev.close()
    }

    func printStats() {
        let now = Date()
        let dt = now.timeIntervalSince(lastStatsTime)
        let stats = dev.modem.statistics()
        for (s, u) in sessions {
            guard let cur = stats[NSNumber(value: s.config.muxID)] else { continue }
            let prev = lastStats[NSNumber(value: s.config.muxID)] ?? [:]
            func d(_ k: String) -> Double { Double(cur[k]?.uint64Value ?? 0) - Double(prev[k]?.uint64Value ?? 0) }
            let rxMbps = d("rx_bytes") * 8 / dt / 1e6, txMbps = d("tx_bytes") * 8 / dt / 1e6
            print(String(format: "%@ %@  rx %.1f Mbit/s (%llu pkts, %llu drops)  tx %.1f Mbit/s (%llu pkts, %llu drops)  flow-off %llu ms",
                         s.config.name, u.name, rxMbps, cur["rx_packets"]?.uint64Value ?? 0, cur["rx_drops"]?.uint64Value ?? 0,
                         txMbps, cur["tx_packets"]?.uint64Value ?? 0, cur["tx_drops"]?.uint64Value ?? 0,
                         cur["flow_disabled_ms"]?.uint64Value ?? 0))
        }
        if let g = stats[0] {
            print("usb   " + g.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        }
        lastStats = stats
        lastStatsTime = now
    }
}

var statsTimer: DispatchSourceTimer?
var flowTestTimer: DispatchSourceTimer?
var stallTestTimer: DispatchSourceTimer?

func connect(_ o: Options) {
    guard geteuid() == 0 || o.dryRun else { fail("run needs root (utun, ifconfig, route): sudo qmictl run ... (or --dry-run)") }
    guard !o.pdns.isEmpty else { fail("run needs at least one --pdn") }
    let dev = openDevice(o)
    let conn = Connection(dev: dev)

    dev.modem.terminationHandler = {
        print("modem went away")
        exit(1)
    }
    dev.modem.commandFrameHandler = { mux, cmd, type in
        let name = [1: "flow-disable", 2: "flow-enable"][Int(cmd)] ?? "command \(cmd)"
        print(String(format: "qmap mux 0x%02x: %@ (type %d)", mux, name, type))
    }
    dev.onIndication = { m in
        if m.service == .wds, m.messageID == WDS.getPacketServiceStatus, let s = WDS.parsePacketServiceStatus(m) {
            let pdn = conn.sessions.first { $0.0.clientIDs.contains(m.clientID) }?.0.config.name ?? "cid \(m.clientID)"
            print("\(pdn): packet service \(s.connectionName)\(s.connection == 1 ? ", \(s.callEnd)" : "")")
        }
    }

    do {
        // WDA Set Data Format: raw IP + QMAP both ways; use what the modem grants (PLAN.md §4.2).
        let wda = try dev.allocateClient(.wda)
        conn.wda = wda
        var req = WDA.Request(endpointInterface: UInt32(dev.modem.interfaceNumber))
        if o.flowControl { req.flowControl = true }
        let g = WDA.parseGranted(try wda.request(WDA.setDataFormat, req.tlvs))
        print("data format: link \(g.linkLayer.map(String.init) ?? "?") ul-agg \(g.uplinkAggregation.map(String.init) ?? "?") dl-agg \(g.downlinkAggregation.map(String.init) ?? "?") " +
              "dl \(g.downlinkMaxDatagrams.map(String.init) ?? "?")x\(g.downlinkMaxSize.map(String.init) ?? "?") " +
              "ul \(g.uplinkMaxDatagrams.map(String.init) ?? "?")x\(g.uplinkMaxSize.map(String.init) ?? "?") pad \(g.downlinkMinPadding.map(String.init) ?? "-") " +
              "flow-control \(g.flowControl.map { $0 ? "on" : "off" } ?? "-")")
        if let problem = g.datapathProblem {
            throw QMIHostError.transport("unusable data format: \(problem) (see data format above)")
        }
        if o.dryRun {
            for cfg in o.pdns {
                let session = PDNSession(device: dev, config: cfg, dataInterface: dev.modem.interfaceNumber)
                do {
                    try session.connect()
                    print("\(cfg) up (dry run)")
                    for line in describe(session.merged) { print("  \(line)") }
                } catch {
                    print("\(cfg) failed: \(error)")
                }
                for (fam, err) in session.failures { print("  ipv\(fam) failed: \(err)") }
                session.disconnect()
            }
            conn.teardown()
            exit(0)
        }
        dev.modem.batchUtunIO = !o.noBatch
        dev.modem.batchFallbackHandler = { print("utun batching off: \($0)") }
        try dev.modem.startDatapath(withDownlinkSize: UInt(g.downlinkMaxSize ?? 16384),
                                    uplinkSize: UInt(g.uplinkMaxSize ?? 0),
                                    uplinkDatagrams: UInt(g.uplinkMaxDatagrams ?? 0))

        if o.publish {
            let pub = try ServicePublisher(name: "qmictl")
            conn.publisher = pub
            try pub.publish([ServicePublisher.modemKey: [
                "VendorID": Int(dev.modem.vendorID), "ProductID": Int(dev.modem.productID),
                "Interface": Int(dev.modem.interfaceNumber), "State": "running",
            ]])
        }
        for (i, cfg) in o.pdns.enumerated() {
            let session = PDNSession(device: dev, config: cfg, dataInterface: dev.modem.interfaceNumber)
            try session.connect()
            let utun = try Utun()
            conn.sessions.append((session, utun))
            try utun.configure(session.merged)
            dev.modem.attachMux(cfg.muxID, fd: utun.fd)
            print("\(cfg) up on \(utun.name)\(utun.maxPendingResult == 0 ? "" : " (max-pending: \(String(cString: strerror(utun.maxPendingResult))))")")
            for line in describe(session.merged) { print("  \(line)") }
            for (fam, err) in session.failures { print("  ipv\(fam) failed: \(err)") }
            if o.scoped {
                if session.merged.ipv4Address != nil { try utun.addScopedDefault(inet6: false) }
                if session.merged.ipv6Address != nil { try utun.addScopedDefault(inet6: true) }
            }
            if i == 0 { for r in o.routes { try utun.addHostRoute(r); print("  route \(r) -> \(utun.name)") } }
            if let pub = conn.publisher {
                let policy = o.policies[cfg.name] ?? .preferWifi
                let id = ServicePublisher.serviceID(for: cfg.name)
                var entries = ServicePublisher.entities(pdnName: cfg.name, interface: utun.name,
                                                        settings: session.merged, policy: policy)
                entries[ServicePublisher.pdnKey(cfg.name)] = ServicePublisher.pdnStatus(
                    name: cfg.name, interface: utun.name, muxID: cfg.muxID, config: cfg,
                    settings: session.merged, policy: policy)
                try pub.publish(entries)
                print("  published service \(id) (\(policy.rawValue))")
            }
        }
    } catch {
        print("error: \(error)")
        conn.teardown()
        exit(1)
    }

    var sources: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        s.setEventHandler {
            print("\ndisconnecting")
            conn.printStats()
            conn.teardown()
            exit(0)
        }
        s.resume()
        sources.append(s)
    }
    if o.statsInterval > 0 {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + o.statsInterval, repeating: o.statsInterval)
        t.setEventHandler { conn.printStats() }
        t.resume()
        statsTimer = t
    }
    if o.fcTest > 0 {
        var disabled = false
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + o.fcTest, repeating: o.fcTest)
        t.setEventHandler {
            disabled.toggle()
            for (s, _) in conn.sessions { dev.modem.simulateFlowControl(disabled, mux: s.config.muxID) }
            print("fc-test: flow \(disabled ? "disabled" : "enabled") on every PDN (simulated)")
        }
        t.resume()
        flowTestTimer = t
    }
    if o.stallTest > 0 {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + o.stallTest, repeating: o.stallTest)
        t.setEventHandler {
            dev.modem.simulateInStall()
            print("stall-test: bulk IN stall cleared (simulated)")
        }
        t.resume()
        stallTestTimer = t
    }
    print("connected; Ctrl-C to disconnect")
    withExtendedLifetime(sources) { dispatchMain() }
}

// MARK: - Daemon client (XPC)

func withDaemon(_ body: (QMIDControl, @escaping () -> Void) -> Void) {
    let c = NSXPCConnection(machServiceName: qmidMachService, options: .privileged)
    c.remoteObjectInterface = NSXPCInterface(with: QMIDControl.self)
    c.resume()
    let done = DispatchSemaphore(value: 0)
    let proxy = c.remoteObjectProxyWithErrorHandler { error in
        fail(QMIDError(xpc: error).message)
    } as! QMIDControl
    body(proxy) { done.signal() }
    // connect answers when the dial has ended: up to 60 s per family.
    if done.wait(timeout: .now() + 150) == .timedOut { fail("qmid did not answer") }
    c.invalidate()
}

func printStatus(_ d: NSDictionary) {
    if let v = d[QMIDKey.version] { print("qmid: \(v)") }
    print("modem: \(d["modem"] ?? "?")\(d["modemError"].map { " (\($0))" } ?? "")\(d["network"].map { ", \($0)" } ?? "")")
    if let s = QMIDStatus(d).sim { print("sim: \(describe(s))") }
    if let p = QMIDStatus(d).plmn { print("operator: \(describe(p))") }
    for case let p as NSDictionary in (d["pdns"] as? NSArray) ?? [] {
        var line = "\(p["name"] ?? "?"): \(p["state"] ?? "?")"
        if let i = p["interface"] { line += " on \(i)" }
        line += ", \(p["policy"] ?? "?")"
        if let u = p["uptime"] as? Int { line += ", up \(u) s" }
        if (p["wanted"] as? Bool) == false { line += ", manual" }
        print(line)
        if let a = p["ipv4"] { print("  ipv4 \(a)") }
        if let a = p["ipv6"] { print("  ipv6 \(a)") }
        if let pc = p["pcscf"] as? [String] { print("  p-cscf \(pc.joined(separator: " "))") }
        if let q = QMIDPDN(p), q.qci != nil || q.ambr != nil {
            print("  qci \(q.qci.map(String.init) ?? "?"), ambr \(q.ambr.map(describe) ?? "?")")
        }
        for b in QMIDPDN(p)?.bearers ?? [] { describe(b).forEach { print("  " + $0) } }
        if let c = p["counters"] as? NSDictionary {
            print("  rx \(c["rx_packets"] ?? 0) pkts/\(c["rx_bytes"] ?? 0) B, tx \(c["tx_packets"] ?? 0) pkts/\(c["tx_bytes"] ?? 0) B, drops rx \(c["rx_drops"] ?? 0)/tx \(c["tx_drops"] ?? 0)")
        }
        if let e = p["error"] { print("  last error: \(e)\(p["reason"].map { " [\($0)]" } ?? "")") }
        if let q = QMIDPDN(p), !q.causes.isEmpty {
            print("  causes: " + q.causes.map { c in
                [c.family.map { "ipv\($0)" }, "\(c.type) \(c.code.map(String.init) ?? "?")"].compactMap { $0 }.joined(separator: " ")
            }.joined(separator: ", "))
        }
        if let b = p["blocked"] as? [String] {
            // "ipv4: X", "ipv6: X" → "X" when every family is blocked for the same reason.
            let reasons = Set(b.map { $0.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? $0 })
            print("  blocked: \(b.count > 1 && reasons.count == 1 ? reasons.first! : b.joined(separator: "; "))")
        }
    }
    if let g = d["datapath"] as? NSDictionary {
        print("datapath: " + (g as! [String: Any]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
    }
}

func describe(_ a: QMIDAMBR) -> String {
    func mbps(_ v: UInt64) -> String { String(format: v % 1_000_000 == 0 ? "%.0f" : "%.1f", Double(v) / 1_000_000) }
    return "\(mbps(a.uplink))/\(mbps(a.downlink)) Mbps up/down"
}

// A dedicated bearer as lines: the bearer, then each filter.
func describe(_ b: QMIDBearer) -> [String] {
    func kbps(_ r: QMIDBitrates) -> String {
        [r.max.map { "max \($0 / 1000)" }, r.guaranteed.map { "gbr \($0 / 1000)" }].compactMap { $0 }.joined(separator: " ")
    }
    func filter(_ f: QMIDPacketFilter) -> String {
        var parts = ["#\(f.id) prec \(f.precedence) ipv\(f.ipVersion)"]
        if let a = f.source { parts.append("src \(a)") }
        if let a = f.destination { parts.append("dst \(a)") }
        if let p = f.ipProtocol { parts.append(p == 6 ? "tcp" : p == 17 ? "udp" : "proto \(p)") }
        func ports(_ r: ClosedRange<Int>) -> String { r.count == 1 ? "\(r.lowerBound)" : "\(r.lowerBound)-\(r.upperBound)" }
        if let r = f.sourcePorts { parts.append("sport \(ports(r))") }
        if let r = f.destinationPorts { parts.append("dport \(ports(r))") }
        return parts.joined(separator: " ")
    }
    var lines = ["bearer \(String(format: "0x%x", b.id)) qci \(b.qci.map(String.init) ?? "?")\(b.isGBR ? " GBR" : "")" +
                 "\(b.networkInitiated == true ? " (network)" : ""), up \(kbps(b.uplink)) / down \(kbps(b.downlink)) kbps"]
    lines += b.uplinkFilters.map { "  up   " + filter($0) }
    lines += b.downlinkFilters.map { "  down " + filter($0) }
    return lines
}

func describe(_ s: QMIDSIM) -> String {
    var line = [s.mccmnc, s.iccidSuffix].compactMap { $0 }.joined(separator: " ")
    if let c = s.carrier { line += ", carrier \(c)\(s.matchedBy.map { " by \($0)" } ?? "")" }
    if let a = s.attachAPN { line += ", default bearer apn \(a)\(s.attachAPNFromNetwork ? " (chosen by the network)" : "")" }
    return line
}

func describe(_ p: QMIDPLMN) -> String {
    guard p.displayName != nil else { return "no name" }
    var s = "\(p.longName ?? "-") / \(p.shortName ?? "-")\(p.nameFromNetwork ? " (network)" : "")"
    if let b = p.emergencyBearers { s += ", emergency bearers \(b ? "yes" : "no")" }
    if p.emergencyAccessBarred == true { s += ", emergency access barred" }
    return s
}

func describe(_ p: QMIDPDN) -> String {
    var s = "\(p.name) \(p.stateName)"
    if let i = p.interface { s += " on \(i)" }
    if let a = p.ipv4 { s += " \(a)" }
    if let a = p.ipv6 { s += " \(a)" }
    if !p.pcscf.isEmpty { s += " p-cscf \(p.pcscf.joined(separator: ","))" }
    if let q = p.qci { s += " qci \(q)" }
    if let a = p.ambr { s += " ambr \(describe(a))" }
    if let e = p.error, !p.isConnected { s += " (\(e))" }
    return s
}

// Uses QMIDClient (as any client app would), so it also shows reconnects after qmid restarts.
func streamEvents() -> Never {
    let fmt = DateFormatter()
    fmt.dateFormat = "HH:mm:ss"
    let client = QMIDClient(queue: .main)
    client.onAvailabilityChange = { print("\(fmt.string(from: Date())) qmid \($0 ? "available" : "unavailable")") }
    client.onEvent = { e in
        let t = fmt.string(from: Date())
        switch e {
        case .modem(let state, let network, let error):
            print("\(t) modem \(state)\(network.map { ", \($0)" } ?? "")\(error.map { " (\($0))" } ?? "")")
        case .pdn(let p): print("\(t) pdn \(describe(p))")
        case .config: print("\(t) config changed")
        case .unknown(let type) where type == QMIDEventType.sim: break    // onSIM
        case .unknown(let type) where type == QMIDEventType.plmn: break   // onPLMN
        case .unknown(let type) where type == QMIDEventType.bearers: break   // onBearers
        case .unknown(let type): print("\(t) event \(type)")
        }
    }
    client.onSIM = { s in print("\(fmt.string(from: Date())) sim \(s.map(describe) ?? "none")") }
    client.onPLMN = { p in print("\(fmt.string(from: Date())) operator \(p.map(describe) ?? "none")") }
    client.onBearers = { pdn, bearers in
        print("\(fmt.string(from: Date())) bearers \(pdn): \(bearers.isEmpty ? "none" : "\(bearers.count)")")
        for b in bearers { describe(b).forEach { print("  " + $0) } }
    }
    client.subscribe()
    withExtendedLifetime(client) { dispatchMain() }
}

// qmid's log over XPC: recent history, then live. Falls back to `log stream` (macOS keeps only
// notice/error on disk) when qmid can't be reached.
func streamLog(_ args: [String]) -> Never {
    var level = QMIDLogLevel.info
    var history = true
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--level" where i + 1 < args.count:
            guard let l = QMIDLogLevel(name: args[i + 1]) else { fail("bad level \(args[i + 1]) (debug, info, notice, error)") }
            level = l
            i += 1
        case "--no-history": history = false
        default: fail("usage: qmictl log [--level debug|info|notice|error] [--no-history]")
        }
        i += 1
    }
    let fmt = DateFormatter()
    fmt.dateFormat = "HH:mm:ss.SSS"
    let client = QMIDClient(queue: .main)
    client.onLog = { e in
        print("\(fmt.string(from: e.time)) \(e.level.name.prefix(1).uppercased()) \(e.category == "qmid" ? "" : "[\(e.category)] ")\(e.message)")
    }
    var announced = false
    client.onAvailabilityChange = { up in
        if announced || !up { FileHandle.standardError.write(Data("-- qmid \(up ? "available" : "unavailable")\n".utf8)) }
        announced = true
    }
    client.apiVersion { result in
        guard case .failure(let e) = result else { return }
        FileHandle.standardError.write(Data("\(e); falling back to log stream\n".utf8))
        let argv = ["log", "stream", "--style", "compact", "--level", level == .debug ? "debug" : "info",
                    "--predicate", "subsystem == \"\(qmidMachService)\""]
        execv("/usr/bin/log", argv.map { strdup($0) } + [nil])
        fail("can't run /usr/bin/log")
    }
    client.subscribeLogs(level: level, history: history)
    withExtendedLifetime(client) { dispatchMain() }
}

func daemonCommand(_ args: [String]) -> Bool {
    func reportResult(_ err: String?) {
        if let err { fail(err) }
        print("ok")
    }
    switch args.first {
    case "status":
        withDaemon { d, done in d.status { printStatus($0); done() } }
    case "connect" where args.count == 2:
        withDaemon { d, done in d.connect(args[1]) { reportResult($0); done() } }
    case "disconnect" where args.count == 2:
        withDaemon { d, done in d.disconnect(args[1]) { reportResult($0); done() } }
    case "policy" where args.count == 3:
        withDaemon { d, done in d.setPolicy(args[1], policy: args[2]) { reportResult($0); done() } }
    case "restart":
        withDaemon { d, done in d.restart { reportResult($0); done() } }
    case "reload":
        withDaemon { d, done in d.reload { reportResult($0); done() } }
    case "config" where args.count == 2 && args[1] == "get":
        withDaemon { d, done in
            d.getConfig { data, err in
                if let data { FileHandle.standardOutput.write(data); print() } else { fail(err ?? "no config") }
                done()
            }
        }
    case "config" where args.count == 3 && args[1] == "set":
        guard let data = FileManager.default.contents(atPath: args[2]) else { fail("can't read \(args[2])") }
        withDaemon { d, done in d.setConfig(data) { reportResult($0); done() } }
    case "events":
        streamEvents()
    case "log":
        streamLog(Array(args.dropFirst()))
    case "sync":
        withDaemon { d, done in
            d.profiles { list in
                for case let e as NSDictionary in list {
                    if let s = e["sim"] {
                        print("sim: \(s)\(e["carrier"].map { ", carrier \($0)" } ?? "")\(e["attachAPN"].map { ", default bearer apn \($0)" } ?? "")")
                    } else if let l = e["learned"] as? [String] {
                        print("default bearer apns seen (home mccmnc: apn):"); l.forEach { print("  \($0)") }
                    } else if let pdn = e["pdn"] {
                        print("\(pdn): profile \(e["profile"] ?? "-")\((e["attach"] as? Bool) == true ? " (attach)" : ""): \(e["action"] ?? "")")
                        if let st = e["settings"] { print("  \(st)") }
                    } else if let m = e["modem"] as? [String] {
                        print("modem profiles:"); m.forEach { print("  \($0)") }
                    } else if let a = e["autoconnect"] { print("modem autoconnect: \(a)") }
                    else if let a = e["attach"] { print("lte attach profile: \(a)") }
                    else if let err = e["error"] { print("sync error: \(err)") }
                }
                done()
            }
        }
    default:
        return false
    }
    return true
}

if daemonCommand(Array(CommandLine.arguments.dropFirst())) { exit(0) }
if CommandLine.arguments.dropFirst().first == "profile-write" {
    profileWrite(Array(CommandLine.arguments.dropFirst(2)).filter { $0 != "-v" })
    exit(0)
}

let options = parseOptions()
switch options.command {
case "probe": probe(options)
case "modem-status": status(options)
case "profiles": profiles(options)
case "plmn-name": plmnName(options)
case "run": connect(options)
default: print(usage); exit(2)
}
