import Foundation
import QMIDAPI
import QMIDatapath
import QMIHost
import QMIKit

// qmictl: qmid's command line (XPC), plus tools that talk to the modem directly for development
// (qmid stopped). Only run needs root (utun, ifconfig, route).

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
  qmictl prepare-sim ICCID [MCCMNC] [--hold SECONDS]
                                            write the attach profile for that card before a SIM
                                            switch; held until Ctrl-C (or SECONDS), which ends it
  qmictl cancel-sim ICCID                   end a prepare-sim: attach profile back to the current SIM
  qmictl radio [-v]                         serving cells (LTE CA, NR), neighbours, signal; -v: raw TLVs
  qmictl radio watch [-v]                   radio events as they come (cells, activation, RRC); -v: neighbours
  qmictl airplane on|off                    modem radio off / on (PDNs wait while off)
  qmictl restart-modem                      reset the modem; qmid reopens it and redials
  qmictl bands                              allowed technologies and LTE / NR bands
  qmictl bands set [lte 1,3] [nsa 41] [sa 41] [--persistent]
                                            restrict bands (others unchanged); until the modem
                                            restarts unless --persistent
  qmictl bands reset [--persistent]         back to the setting before qmid changed it (else
                                            every supported band)
  qmictl modes set lte[,nr,...] [--persistent]
                                            allowed technologies (bands unchanged); lte = LTE only
  qmictl modes reset [--persistent]         back to the modes before qmid changed them
  qmictl gnss                               GNSS engine / session, XTRA
  qmictl gnss watch [--sats] [-v] [--nmea] [--interval S] [--for S]
                                            run GNSS through qmid: positions, satellites (-v: each)
  qmictl xtra                               GNSS assistance data (XTRA): validity, servers
  qmictl xtra load FILE                     load an XTRA file (as downloaded from a server above)
  qmictl sharing                            Internet Sharing over a PDN (config "sharing"): state, clients

usage (direct to the modem; stop qmid first). DEV: [--iface N] [--vendor HEX]... [-v]
  qmictl probe        DEV                  QMI services and versions
  qmictl modem-status DEV                  firmware, IMEI, SIM, registration, default bearer APN
  qmictl profiles     DEV                  modem profiles, autoconnect, LTE attach PDN list
  qmictl plmn-name    DEV                  operator long/short name: network (NITZ) and modem's own
  qmictl nas-survey   DEV                  raw TLVs of the NAS cell, signal, band and CA messages
  qmictl ambr-survey  DEV                  raw TLVs of WDS/QoS messages that may carry the APN-AMBR (profile 1)
  qmictl reattach     DEV                  low power, then online: attach again with the attach profile
  qmictl loc-survey   DEV [--register HEX] [--reg-tlv T:HEX]... [--supl] [--call ID[:TT=HEX,...]]...
                      [--listen S]         LOC: XTRA source / validity, engine lock, raw indications
  qmictl loc-inject   FILE DEV [--msg 35|a7] [--part-size N] [--part-timeout S] [--stop-after N]
                      [--listen S]         LOC: load an XTRA file part by part, timing each ack
  qmictl loc-fix      DEV [--timeout S] [--after-fix S] [--log FILE] [--no-register] [--release-test S]
                      [--no-stop] [--mask HEX] [--inject-file FILE]
                                           LOC: 1 Hz session, satellites, time to first fix
  qmictl profile-write INDEX|new KEY=VALUE... DEV
                                           create/modify a profile; keys: apn, pdp
                      (ipv4|ipv6|ipv4v6|ppp|non-ip), user, pass, auth (none|pap|chap|pap-chap),
                      pcscf-pco, pcscf-dhcp, imcn, disabled (0|1), type (default,ims,...)
  qmictl run --pdn NAME:PROFILE:MUX[:FAMILIES[:POLICY]] [--pdn ...] DEV
             [--publish] [--route HOST]... [--scoped] [--stats SECONDS] [--dry-run]
             [--no-batch] [--fc-test SECONDS] [--stall-test SECONDS] [--flow-control]

  PROFILE   3GPP profile index (AT+CGDCONT cid), or apn=NAME
  MUX       QMAP mux id, e.g. 0x81
  FAMILIES  4, 6 or 46 (default 46)
  POLICY    prefer-wifi | prefer-cellular | last-resort | never
            (default: never for a PDN named ims, prefer-wifi otherwise)
  --iface   QMI USB interface number (default: found by its descriptor)
  --vendor  extra USB vendor ID to look for, e.g. 1234 (known modem makers are built in)
  -v        QMI trace
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

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("qmictl: \(message)\n".utf8))
    exit(1)
}

// MARK: - Arguments

// A command's arguments, taken front to back.
struct Args {
    private var rest: ArraySlice<String>

    init(_ args: [String]) { rest = args[...] }

    mutating func next() -> String? { rest.popFirst() }

    // The value after `option`.
    mutating func value(_ option: String) -> String {
        guard let v = rest.popFirst() else { fail("\(option) needs a value") }
        return v
    }

    mutating func number(_ option: String) -> Double {
        let v = value(option)
        guard let n = Double(v) else { fail("bad \(option) \(v)") }
        return n
    }

    mutating func int(_ option: String) -> Int {
        let v = value(option)
        guard let n = Int(v) else { fail("bad \(option) \(v)") }
        return n
    }

    // Hex, with or without 0x.
    mutating func hex(_ option: String) -> UInt64 {
        let v = value(option)
        guard let n = UInt64(v.lowercased().replacingOccurrences(of: "0x", with: ""), radix: 16) else { fail("bad \(option) \(v) (hex)") }
        return n
    }

    // An argument the command doesn't take (or -h).
    func reject(_ a: String) -> Never {
        if a == "-h" || a == "--help" { print(usage); exit(0) }
        fail("\(a.hasPrefix("-") ? "unknown option" : "unexpected argument") \(a) (qmictl --help)")
    }
}

// Options of every command that opens the modem itself.
struct DeviceOptions {
    var iface: Int?
    var vendors: [UInt16] = []
    var verbose = false

    // Takes `a` (and its value) if it is a device option.
    mutating func take(_ a: String, _ args: inout Args) -> Bool {
        switch a {
        case "--iface": iface = args.int(a)
        case "--vendor":
            let v = args.value(a)
            guard v.count == 4, let id = UInt16(v, radix: 16) else { fail("bad vendor ID \(v) (4 hex digits)") }
            vendors.append(id)
        case "-v", "--verbose": verbose = true
        default: return false
        }
        return true
    }

    // For commands with no options of their own.
    static func parse(_ args: inout Args) -> DeviceOptions {
        var d = DeviceOptions()
        while let a = args.next() { if !d.take(a, &args) { args.reject(a) } }
        return d
    }
}

func openDevice(_ o: DeviceOptions) -> QMIDevice {
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

// Get Supported Messages (every service): TLV 0x10, a u16 length then a bitmap, bit N set =
// message N answered. nil without the TLV.
func supportedMessages(_ c: QMIClient, timeout: TimeInterval = 2) throws -> [Int]? {
    guard let v = try c.request(0x001E, timeout: timeout)[tlv: 0x10], v.count >= 2 else { return nil }
    return Array(v.dropFirst(2)).bitIndexes
}

func hex16(_ ids: [Int]) -> String { ids.map { String(format: "0x%04x", $0) }.joined(separator: " ") }

// MARK: - probe

func probe(_ o: DeviceOptions) {
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

// MARK: - modem-status

func modemStatus(_ o: DeviceOptions) {
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
        if let cards = section("card status", { try UIM.parseCardStatus(try uim.request(UIM.getCardStatus)) }) {
            for (i, c) in cards.enumerated() {
                let apps = c.applications.map { "type \($0.type) state \($0.state)" }.joined(separator: ", ")
                print("sim \(i):    \(c.stateName), \(c.isReady ? "ready" : "not ready") [\(apps)]")
            }
        }
        uim.release()
    }
    if let nas = section("nas", { try dev.allocateClient(.nas) }) {
        if let s = section("serving system", { try NAS.parseServingSystem(try nas.request(NAS.getServingSystem)) }) {
            let rats = s.radioInterfaces.map(NAS.ServingSystem.radioName).joined(separator: "+")
            let plmn = s.mcc.map { "\($0)-\(String(format: "%02d", s.mnc ?? 0))" } ?? "?"
            print("network:  \(s.registrationName), ps \(s.psAttached ? "attached" : "detached"), rat \(rats.isEmpty ? "none" : rats), plmn \(plmn) \(s.operatorName ?? "")")
        }
        nas.release()
    }
    if let wds = section("wds", { try dev.allocateClient(.wds) }) {
        if let r = section("lte attach parameters", { try wds.request(WDS.getLTEAttachParameters, timeout: 5) }) {
            print("bearer:   default bearer apn \"\(WDS.parseAttachParameters(r).apn ?? "")\"")
        }
        wds.release()
    }
}

// MARK: - reattach

// DMS Set Operating Mode low power, then online: the modem detaches and attaches again with the
// current LTE attach profile (what qmid's reattachLTE does).
func reattach(_ o: DeviceOptions) {
    let dev = openDevice(o)
    defer { dev.close() }
    do {
        let dms = try dev.allocateClient(.dms)
        defer { dms.release() }
        try dms.request(DMS.setOperatingMode, DMS.operatingModeRequest(.lowPower), timeout: 20)
        print("low power")
        Thread.sleep(forTimeInterval: 2)
        try dms.request(DMS.setOperatingMode, DMS.operatingModeRequest(.online), timeout: 20, accept: [.noEffect])
        print("online")
    } catch {
        fail("\(error)")
    }
}

// MARK: - plmn-name

func plmnName(_ o: DeviceOptions) {
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
            d.tlvDump(prefix: String(format: "  0x%04x ", NAS.getOperatorNameData)).forEach { print($0) }
            r.tlvDump(prefix: String(format: "  0x%04x ", NAS.getPLMNName)).forEach { print($0) }
        }
        let nitz = NAS.parseNITZName(d), table = try NAS.parsePLMNName(r)
        print("network:  long \"\(nitz?.longName ?? "-")\", short \"\(nitz?.shortName ?? "-")\" (NITZ)")
        print("modem:    long \"\(table.longName ?? "-")\", short \"\(table.shortName ?? "-")\" (Get PLMN Name)")
    } catch {
        fail("\(error)")
    }
}

// MARK: - nas-survey

// Raw TLVs of the NAS messages that carry cell, signal, band and CA information, to check the
// layout on a given modem before writing parsers. Read only.
func nasSurvey(_ o: DeviceOptions) {
    let dev = openDevice(o)
    defer { dev.close() }
    let messages: [(UInt16, String)] = [
        (NAS.getServingSystem, "Get Serving System"),
        (NAS.getSysInfo, "Get Sys Info"),
        (NAS.getCellLocationInfo, "Get Cell Location Info"),
        (NAS.getSignalInfo, "Get Signal Info"),
        (NAS.getRFBandInfo, "Get RF Band Info"),
        (NAS.getLTECPHYCAInfo, "Get LTE CPHY CA Info"),
        (0x00E8, "Get ENDC Config"),
    ]
    do {
        let nas = try dev.allocateClient(.nas)
        defer { nas.release() }
        for (id, name) in messages {
            print(String(format: "0x%04x %@:", id, name))
            do { try nas.request(id, timeout: 2).tlvDump(prefix: "  ").forEach { print($0) } } catch { print("  \(error)") }
        }
        // The IDs libqmi doesn't define: the ones worth probing.
        do {
            if let ids = try supportedMessages(nas) {
                let known: Set<Int> = [0x00, 0x01, 0x02, 0x03, 0x1E, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27,
                                       0x2A, 0x2B, 0x31, 0x33, 0x34, 0x39, 0x43, 0x44, 0x4D, 0x4F, 0x50, 0x5A,
                                       0x65, 0x67, 0x6C, 0x89, 0xAC]
                print("0x001e Get Supported Messages: \(ids.count) IDs")
                print("  not in libqmi: " + hex16(ids.filter { !known.contains($0) }))
            }
        } catch {
            print("0x001e Get Supported Messages: \(error)")
        }
    } catch {
        fail("\(error)")
    }
    // COEX Get WWAN State: TLV 0x13 the LTE carriers, 0x22 the NR carriers (NAS.radioCells).
    do {
        let coex = try dev.allocateClient(NAS.coexService)
        defer { coex.release() }
        print("coex 0x0022 Get WWAN State:")
        try coex.request(NAS.coexGetWWANState, timeout: 2).tlvDump(prefix: "  ").forEach { print($0) }
    } catch {
        print("  coex: \(error)")
    }
}

// MARK: - ambr-survey

// Raw TLVs of the WDS and QoS messages that may carry the APN-AMBR, on a call of our own
// (qmid stopped), to find where a modem reports it whole. Any u16/u32/u64 in them equal to one
// of `find` (APN-AMBRs seen on networks, as bps and kbps) is flagged.
func ambrSurvey(_ o: DeviceOptions) {
    let profile: UInt8 = 1, muxID: UInt8 = 0x81
    let find: Set<UInt64> = [500_000_000, 500_000, 256_000_000, 256_000, 244_000_000, 244_000, 508_640, 508_640_000]
    let dev = openDevice(o)
    defer { dev.close() }
    func ask(_ c: QMIClient, _ id: UInt16, _ name: String, _ tlvs: [TLV] = []) {
        let title = String(format: "0x%04x %@", id, name)
        let r: QMIMessage
        do { r = try c.request(id, tlvs, timeout: 5) } catch { return print("\(title): \(error)") }
        print("\(title):")
        for t in r.tlvs where t.type != 0x02 {
            print("  " + t.dump)
            for w in [2, 4, 8] where t.value.count >= w {
                for off in 0...(t.value.count - w) {
                    var b = ByteReader(Array(t.value[off..<off + w]) + [UInt8](repeating: 0, count: 8 - w))
                    if let v = try? b.u64(), v != 0, find.contains(v) { print("     ^ \(v) at offset \(off) as u\(w * 8)") }
                }
            }
        }
    }
    do {
        let wds = try dev.allocateClient(.wds)
        defer { wds.release() }
        try wds.request(WDS.bindMuxDataPort, WDS.bindMuxDataPortRequest(interface: UInt32(dev.modem.interfaceNumber), muxID: muxID))
        try wds.request(WDS.setIPFamily, [.u8(0x01, 4)])
        let s = try wds.request(WDS.startNetworkInterface, WDS.startRequest(profile: profile, apn: nil, family: 4),
                                timeout: 60, accept: [.noEffect, .callFailed])
        print("start: \(s.result.map { "\($0)" } ?? "?")")
        // Ends our call (runs before the release above).
        defer {
            if let h = WDS.parseHandle(s) {
                _ = try? wds.request(WDS.stopNetworkInterface, [.u32(0x01, h)], timeout: 10,
                                     accept: [.noEffect, .outOfCall, .invalidHandle])
                print("stopped")
            }
        }
        ask(wds, WDS.getAMBRInfo, "Get AMBR Info")
        ask(wds, WDS.getRuntimeSettings, "Get Runtime Settings", WDS.runtimeSettingsRequest())
        ask(wds, WDS.getLTEAttachParameters, "Get LTE Attach Params")
        ask(wds, 0x0091, "Get Data Bearer Tech Ex")
        ask(wds, 0x00F3, "Get Data Bearer Type")
        ask(wds, 0x0023, "Get Channel Rates")
        ask(wds, 0x0041, "Get Current Channel Rate")
        ask(wds, 0x0052, "Get Data Bearer Tech")
        if let ids = try? supportedMessages(wds) { print("WDS supported (\(ids.count)): " + hex16(ids)) }
        let qos = try dev.allocateClient(.qos)
        defer { qos.release() }
        try qos.request(QoS.bindDataPort, QoS.bindDataPortRequest(interface: UInt32(dev.modem.interfaceNumber), muxID: muxID))
        try qos.request(QoS.setClientIPPref, QoS.clientIPPrefRequest(family: 4))
        ask(qos, QoS.getQoSInfo, "Get QoS Info (QoS ID 0)", QoS.qosIDRequest(0))
        ask(qos, QoS.getGrantedQoS, "Get Granted QoS (QoS ID 0)", QoS.qosIDRequest(0))
        ask(qos, QoS.getQoSIDs, "Get QoS IDs")
        ask(qos, 0x0031, "Get QoS Network Status / Global Flow")
        if let ids = try? supportedMessages(qos) { print("QoS supported (\(ids.count)): " + hex16(ids)) }
    } catch {
        fail("\(error)")
    }
}

// MARK: - profiles

func profiles(_ o: DeviceOptions) {
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
            if o.verbose { r.tlvDump(prefix: "      ").forEach { print($0) } }
        }
        if let r = try? wds.request(WDS.getAutoconnectSettings) {
            print("autoconnect: \(WDS.parseAutoconnect(r).map { "\($0)" } ?? "?")\(r.u8(tlv: 0x10).map { ", roaming \($0)" } ?? "")")
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

func profileWrite(_ args: inout Args) {
    var o = DeviceOptions()
    var target: String?
    var p = WDS.Profile(index: 0)
    var keys = 0
    while let a = args.next() {
        if o.take(a, &args) { continue }
        guard !a.hasPrefix("-") else { args.reject(a) }
        guard target != nil else { target = a; continue }
        let parts = a.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { fail("bad \(a)") }
        let (k, v) = (parts[0], parts[1])
        keys += 1
        func bool() -> Bool { v == "1" || v == "true" || v == "yes" }
        switch k {
        case "apn": p.apn = v
        case "pdp": guard let t = WDS.PDPType(name: v) else { fail("bad pdp \(v)") }; p.pdpType = t
        case "user": p.username = v
        case "pass": p.password = v
        case "auth": guard let auth = WDS.Authentication(name: v) else { fail("bad auth \(v)") }; p.authentication = auth
        case "pcscf-pco": p.pcscfUsingPCO = bool()
        case "pcscf-dhcp": p.pcscfUsingDHCP = bool()
        case "imcn": p.imcn = bool()
        case "disabled": p.apnDisabled = bool()
        case "type":
            guard let m = WDS.APNTypeMask(names: v.split(separator: ",").map(String.init)) else { fail("bad type \(v)") }
            p.apnType = m
        default: fail("unknown key \(k)")
        }
    }
    guard let target, keys > 0 else { fail("profile-write INDEX|new KEY=VALUE...") }
    let isNew = target == "new"
    if !isNew {
        guard let i = UInt8(target) else { fail("bad index \(target)") }
        p.index = i
    }
    let dev = openDevice(o)
    defer { dev.close() }
    do {
        let wds = try dev.allocateClient(.wds)
        defer { wds.release() }
        if isNew {
            let r = try wds.request(WDS.createProfile, [.u8(0x01, WDS.profileType3GPP)] + p.settingTLVs)
            p.index = WDS.parseCreatedProfileIndex(r) ?? 0
            print("created profile \(p.index)")
        } else {
            try wds.request(WDS.modifyProfile, [WDS.profileIdentifier(p.index)] + p.settingTLVs)
            print("modified profile \(p.index)")
        }
        let now = try wds.request(WDS.getProfileSettings, [WDS.profileIdentifier(p.index)])
        print("  " + WDS.parseProfile(now, index: p.index).summary)
    } catch {
        if case .protocolError(_, let m)? = error as? QMIHostError, let x = WDS.parseExtendedError(m) {
            fail("\(error) (extended error \(x))")
        }
        fail("\(error)")
    }
}

// MARK: - run

struct RunOptions {
    var device = DeviceOptions()
    var pdns: [PDNConfig] = []
    var policies: [String: QMIDPolicy] = [:]
    var routes: [String] = []
    var scoped = false
    var statsInterval: Double = 0
    var dryRun = false
    var publish = false
    var noBatch = false
    var fcTest: Double = 0
    var stallTest: Double = 0
    var flowControl = false

    // --pdn NAME:PROFILE:MUX[:FAMILIES[:POLICY]]
    mutating func addPDN(_ spec: String) {
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
        let name = parts[0]
        pdns.append(PDNConfig(name: name, profile: profile, apn: apn, muxID: mux, families: families))
        if parts.count > 4 {
            guard let p = QMIDPolicy(rawValue: parts[4]) else { fail("bad policy in \(spec)") }
            policies[name] = p
        } else {
            policies[name] = name == "ims" ? .never : .preferWifi
        }
    }

    static func parse(_ args: inout Args) -> RunOptions {
        var o = RunOptions()
        while let a = args.next() {
            if o.device.take(a, &args) { continue }
            switch a {
            case "--pdn": o.addPDN(args.value(a))
            case "--route": o.routes.append(args.value(a))
            case "--scoped": o.scoped = true
            case "--dry-run": o.dryRun = true
            case "--publish": o.publish = true
            case "--stats": o.statsInterval = args.number(a)
            case "--no-batch": o.noBatch = true
            case "--fc-test": o.fcTest = args.number(a)
            case "--stall-test": o.stallTest = args.number(a)
            case "--flow-control": o.flowControl = true
            default: args.reject(a)
            }
        }
        return o
    }
}

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
    var lastStats: [UInt8: QMIDCounters] = [:]
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
            let mux = s.config.muxID
            guard let d = stats[NSNumber(value: mux)] else { continue }
            let cur = QMIDCounters(d as NSDictionary), prev = lastStats[mux] ?? QMIDCounters()
            lastStats[mux] = cur
            func mbps(_ k: KeyPath<QMIDCounters, UInt64?>) -> Double {
                (Double(cur[keyPath: k] ?? 0) - Double(prev[keyPath: k] ?? 0)) * 8 / dt / 1e6
            }
            print(String(format: "%@ %@  rx %.1f Mbit/s (%llu pkts, %llu drops)  tx %.1f Mbit/s (%llu pkts, %llu drops)  flow-off %llu ms",
                         s.config.name, u.name, mbps(\.rxBytes), cur.rxPackets ?? 0, cur.rxDrops ?? 0,
                         mbps(\.txBytes), cur.txPackets ?? 0, cur.txDrops ?? 0, cur.flowDisabledMs ?? 0))
        }
        if let g = stats[0] {
            print("usb   " + g.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        }
        lastStatsTime = now
    }
}

var timers: [DispatchSourceTimer] = []

// Runs `body` on the main queue every `interval` seconds (kept until exit).
func every(_ interval: Double, _ body: @escaping () -> Void) {
    let t = DispatchSource.makeTimerSource(queue: .main)
    t.schedule(deadline: .now() + interval, repeating: interval)
    t.setEventHandler(handler: body)
    t.resume()
    timers.append(t)
}

func run(_ o: RunOptions) -> Never {
    guard geteuid() == 0 || o.dryRun else { fail("run needs root (utun, ifconfig, route): sudo qmictl run ... (or --dry-run)") }
    guard !o.pdns.isEmpty else { fail("run needs at least one --pdn") }
    let dev = openDevice(o.device)
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
        let (wda, g) = try dev.setDataFormat(flowControl: o.flowControl) { g in
            print("data format: link \(g.linkLayer.map(String.init) ?? "?") ul-agg \(g.uplinkAggregation.map(String.init) ?? "?") dl-agg \(g.downlinkAggregation.map(String.init) ?? "?") " +
                  "dl \(g.downlinkMaxDatagrams.map(String.init) ?? "?")x\(g.downlinkMaxSize.map(String.init) ?? "?") " +
                  "ul \(g.uplinkMaxDatagrams.map(String.init) ?? "?")x\(g.uplinkMaxSize.map(String.init) ?? "?") pad \(g.downlinkMinPadding.map(String.init) ?? "-") " +
                  "flow-control \(g.flowControl.map { $0 ? "on" : "off" } ?? "-")")
        }
        conn.wda = wda
        if o.dryRun {
            for cfg in o.pdns {
                let session = PDNSession(device: dev, config: cfg)
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
        try dev.startDatapath(g, batch: !o.noBatch) { print("utun batching off: \($0)") }

        if o.publish {
            let pub = try ServicePublisher(name: "qmictl")
            conn.publisher = pub
            try pub.publish([QMIDStoreKey.modem: QMIDStoreModem(
                state: "running", vendorID: Int(dev.modem.vendorID), productID: Int(dev.modem.productID),
                interface: Int(dev.modem.interfaceNumber)).dictionary])
        }
        for (i, cfg) in o.pdns.enumerated() {
            let session = PDNSession(device: dev, config: cfg)
            try session.connect()
            // From here the call is up: teardown() must see it whatever fails next.
            let utun: Utun
            do { utun = try Utun() } catch { session.disconnect(); throw error }
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
                var entries = ServicePublisher.entities(pdnName: cfg.name, interface: utun.name,
                                                        settings: session.merged, policy: policy)
                entries[QMIDStoreKey.pdn(cfg.name)] = ServicePublisher.pdnStatus(
                    name: cfg.name, interface: utun.name, config: cfg,
                    settings: session.merged, policy: policy).dictionary
                try pub.publish(entries)
                print("  published service \(ServicePublisher.serviceID(for: cfg.name)) (\(policy.rawValue))")
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
    if o.statsInterval > 0 { every(o.statsInterval) { conn.printStats() } }
    if o.fcTest > 0 {
        var disabled = false
        every(o.fcTest) {
            disabled.toggle()
            for (s, _) in conn.sessions { dev.modem.simulateFlowControl(disabled, mux: s.config.muxID) }
            print("fc-test: flow \(disabled ? "disabled" : "enabled") on every PDN (simulated)")
        }
    }
    if o.stallTest > 0 {
        every(o.stallTest) {
            dev.modem.simulateInStall()
            print("stall-test: bulk IN stall cleared (simulated)")
        }
    }
    print("connected; Ctrl-C to disconnect")
    withExtendedLifetime(sources) { dispatchMain() }
}

// MARK: - Through qmid (XPC)

// For the one-shot commands; its replies come on its own queue, so the main thread can wait.
let qmid = QMIDClient(queue: DispatchQueue(label: "qmictl.qmid"))

// One call to qmid, waited for; exits with its error. connect answers when the dial has ended
// (up to 60 s per family), hence the long timeout.
func ask<T>(_ call: (@escaping (Result<T, QMIDError>) -> Void) -> Void) -> T {
    switch qmid.sync(timeout: 150, call) {
    case .success(let v): return v
    case .failure(let e): fail(e.message)
    }
}

// The same, for a call that only succeeds or fails: "ok".
func perform(_ call: (@escaping (Result<Void, QMIDError>) -> Void) -> Void) {
    ask(call)
    print("ok")
}

// The same, where a failure only means there is nothing to show.
func tryAsk<T>(_ call: (@escaping (Result<T, QMIDError>) -> Void) -> Void) -> T? {
    try? qmid.sync(timeout: 150, call).get()
}

func daemonCommand(_ args: [String]) -> Bool {
    let persistent = args.contains("--persistent")
    switch args.first {
    case "status":
        // Everything read-only: state, then the cells, then the band preference.
        printStatus(ask { qmid.status($0) })
        if let r = tryAsk({ qmid.radio($0) }) { printRadio(r) }
        if let b = tryAsk({ qmid.bandPreference($0) }) { printBands(b) }
    case "connect" where args.count == 2:
        perform { qmid.connect(pdn: args[1], $0) }
    case "disconnect" where args.count == 2:
        perform { qmid.disconnect(pdn: args[1], $0) }
    case "policy" where args.count == 3:
        perform { qmid.setPolicy(pdn: args[1], policy: args[2], $0) }
    case "restart":
        perform { qmid.restart($0) }
    case "reload":
        perform { qmid.reload($0) }
    case "config" where args.count == 2 && args[1] == "get":
        FileHandle.standardOutput.write(ask { qmid.getConfig($0) })
        print()
    case "config" where args.count == 3 && args[1] == "set":
        guard let data = FileManager.default.contents(atPath: args[2]) else { fail("can't read \(args[2])") }
        perform { qmid.setConfig(data, $0) }
    case "events":
        streamEvents()
    case "log":
        var a = Args(Array(args.dropFirst()))
        streamLog(&a)
    case "sync":
        printProfileReport(ask { qmid.profiles($0) })
    case "prepare-sim" where args.count >= 2:
        var a = Args(Array(args.dropFirst()))
        prepareSIM(&a)
    case "cancel-sim" where args.count == 2:
        perform { qmid.cancelSIM(iccid: args[1], $0) }
    case "radio" where args.count >= 2 && args[1] == "watch":
        radioWatch(verbose: args.contains("-v"))
    case "radio" where args.count <= 2:
        printRadio(ask { qmid.radio(raw: args.last == "-v", $0) })
    case "airplane" where args.count == 2 && ["on", "off"].contains(args[1]):
        perform { qmid.setAirplaneMode(args[1] == "on", $0) }
    case "restart-modem":
        perform { qmid.restartModem($0) }
    case "bands" where args.count >= 2 && args[1] == "set":
        var lists: [String: [Int]] = [:]
        var i = 2
        while i < args.count {
            if args[i] == "--persistent" { i += 1; continue }
            guard ["lte", "nsa", "sa"].contains(args[i]) else { fail("bands set: unknown \(args[i]) (lte, nsa, sa)") }
            guard i + 1 < args.count else { fail("bands set: \(args[i]) needs a list, e.g. 1,3") }
            lists[args[i]] = args[i + 1].split(separator: ",").compactMap { Int($0) }
            i += 2
        }
        perform { qmid.setBandPreference(lte: lists["lte"], nrNSA: lists["nsa"], nrSA: lists["sa"], persistent: persistent, $0) }
    case "bands" where args.count >= 2 && args[1] == "reset":
        perform { qmid.resetBandPreference(persistent: persistent, $0) }
    case "bands":
        printBands(ask { qmid.bandPreference($0) })
    case "modes" where args.count >= 3 && args[1] == "set":
        perform { qmid.setModePreference(args[2].split(separator: ",").map(String.init), persistent: persistent, $0) }
    case "modes" where args.count >= 2 && args[1] == "reset":
        perform { qmid.resetModePreference(persistent: persistent, $0) }
    case "sharing" where args.count == 1:
        if let s = ask({ qmid.status($0) }).sharing { printSharing(s) } else {
            print("sharing: not configured (qmid.json \"sharing\": { \"pdn\": \"internet\" })")
        }
    case "gnss" where args.count >= 2 && args[1] == "watch":
        var a = Args(Array(args.dropFirst(2)))
        gnssWatch(&a)
    case "gnss" where args.count == 1:
        printGNSS(ask { qmid.gnss($0) })
        if let x = tryAsk({ qmid.xtra($0) }) { printXTRA(x) }
    case "xtra" where args.count == 3 && args[1] == "load":
        guard let data = FileManager.default.contents(atPath: args[2]) else { fail("cannot read \(args[2])") }
        let x = ask { qmid.loadXTRA(data, $0) }
        print("loaded \(data.count) bytes")
        printXTRA(x)
    case "xtra" where args.count == 1:
        printXTRA(ask { qmid.xtra($0) })
    default:
        return false
    }
    return true
}

// The prepare lasts while this connection does, so qmictl stays until Ctrl-C or --hold runs out.
func prepareSIM(_ args: inout Args) -> Never {
    var hold: Double?
    var rest: [String] = []
    while let a = args.next() {
        if a == "--hold" { hold = args.number(a) } else if a.hasPrefix("-") || rest.count == 2 { args.reject(a) } else { rest.append(a) }
    }
    guard let iccid = rest.first else { fail("prepare-sim ICCID [MCCMNC] [--hold SECONDS]") }
    let p = ask { qmid.prepareSIM(iccid: iccid, mccmnc: rest.count == 2 ? rest[1] : nil, $0) }
    print("prepared: attach apn \"\(p.apn)\"\(p.carrier.map { ", carrier \($0)" } ?? "")\(p.matchedBy.map { " by \($0)" } ?? "")")
    print(hold.map { "holding \(Int($0)) s" } ?? "switch SIMs now; Ctrl-C ends the prepare")
    if let hold { DispatchQueue.main.asyncAfter(deadline: .now() + hold) { qmid.invalidate(); exit(0) } }
    dispatchMain()
}

func printProfileReport(_ r: QMIDProfileReport) {
    if let s = r.sim {
        print("sim: \(s)\(r.carrier.map { ", carrier \($0)" } ?? "")\(r.attachAPN.map { ", default bearer apn \($0)" } ?? "")\(r.pending.map { ", prepared for SIM \($0)" } ?? "")")
    }
    for p in r.pdns {
        print("\(p.pdn): profile \(p.profile.map(String.init) ?? "-")\(p.attach ? " (attach)" : ""): \(p.action)")
        if let st = p.settings { print("  \(st)") }
    }
    if let e = r.error { print("sync error: \(e)") }
    if !r.learned.isEmpty {
        print("default bearer apns seen (home mccmnc: apn):")
        r.learned.forEach { print("  \($0)") }
    }
    if let m = r.modemProfiles {
        print("modem profiles:")
        m.forEach { print("  \($0)") }
    }
    if let a = r.autoconnect { print("modem autoconnect: \(a)") }
    if let a = r.attachProfile { print("lte attach profile: \(a)") }
}

// MARK: - Formatting

func printStatus(_ st: QMIDStatus) {
    if let v = st.version { print("qmid: \(v)") }
    print("modem: " + describe(QMIDModem(state: st.modem, network: st.network, error: st.modemError, airplaneMode: st.airplaneMode)))
    if let s = st.sim {
        print("sim: \(describe(s))")
        let ids = [s.iccid.map { "iccid \($0)" }, s.imsi.map { "imsi \($0)" }, s.msisdn.map { "msisdn \($0)" }].compactMap { $0 }
        if !ids.isEmpty { print("  " + ids.joined(separator: ", ")) }
    }
    if let i = st.imei { print("imei: \(i)") }
    if let p = st.plmn { print("operator: \(describe(p))") }
    if let g = st.gnss, g.running || g.engine == "on" { printGNSS(g) }
    if let s = st.sharing { printSharing(s) }
    for p in st.pdns { describe(p).forEach { print($0) } }
    if let g = st.datapath {
        print("datapath: " + g.values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
    }
}

// "ready (error), registered, ps attached, lte, airplane mode"
func describe(_ m: QMIDModem) -> String {
    "\(m.state)\(m.error.map { " (\($0))" } ?? "")\(m.network.map { ", \($0)" } ?? "")\(m.airplaneMode ? ", airplane mode" : "")"
}

// A PDN as lines (status, and pdn events): state, then addresses, QoS, bearers, counters, errors.
func describe(_ q: QMIDPDN) -> [String] {
    var line = "\(q.name): \(q.stateName)"
    if let i = q.interface { line += " on \(i)" }
    line += ", \(q.policy ?? "?")"
    if let u = q.uptime { line += ", up \(u) s" }
    if let r = q.rat { line += ", on \(r)" }
    if !q.wanted { line += ", manual" }
    var out = [line]
    func add(_ s: String) { out.append("  " + s) }
    if let a = q.ipv4 { add("ipv4 \(a)") }
    if let a = q.ipv6 { add("ipv6 \(a)") }
    if !q.pcscf.isEmpty { add("p-cscf \(q.pcscf.joined(separator: " "))") }
    if q.qci != nil || q.ambr != nil { add("qci \(q.qci.map(String.init) ?? "?"), ambr \(q.ambr.map(describe) ?? "?")") }
    for b in q.bearers ?? [] { describe(b).forEach(add) }
    if let c = q.counters {
        add("rx \(c.rxPackets ?? 0) pkts/\(c.rxBytes ?? 0) B, tx \(c.txPackets ?? 0) pkts/\(c.txBytes ?? 0) B, drops rx \(c.rxDrops ?? 0)/tx \(c.txDrops ?? 0)")
    }
    if let e = q.error { add("last error: \(e)\(q.reason.map { " [\($0.rawValue)]" } ?? "")") }
    if !q.causes.isEmpty {
        add("causes: " + q.causes.map { c in
            [c.family.map { "ipv\($0)" }, "\(c.type) \(c.code.map(String.init) ?? "?")"].compactMap { $0 }.joined(separator: " ")
        }.joined(separator: ", "))
    }
    if !q.blocked.isEmpty {
        // "ipv4: X", "ipv6: X" → "X" when every family is blocked for the same reason.
        let reasons = Set(q.blocked.map { $0.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? $0 })
        if q.blocked.count > 1, reasons.count == 1, let r = reasons.first { add("blocked: \(r)") }
        else { add("blocked: \(q.blocked.joined(separator: "; "))") }
    }
    return out
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
    if let p = s.pendingSIM { line += ", prepared for SIM \(p)" }
    if let c = s.card, c != .present { line += ", card \(c.rawValue)" }
    if let p = s.pin { line += ", pin \(p.rawValue)\(s.pinRetries.map { " (\($0) tries left)" } ?? "")" }
    return line
}

func describe(_ p: QMIDPLMN) -> String {
    guard p.displayName != nil else { return "no name" }
    var s = "\(p.longName ?? "-") / \(p.shortName ?? "-")\(p.nameFromNetwork ? " (network)" : "")"
    if let b = p.emergencyBearers { s += ", emergency bearers \(b ? "yes" : "no")" }
    if p.emergencyAccessBarred == true { s += ", emergency access barred" }
    if let r = p.roaming { s += r ? ", roaming" : ", home" }
    return s
}

func printSharing(_ s: QMIDSharing) {
    let to = s.sharedTo.isEmpty ? "" : " to \(s.sharedTo.joined(separator: ", "))"
    switch s.stateKind {
    case .on?:
        print("sharing: on, \(s.pdn) (\(s.interface ?? "?"))\(to) via \(s.bridge ?? "?"), \(s.clients) client\(s.clients == 1 ? "" : "s")")
    case .waiting?: print("sharing: waiting for \(s.pdn)\(to)")
    case .off?: print("sharing: off (Internet Sharing is turned off)")
    case .notSelected?: print("sharing: Internet Sharing doesn't use \"Cellular (\(s.pdn))\" as its source")
    case nil: print("sharing: \(s.stateName), \(s.pdn)\(to)")
    }
}

// "45 s", "12 min", "3 h 20 min"
func span(_ t: TimeInterval) -> String {
    let s = Int(t)
    return s < 120 ? "\(s) s" : s < 3600 ? "\(s / 60) min" : "\(s / 3600) h \(s % 3600 / 60) min"
}

func ago(_ d: Date) -> String { span(-d.timeIntervalSinceNow) + " ago" }

func printGNSS(_ g: QMIDGNSS) {
    var line = "gnss: engine \(g.engine), session \(g.running ? "running (\(g.interval ?? 0) ms)" : "idle")"
    line += ", \(g.clients) client\(g.clients == 1 ? "" : "s")"
    if let f = g.lastFix { line += ", last fix \(ago(f))" }
    print(line)
    if let a = g.assist {
        var s = "  start position: \(a.result.rawValue) \(ago(a.time))"
        if let srv = a.server { s += " from \(a.source.uppercased()) \(srv)" }
        if let u = a.uncertainty { s += String(format: ", ±%.0f m", u) }
        if let d = a.duration { s += String(format: ", server %.2f s", d) }
        if let c = a.cell { s += ", cell \(c)" }
        print(s)
        if let after = a.firstFixAfter {
            print(String(format: "    first fix %.1f s after start%@", after,
                         a.firstFixDistance.map { String(format: ", %.0f m from the starting position", $0) } ?? ""))
        }
        if let e = a.error { print("    \(e)") }
    }
}

func printXTRA(_ x: QMIDXTRA) {
    guard x.supported else { return print("xtra: not supported by this modem") }
    if let from = x.validFrom, let hours = x.validHours, let expires = x.expires {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        f.timeZone = TimeZone(identifier: "UTC")
        let left = expires.timeIntervalSinceNow
        print("xtra: valid from \(f.string(from: from)) for \(hours) h, " + (left > 0 ? "\(span(left)) left" : "expired"))
    } else {
        print("xtra: no data")
    }
    if let a = x.age() { print("  age \(span(a))") }
    var auto = "  updates by qmid: \(x.autoUpdate ? "on" : "off")"
    if let d = x.lastDownload { auto += ", last \(ago(d))" }
    if let n = x.nextCheck { auto += ", next check in \(max(0, Int(n.timeIntervalSinceNow / 60))) min" }
    print(auto)
    if let e = x.lastError { print("  last error: \(e)") }
    for s in x.servers { print("  server \(s)") }
}

func printBands(_ b: QMIDBandPreference) {
    func list(_ l: [Int], _ p: String) -> String { l.isEmpty ? "-" : l.map { "\(p)\($0)" }.joined(separator: " ") }
    print("allowed modes: \(b.modes.isEmpty ? "-" : b.modes.joined(separator: " "))")
    print("allowed lte:    \(list(b.lteBands, "B"))")
    print("allowed nr nsa: \(list(b.nrNSABands, "n"))")
    print("allowed nr sa:  \(list(b.nrSABands, "n"))")
    if !b.supportedModes.isEmpty { print("supported modes: \(b.supportedModes.joined(separator: " "))") }
    if !b.supportedLTEBands.isEmpty { print("supported lte:  \(list(b.supportedLTEBands, "B"))") }
    if !b.supportedNRBands.isEmpty { print("supported nr:   \(list(b.supportedNRBands, "n"))") }
}

// PCell, SCell n (LTE carrier aggregation), PSCell (the NR leg of EN-DC; the PCell on SA),
// SCell (NR carrier aggregation); a role or technology this version doesn't know by its name.
func cellRole(_ c: QMIDCell) -> String {
    switch (c.ratKind, c.roleKind) {
    case (_, .primary?): return "pcell"
    case (.lte?, .secondary?): return "scell\(c.scellIndex.map { " \($0)" } ?? "")"
    case (.nr?, .secondary?): return c.pscell == true ? "pscell" : "scell"
    case (_, .neighbor?): return "neighbour"
    default: return c.roleName
    }
}

// "B3", "n41"
func bandName(_ c: QMIDCell) -> String? {
    c.band.map { (c.ratKind == .lte ? "B" : c.ratKind == .nr ? "n" : "\(c.ratName) ") + "\($0)" }
}

func printRadio(_ r: QMIDRadio, neighbours: Bool = true) {
    func f(_ v: Double?, _ unit: String = "") -> String? { v.map { String(format: $0 == $0.rounded() ? "%.0f" : "%.1f", $0) + unit } }
    func line(_ c: QMIDCell) -> String {
        let lte = c.ratKind == .lte
        var parts: [String] = [c.ratName.padding(toLength: 4, withPad: " ", startingAt: 0)
                               + cellRole(c).padding(toLength: 10, withPad: " ", startingAt: 0)]
        parts.append(bandName(c) ?? "band ?")
        if let ch = c.channel { parts.append("\(lte ? "earfcn" : "arfcn") \(ch)") }
        if let bw = f(c.bandwidth, " MHz") { parts.append(bw) }
        if let p = c.pci { parts.append("pci \(p)") }
        if let id = c.cellID {
            parts.append(lte ? String(format: "cell %llu (eNB %llu/%llu)", id, id >> 8, id & 0xff) : String(format: "cell %llu", id))
        }
        if let t = c.tac { parts.append("tac \(t)") }
        if let a = c.active { parts.append(a ? "active" : "configured") }
        for (name, v, unit) in [("rsrp", c.rsrp, " dBm"), ("rsrq", c.rsrq, " dB"), ("rssi", c.rssi, " dBm"), ("snr", c.snr, " dB")] {
            if let s = f(v, unit) { parts.append("\(name) \(s)") }
        }
        return parts.joined(separator: "  ")
    }
    // Summary: "pcell B3 + scell B1 (configured) + pscell n41 + scell n1, 3 neighbours".
    func name(_ c: QMIDCell) -> String {
        "\(cellRole(c).split(separator: " ").first ?? "") \(bandName(c) ?? "?")" + (c.active.map { $0 ? "" : " (configured)" } ?? "")
    }
    print("cells: " + (r.serving.isEmpty ? "none" : r.serving.map(name).joined(separator: " + "))
          + ", \(r.neighbors.count) neighbours"
          + (r.endcAvailable == true && !r.serving.contains { $0.ratKind == .nr } ? ", en-dc available" : "")
          + (r.lteRRC == nil && r.nrRRC == nil ? ""
             : "; rrc " + [r.lteRRC.map { "lte \($0.rawValue)" }, r.nrRRC.map { "nr \($0.rawValue)" }].compactMap { $0 }.joined(separator: ", ")))
    r.serving.forEach { print(line($0)) }
    if neighbours, !r.neighbors.isEmpty {
        print("neighbours:")
        r.neighbors.forEach { print("  " + line($0)) }
    }
    if let raw = r.raw { print("raw:"); raw.forEach { print("  " + $0) } }
}

// MARK: - Streams (QMIDClient on the main queue, as any client app would; they also show
// reconnects after qmid restarts)

let hms: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

func now() -> String { hms.string(from: Date()) }

func streamClient() -> QMIDClient {
    let client = QMIDClient(queue: .main)
    client.onAvailabilityChange = { print("\(now()) qmid \($0 ? "available" : "unavailable")") }
    return client
}

func streamEvents() -> Never {
    let client = streamClient()
    client.onModem = { print("\(now()) modem \(describe($0))") }
    client.onGNSS = { g in print("\(now()) ", terminator: ""); printGNSS(g) }
    client.onSharing = { s in print("\(now()) ", terminator: ""); printSharing(s) }
    client.onSIM = { s in print("\(now()) sim \(s.map(describe) ?? "none")") }
    client.onPLMN = { p in print("\(now()) operator \(p.map(describe) ?? "none")") }
    client.onBearers = { pdn, bearers in
        print("\(now()) bearers \(pdn): \(bearers.isEmpty ? "none" : "\(bearers.count)")")
        for b in bearers { describe(b).forEach { print("  " + $0) } }
    }
    // Types with a callback of their own (above) are printed there.
    let handled: Set<String> = [QMIDEventType.sim, QMIDEventType.plmn, QMIDEventType.bearers,
                                QMIDEventType.gnss, QMIDEventType.sharing]
    client.onEvent = { e in
        switch e {
        case .pdn(let p):
            let lines = describe(p)
            print("\(now()) pdn \(lines[0])")
            lines.dropFirst().forEach { print($0) }
        case .config: print("\(now()) config changed")
        case .unknown(let type) where !handled.contains(type): print("\(now()) event \(type)")
        case .modem, .unknown: break
        }
    }
    client.subscribe()
    withExtendedLifetime(client) { dispatchMain() }
}

// qmid's log over XPC: recent history, then live. Falls back to `log stream` (macOS keeps only
// notice/error on disk) when qmid can't be reached.
func streamLog(_ args: inout Args) -> Never {
    var level = QMIDLogLevel.info
    var history = true
    while let a = args.next() {
        switch a {
        case "--level":
            let v = args.value(a)
            guard let l = QMIDLogLevel(name: v) else { fail("bad level \(v) (debug, info, notice, error)") }
            level = l
        case "--no-history": history = false
        default: args.reject(a)
        }
    }
    let ms = DateFormatter()
    ms.dateFormat = "HH:mm:ss.SSS"
    let client = QMIDClient(queue: .main)
    client.onLog = { e in
        print("\(ms.string(from: e.time)) \(e.level.name.prefix(1).uppercased()) \(e.category == "qmid" ? "" : "[\(e.category)] ")\(e.message)")
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

// Starts location through qmid and prints what comes; Ctrl-C (or --for) ends it, and qmid
// stops the session when this connection closes.
func gnssWatch(_ args: inout Args) -> Never {
    var sats = false, nmea = false, verbose = false
    var interval: TimeInterval = 1, duration: TimeInterval?
    while let a = args.next() {
        switch a {
        case "--sats": sats = true
        case "--nmea": nmea = true
        case "-v": verbose = true; sats = true
        case "--interval": interval = args.number(a)
        case "--for": duration = args.number(a)
        default: args.reject(a)
        }
    }
    let utc = DateFormatter()
    utc.dateFormat = "HH:mm:ss.SSS"
    utc.timeZone = TimeZone(identifier: "UTC")
    let started = Date()
    var first = true
    let client = streamClient()
    client.onGNSS = { printGNSS($0) }
    client.onLocation = { l in
        var s = "\(now()) \(l.fixName)"
        if let la = l.latitude, let lo = l.longitude { s += String(format: " %.6f, %.6f", la, lo) }
        if let h = l.horizontalAccuracy { s += String(format: " ±%.0f m", h) }
        if let alt = l.altitudeMSL ?? l.altitude { s += String(format: ", alt %.0f m", alt) }
        if let v = l.speed, v > 0.5 { s += String(format: ", %.1f m/s", v) }
        if let h = l.heading { s += String(format: ", heading %.0f°", h) }
        if let n = l.satellitesUsed { s += ", \(n) satellites" }
        if !l.technology.isEmpty { s += " [\(l.technology.joined(separator: ","))]" }
        if let t = l.time { s += " utc \(utc.string(from: t))" }
        if first, l.fix == .fix {
            first = false
            s += String(format: "  (first fix after %.1f s)", Date().timeIntervalSince(started))
        }
        print(s)
    }
    client.onSatellites = { s in
        let parts = s.summary.map { "\($0.system) \($0.tracking)" + ($0.used > 0 ? "/\($0.used) used" : "") }
        print("\(hms.string(from: s.time)) satellites: tracking " + (parts.isEmpty ? "none" : parts.joined(separator: ", "))
              + ", searching \(s.satellites.count - s.tracking.count)")
        guard verbose else { return }
        for x in s.tracking.sorted(by: { ($0.system, $0.id) < ($1.system, $1.id) }) {
            print(String(format: "    %-7@ %3d %-4@ el %4.0f° az %4.0f° C/N0 %4.1f%@", x.system, x.id, x.signal ?? "?",
                         x.elevation ?? .nan, x.azimuth ?? .nan, x.cn0 ?? .nan, x.used ? "  used" : ""))
        }
    }
    client.onNMEA = { print($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    client.subscribe()
    client.startLocation(interval: interval, satellites: sats, nmea: nmea) { r in
        if case .failure(let e) = r { fail("startLocation: \(e)") }
    }
    if let duration {
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            client.stopLocation { _ in exit(0) }
        }
    }
    withExtendedLifetime(client) { dispatchMain() }
}

// Radio events: one block per change (serving cells, activation, EN-DC, RRC); -v: neighbours too.
func radioWatch(verbose: Bool) -> Never {
    let client = streamClient()
    client.onRadio = { r in
        print("--- \(now())")
        guard let r else { return print("radio: modem not ready") }
        printRadio(r, neighbours: verbose)
    }
    client.subscribe()
    withExtendedLifetime(client) { dispatchMain() }
}

// MARK: - main

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else { print(usage); exit(2) }
if command == "-h" || command == "--help" { print(usage); exit(0) }
if daemonCommand(argv) { exit(0) }

var rest = Args(Array(argv.dropFirst()))
switch command {
case "probe": probe(.parse(&rest))
case "modem-status": modemStatus(.parse(&rest))
case "profiles": profiles(.parse(&rest))
case "plmn-name": plmnName(.parse(&rest))
case "nas-survey": nasSurvey(.parse(&rest))
case "ambr-survey": ambrSurvey(.parse(&rest))
case "reattach": reattach(.parse(&rest))
case "profile-write": profileWrite(&rest)
case "loc-survey": locSurvey(&rest)
case "loc-inject": locInject(&rest)
case "loc-fix": locFix(&rest)
case "run": run(.parse(&rest))
default: print(usage); exit(2)
}
