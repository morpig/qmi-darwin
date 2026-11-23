import Foundation
import QMIHost
import QMIKit

// Direct-mode LOC probes (stop qmid first): what the modem's LOC service answers, beyond what
// qmid uses (docs/QMI-loc.md). LOC answers a request with an indication of the same message ID;
// the probes print the response, then that indication, with their timing. They keep every LOC
// indication in an inbox instead of using QMIClient.requestIndication, which hides the response
// and keeps reply indications from onIndication (--listen and --log show them all).

// Every LOC indication, in arrival order; waiters look for one newer than their mark.
private final class LOCInbox {
    private let cond = NSCondition()
    private var items: [(at: Date, msg: QMIMessage)] = []
    var printAll = false
    let start = Date()

    func add(_ m: QMIMessage) {
        cond.lock()
        items.append((Date(), m))
        cond.broadcast()
        cond.unlock()
        if printAll { print(Self.describe(m, at: Date().timeIntervalSince(start))) }
    }

    var mark: Int { cond.lock(); defer { cond.unlock() }; return items.count }

    func wait(_ message: UInt16, after mark: Int, timeout: TimeInterval,
              where match: (QMIMessage) -> Bool = { _ in true }) -> (QMIMessage, Date)? {
        let deadline = Date().addingTimeInterval(timeout)
        cond.lock()
        defer { cond.unlock() }
        var seen = mark
        while true {
            while seen < items.count {
                let it = items[seen]
                seen += 1
                if it.msg.messageID == message, match(it.msg) { return (it.msg, it.at) }
            }
            guard cond.wait(until: deadline) else { return nil }
        }
    }

    // "  [  1.234 s] ind 0x0037 status 0 (success)", then the other TLVs.
    static func describe(_ m: QMIMessage, at t: TimeInterval) -> String {
        var s = String(format: "  [%7.3f s] ind 0x%04x", t, m.messageID)
        if let st = LOC.indicationStatus(m) { s += " status \(st.rawValue) (\(st))" }
        for tlv in m.tlvs where tlv.type != 0x01 { s += "\n      " + tlv.dump }
        return s
    }
}

private func openLOC(_ o: DeviceOptions) -> (QMIDevice, QMIClient, LOCInbox) {
    let dev = openDevice(o)
    let inbox = LOCInbox()
    dev.onIndication = { m in if m.service == .loc { inbox.add(m) } }
    if let v = try? dev.versions().first(where: { $0.service == .loc }) {
        print("LOC service version \(v.major).\(v.minor)")
    } else {
        print("LOC: not in the service list")
    }
    do {
        let c = try dev.allocateClient(.loc)
        print("LOC client \(c.id)")
        return (dev, c, inbox)
    } catch {
        fail("LOC client: \(error)")
    }
}

// Request, its response, then the indication with the same message ID (up to `wait` s).
@discardableResult
private func call(_ c: QMIClient, _ inbox: LOCInbox, _ id: UInt16, _ name: String, _ tlvs: [TLV] = [],
                  wait: TimeInterval = 5, quiet: Bool = false) -> QMIMessage? {
    let mark = inbox.mark
    let sent = Date()
    if !quiet { print(String(format: "0x%04x %@:", id, name)) }
    do {
        let r = try c.request(id, tlvs, timeout: 5)
        if !quiet {
            print(String(format: "  response ok after %.0f ms", Date().timeIntervalSince(sent) * 1000))
            r.tlvDump(prefix: "  resp ").forEach { print($0) }
        }
    } catch {
        print(String(format: "0x%04x %@: response: \(error)", id, name))
        return nil
    }
    guard wait > 0 else { return nil }
    guard let (ind, at) = inbox.wait(id, after: mark, timeout: wait) else {
        print(String(format: "  no indication within %.0f s", wait))
        return nil
    }
    if !quiet {
        print(String(format: "  indication after %.0f ms", at.timeIntervalSince(sent) * 1000)
              + LOCInbox.describe(ind, at: at.timeIntervalSince(inbox.start)).dropFirst(2))
    }
    return ind
}

// Get Predicted Orbits Data Source: part sizes and servers.
@discardableResult
private func showSource(_ c: QMIClient, _ inbox: LOCInbox) -> LOC.XTRASource? {
    guard let ind = call(c, inbox, LOC.getPredictedOrbitsDataSource, "Get Predicted Orbits Data Source") else { return nil }
    let s = LOC.parseSource(ind)
    if let file = s.maxFileSize, let part = s.maxPartSize { print("  max file size \(file), max part size \(part)") }
    for (i, url) in s.servers.enumerated() { print("  server \(i + 1): \(url)") }
    return s
}

// Get Predicted Orbits Data Validity: "from 2026-01-01T00:00:00Z, 168 h, 150 h left".
private func validity(_ c: QMIClient, _ inbox: LOCInbox, _ name: String, quiet: Bool = false) -> String {
    guard let ind = call(c, inbox, LOC.getPredictedOrbitsDataValidity, name, quiet: quiet) else { return "no answer" }
    guard let v = LOC.parseValidity(ind) else { return "no data" }
    return "from \(ISO8601DateFormatter().string(from: v.start)), \(v.hours) h, \(Int(v.expires.timeIntervalSinceNow / 3600)) h left"
}

// "TT<sep>HEX": a TLV given by hand.
private func handTLV(_ s: Substring, _ separator: Character) -> TLV? {
    let p = s.split(separator: separator, maxSplits: 1)
    guard p.count == 2, let t = UInt8(p[0], radix: 16), let v = [UInt8](hex: String(p[1])) else { return nil }
    return TLV(t, v)
}

func locSurvey(_ args: inout Args) {
    var o = DeviceOptions()
    var register: UInt64?
    var regExtra: [TLV] = []                 // --reg-tlv TYPE:HEX, appended to Register Events
    var listen: TimeInterval = 0
    var supl = false
    var extra: [(UInt16, [TLV])] = []        // --call ID[:TT=HEX,...], read-only queries by hand
    while let a = args.next() {
        if o.take(a, &args) { continue }
        switch a {
        case "--supl": supl = true
        case "--call":
            let spec = args.value(a)
            let parts = spec.split(separator: ":", maxSplits: 1)
            guard let first = parts.first, let id = UInt16(first.lowercased().replacingOccurrences(of: "0x", with: ""), radix: 16)
            else { fail("bad --call \(spec): ID[:TT=HEX,...]") }
            let pairs = (parts.count > 1 ? parts[1] : "").split(separator: ",")
            let tlvs = pairs.compactMap { handTLV($0, "=") }
            guard tlvs.count == pairs.count else { fail("bad --call \(spec): ID[:TT=HEX,...]") }
            extra.append((id, tlvs))
        case "--register": register = args.hex(a)
        case "--reg-tlv":
            let spec = args.value(a)
            guard let tlv = handTLV(Substring(spec), ":") else { fail("bad --reg-tlv \(spec): TYPE:HEX") }
            regExtra.append(tlv)
        case "--listen": listen = args.number(a)
        default: args.reject(a)
        }
    }
    let (dev, c, inbox) = openLOC(o)
    defer { c.release(); dev.close() }

    do {
        if let ids = try supportedMessages(c, timeout: 3) {
            print(String(format: "0x001e Get Supported Messages: %d IDs, 0x%04x–0x%04x", ids.count, ids.first ?? 0, ids.last ?? 0))
        } else {
            print("0x001e Get Supported Messages: no TLV 0x10")
        }
    } catch {
        print("0x001e Get Supported Messages: \(error)")
    }

    if let m = register {
        // Only the mask: the client type (0x11) the RM551E wants comes with --reg-tlv, if wanted.
        call(c, inbox, LOC.registerEvents, String(format: "Register Events 0x%llx", m),
             LOC.registerEventsRequest(m).filter { $0.type == 0x01 } + regExtra, wait: 0)
    } else {
        print("(no Register Events sent)")
    }

    showSource(c, inbox)
    print("  validity: " + validity(c, inbox, "Get Predicted Orbits Data Validity"))
    call(c, inbox, 0x004B, "Get Operation Mode")
    call(c, inbox, 0x003B, "Get Engine Lock")
    call(c, inbox, 0x003F, "Get NMEA Types")
    if supl {
        // Get Server: TLV 0x01 server type (1 CDMA PDE, 2 CDMA MPC, 3 UMTS SLP, 4 custom PDE),
        // 0x10 address types wanted (1 IPv4, 2 IPv6, 4 URL).
        for (type, name) in [(UInt32(3), "UMTS SLP"), (1, "CDMA PDE"), (4, "custom PDE")] {
            call(c, inbox, 0x0043, "Get Server (\(name))", [.u32(0x01, type), .u8(0x10, 7)])
        }
        // Get Protocol Config Parameters: TLV 0x01 u64 mask of what to read.
        var w = ByteWriter()
        w.u64(0xffff)
        call(c, inbox, 0x0055, "Get Protocol Config Parameters", [TLV(0x01, w.bytes)])
    }
    for (id, tlvs) in extra { call(c, inbox, id, "by hand", tlvs) }

    if listen > 0 {
        print("listening \(Int(listen)) s for LOC indications…")
        inbox.printAll = true
        Thread.sleep(forTimeInterval: listen)
        inbox.printAll = false
    }
}

func locInject(_ args: inout Args) {
    var o = DeviceOptions()
    var file: String?
    var message = LOC.injectPredictedOrbitsData
    var partSize: Int?
    var stopAfter: Int?
    var listen: TimeInterval = 0
    var partTimeout: TimeInterval = 10
    while let a = args.next() {
        if o.take(a, &args) { continue }
        switch a {
        case "--msg": message = args.value(a) == "a7" ? LOC.injectXTRAData : LOC.injectPredictedOrbitsData
        case "--part-size": partSize = args.int(a)
        case "--stop-after": stopAfter = args.int(a)
        case "--listen": listen = args.number(a)
        case "--part-timeout": partTimeout = args.number(a)
        default:
            guard file == nil, !a.hasPrefix("-") else { args.reject(a) }
            file = a
        }
    }
    guard let file, let data = FileManager.default.contents(atPath: file) else { fail("cannot read \(file ?? "FILE")") }
    let (dev, c, inbox) = openLOC(o)
    defer { c.release(); dev.close() }

    let source = showSource(c, inbox)
    print("  validity: " + validity(c, inbox, "Get Predicted Orbits Data Validity (before)"))
    let part = max(1, min(partSize ?? source?.maxPartSize ?? LOC.maxPartSize, LOC.maxPartSize))
    let requests = LOC.injectRequests([UInt8](data), message: message, partSize: part)
    let total = requests.count
    print(String(format: "injecting %d bytes in %d parts of %d with 0x%04x", data.count, total, part, message))

    let started = Date()
    var slowest: TimeInterval = 0
    for (i, tlvs) in requests.enumerated() {
        if let s = stopAfter, i >= s { print("stopped after \(s) parts"); break }
        let mark = inbox.mark
        let t0 = Date()
        do {
            try c.request(message, tlvs, timeout: 5)
        } catch {
            print("part \(i + 1)/\(total): response: \(error)")
            break
        }
        // An indication without a part number counts as this part's.
        guard let (ind, at) = inbox.wait(message, after: mark, timeout: partTimeout,
                                         where: { LOC.injectedPart($0).map { $0 == i + 1 } ?? true }) else {
            print("part \(i + 1)/\(total): no indication within \(Int(partTimeout)) s")
            break
        }
        let dt = at.timeIntervalSince(t0)
        slowest = max(slowest, dt)
        let ok = LOC.indicationStatus(ind) == .success
        if !ok || i == 0 || i == total - 1 || o.verbose {
            print(String(format: "part %d/%d: %.0f ms,", i + 1, total, dt * 1000)
                  + LOCInbox.describe(ind, at: at.timeIntervalSince(inbox.start)).dropFirst(2))
        }
        if !ok { break }
    }
    print(String(format: "inject: %.1f s total, slowest part %.0f ms", Date().timeIntervalSince(started), slowest * 1000))
    Thread.sleep(forTimeInterval: 1)
    print("  validity: " + validity(c, inbox, "Get Predicted Orbits Data Validity (after)"))
    if listen > 0 {
        print("listening \(Int(listen)) s…")
        inbox.printAll = true
        Thread.sleep(forTimeInterval: listen)
    }
}

// A periodic 1 Hz session: satellite summaries, engine/session state, fixes, time to first fix.
// On screen, coordinates are rounded to 0.01°; --log gets the full indications.
func locFix(_ args: inout Args) {
    let defaultMask: LOC.EventMask = [.position, .satellites, .engineState, .fixSessionState]
    var o = DeviceOptions()
    var timeout: TimeInterval = 600
    var afterFix: TimeInterval = 15
    var logPath: String?
    var noRegister = false                  // check: does a session report without Register Events?
    var releaseAfter: TimeInterval?         // check: release the client without Stop; watch engine state on a 2nd client
    var noStop = false
    var mask = defaultMask.rawValue
    var injectFile: String?                 // "lat lon uncertainty_m": Inject Position before Start
    while let a = args.next() {
        if o.take(a, &args) { continue }
        switch a {
        case "--no-register": noRegister = true
        case "--release-test": releaseAfter = args.number(a)
        case "--no-stop": noStop = true
        case "--mask": mask = args.hex(a)
        case "--inject-file": injectFile = args.value(a)
        case "--timeout": timeout = args.number(a)
        case "--after-fix": afterFix = args.number(a)
        case "--log": logPath = args.value(a)
        default: args.reject(a)
        }
    }
    let log = logPath.flatMap { FileManager.default.createFile(atPath: $0, contents: nil) ? FileHandle(forWritingAtPath: $0) : nil }
    let (dev, c, inbox) = openLOC(o)
    defer { c.release(); dev.close() }

    let lock = NSLock()
    var started = Date()
    var firstFix: TimeInterval?
    var lastSV = Date.distantPast
    var counts: [String: Int] = [:]

    dev.onIndication = { m in
        guard m.service == .loc else { return }
        inbox.add(m)
        lock.lock(); counts[String(format: "cid %d 0x%04x", m.clientID, m.messageID), default: 0] += 1; lock.unlock()
        let t = Date().timeIntervalSince(started)
        log?.write(Data((String(format: "[%8.3f] ", t) + LOCInbox.describe(m, at: t) + "\n").utf8))
        switch m.messageID {
        case LOC.satelliteInfo:                    // every 5 s at most
            lock.lock(); defer { lock.unlock() }
            guard Date().timeIntervalSince(lastSV) >= 5, let listed = (m[tlv: 0x11] ?? m[tlv: 0x10])?.first else { return }
            lastSV = Date()
            let sats = LOC.parseSatellites(m)
            let tracking = sats.filter(\.tracking)
            let bySystem = Dictionary(grouping: tracking) { LOC.systemName($0.system) ?? "\($0.system)" }
            let tr = bySystem.keys.sorted().map { "\($0) \(bySystem[$0]?.count ?? 0)" }.joined(separator: ", ")
            let best = tracking.compactMap(\.cn0).sorted(by: >).prefix(4).map { String(format: "%.0f", $0) }.joined(separator: ",")
            print(String(format: "[%5.0f s] sats: %d listed, tracking %@%@, searching %d", t, Int(listed),
                         tr.isEmpty ? "none" : tr, best.isEmpty ? "" : " (best C/N0 \(best) dB-Hz)", sats.count - tracking.count))
        case LOC.positionReport:
            guard let p = LOC.parsePosition(m) else { return print(LOCInbox.describe(m, at: t)) }
            let names = ["success", "in progress", "general failure", "timeout", "user ended", "bad parameter", "phone offline/engine locked"]
            var s = String(format: "[%5.0f s] position: %@", t, Int(p.status) < names.count ? names[Int(p.status)] : "status \(p.status)")
            if let lat = p.latitude, let lon = p.longitude { s += String(format: ", %.2f, %.2f", lat, lon) }
            if let h = p.horizontalAccuracy { s += String(format: ", ±%.0f m", h) }
            if let alt = p.altitude, !alt.isNaN { s += String(format: ", alt %.0f m", alt) }
            if m[tlv: 0x2C] != nil { s += ", \(p.used.count) sats used" }
            if let tech = p.technology { s += String(format: ", tech 0x%x", tech) }
            print(s)
            lock.lock()
            if p.status == 0, p.latitude != nil, firstFix == nil {
                firstFix = t
                print(String(format: "==> first fix after %.1f s", t))
            }
            lock.unlock()
        case LOC.engineState:
            print(String(format: "[%5.0f s] engine %@ (client %d)", t, LOC.parseEngineOn(m) == true ? "on" : "off", m.clientID))
        case LOC.fixSessionState, LOC.nmea:
            break
        default:
            print(LOCInbox.describe(m, at: t))
        }
    }

    print("XTRA: " + validity(c, inbox, "XTRA validity", quiet: true))
    func register(_ cl: QMIClient, _ mask: UInt64) {
        call(cl, inbox, LOC.registerEvents, String(format: "Register Events 0x%llx on client %d", mask, cl.id),
             LOC.registerEventsRequest(mask), wait: 0)
    }
    if noRegister { print("(no Register Events: session reports should not arrive)") }
    else { register(c, mask) }
    if let injectFile {
        // Coordinates stay off the screen: only the uncertainty and the modem's answer are printed.
        let f = ((try? String(contentsOfFile: injectFile, encoding: .utf8)) ?? "").split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        guard f.count == 3 else { fail("--inject-file: want \"lat lon uncertainty\"") }
        let ind = call(c, inbox, LOC.injectPosition, String(format: "Inject Position (±%.0f m, cell ID source)", f[2]),
                       LOC.injectPositionRequest(latitude: f[0], longitude: f[1], uncertainty: Float(f[2])), quiet: true)
        let st = ind.flatMap(LOC.indicationStatus)
        print("inject position: " + (ind == nil ? "no answer" : "status \(st.map { "\($0.rawValue)" } ?? "?")") + (st == .success ? " (accepted)" : ""))
    }
    started = Date()
    call(c, inbox, LOC.start, "Start", LOC.startRequest(intervalMs: 1000), wait: 0)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 1)
        lock.lock(); let ff = firstFix; lock.unlock()
        if let r = releaseAfter, Date().timeIntervalSince(started) >= (ff ?? 0) + r { break }
        if releaseAfter == nil, let ff, Date().timeIntervalSince(started) > ff + afterFix { break }
    }
    lock.lock(); let ff = firstFix; lock.unlock()
    print(ff.map { String(format: "result: first fix after %.1f s", $0) } ?? "result: no fix within \(Int(timeout)) s")
    if releaseAfter != nil {
        guard let b = try? dev.allocateClient(.loc) else { fail("second LOC client") }
        register(b, defaultMask.rawValue)
        print(String(format: "[%5.0f s] releasing client %d without Stop; watching on client %d", Date().timeIntervalSince(started), c.id, b.id))
        c.release()
        Thread.sleep(forTimeInterval: 15)
        call(b, inbox, LOC.stop, "Stop on client \(b.id) (cleanup)", LOC.stopRequest(), wait: 0)
        b.release()
    } else if !noStop {
        call(c, inbox, LOC.stop, "Stop", LOC.stopRequest(), wait: 0)
    }
    lock.lock()
    print("indications: " + counts.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))
    lock.unlock()
}
