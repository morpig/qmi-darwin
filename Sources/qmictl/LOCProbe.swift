import Foundation
import QMIHost
import QMIKit

// Direct-mode LOC probes (stop qmid first): what the modem's LOC service answers, before qmid
// uses it. LOC replies come as indications with the request's message ID; these commands wait
// for them and print the raw TLVs.
//   qmictl loc-survey [--register HEXMASK] [--listen SECONDS] [-v]
//   qmictl loc-inject FILE [--msg 35|a7] [--part-size N] [--stop-after N] [-v]

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

    static func describe(_ m: QMIMessage, at t: TimeInterval) -> String {
        var s = String(format: "  [%7.3f s] ind 0x%04x", t, m.messageID)
        if let st = status(m) { s += " status \(st) (\(statusName(st)))" }
        for tl in m.tlvs where tl.type != 0x01 {
            s += String(format: "\n      0x%02x (%d): ", tl.type, tl.value.count) + tl.value.hex
        }
        return s
    }

    static func status(_ m: QMIMessage) -> UInt32? {
        guard let v = m[tlv: 0x01], v.count >= 4 else { return nil }
        var r = ByteReader(v)
        return try? r.u32()
    }

    static let statusNames = ["success", "general failure", "unsupported", "invalid parameter",
                              "engine busy", "phone offline", "timeout"]
    static func statusName(_ s: UInt32) -> String { Int(s) < statusNames.count ? statusNames[Int(s)] : "?" }
}

private func u64(_ v: [UInt8], _ at: Int = 0) -> UInt64 {
    (0..<8).reduce(UInt64(0)) { $0 | UInt64(v[at + $1]) << (8 * UInt64($1)) }
}

private func openLOC(verbose: Bool) -> (QMIDevice, QMIClient, LOCInbox) {
    var o = Options()
    o.verbose = verbose
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
            for t in r.tlvs where t.type != 0x02 { print(String(format: "  resp 0x%02x (%d): ", t.type, t.value.count) + t.value.hex) }
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

private func showValidity(_ ind: QMIMessage?) {
    guard let v = ind?[tlv: 0x10], v.count >= 10 else { return print("  validity: no TLV 0x10") }
    let start = u64(v)
    let hours = UInt16(v[8]) | UInt16(v[9]) << 8
    let f = ISO8601DateFormatter()
    print("  validity: start raw \(start), duration \(hours) h")
    print("    as Unix s:  \(f.string(from: Date(timeIntervalSince1970: TimeInterval(start))))")
    print("    as Unix ms: \(f.string(from: Date(timeIntervalSince1970: TimeInterval(start) / 1000)))")
    // GPS epoch 1980-01-06, ignoring leap seconds
    print("    as GPS ms:  \(f.string(from: Date(timeIntervalSince1970: 315_964_800 + TimeInterval(start) / 1000)))")
}

private func showSource(_ ind: QMIMessage?) -> (maxFile: UInt32, maxPart: UInt32)? {
    var sizes: (UInt32, UInt32)?
    if let v = ind?[tlv: 0x10], v.count >= 8 {
        var r = ByteReader(v)
        sizes = ((try? r.u32()) ?? 0, (try? r.u32()) ?? 0)
        print("  max file size \(sizes!.0), max part size \(sizes!.1)")
    }
    if let v = ind?[tlv: 0x11], !v.isEmpty {
        var r = ByteReader(v)
        let n = (try? r.u8()) ?? 0
        for i in 0..<n {
            guard let l = try? r.u8(), let s = try? r.take(Int(l)) else { break }
            print("  server \(i + 1): \(String(decoding: s, as: UTF8.self))")
        }
    }
    return sizes
}

func locSurvey(_ args: [String]) {
    var register: UInt64?
    var regExtra: [TLV] = []                 // --reg-tlv TYPE:HEX, appended to Register Events
    var listen: TimeInterval = 0
    var verbose = false
    var supl = false
    var extra: [(UInt16, [TLV])] = []        // --call ID[:TT=HEX,...], read-only queries by hand
    var a = args[...]
    while let x = a.popFirst() {
        switch x {
        case "--supl": supl = true
        case "--call":
            let parts = (a.popFirst() ?? "").split(separator: ":", maxSplits: 1).map(String.init)
            guard let id = parts.first.flatMap({ UInt16($0.replacingOccurrences(of: "0x", with: ""), radix: 16) }) else { fail("--call ID[:TT=HEX,...]") }
            var tlvs: [TLV] = []
            for kv in (parts.count > 1 ? parts[1] : "").split(separator: ",") {
                let p = kv.split(separator: "=").map(String.init)
                guard p.count == 2, let t = UInt8(p[0], radix: 16), let v = [UInt8](hex: p[1]) else { fail("--call ID[:TT=HEX,...]") }
                tlvs.append(TLV(t, v))
            }
            extra.append((id, tlvs))
        case "--register": register = a.popFirst().flatMap { UInt64($0.replacingOccurrences(of: "0x", with: ""), radix: 16) }
        case "--reg-tlv":
            let parts = (a.popFirst() ?? "").split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let t = UInt8(parts[0], radix: 16), let v = [UInt8](hex: parts[1]) else { fail("--reg-tlv TYPE:HEX") }
            regExtra.append(TLV(t, v))
        case "--listen": listen = a.popFirst().flatMap(Double.init) ?? 0
        case "-v": verbose = true
        default: fail("usage: qmictl loc-survey [--register HEXMASK] [--listen SECONDS] [--supl] [--call ID[:TT=HEX,...]] [-v]")
        }
    }
    let (dev, c, inbox) = openLOC(verbose: verbose)
    defer { c.release(); dev.close() }

    // Get Supported Messages (common to QMI services): bitmap, bit N = message N.
    do {
        let r = try c.request(0x001E, timeout: 3)
        if let v = r[tlv: 0x10], v.count >= 2 {
            let bits = Array(v.dropFirst(2))
            let ids = (0..<bits.count * 8).filter { bits[$0 / 8] & (1 << ($0 % 8)) != 0 }
            print("0x001e Get Supported Messages: \(ids.count) IDs, 0x\(String(format: "%04x", ids.first ?? 0))–0x\(String(format: "%04x", ids.last ?? 0))")
        } else {
            print("0x001e Get Supported Messages: no TLV 0x10")
        }
    } catch {
        print("0x001e Get Supported Messages: \(error)")
    }

    if let m = register {
        var w = ByteWriter(); w.u32(UInt32(m & 0xffff_ffff)); w.u32(UInt32(m >> 32))
        call(c, inbox, 0x0021, String(format: "Register Events 0x%llx", m), [TLV(0x01, w.bytes)] + regExtra, wait: 0)
    } else {
        print("(no Register Events sent)")
    }

    _ = showSource(call(c, inbox, 0x0036, "Get Predicted Orbits Data Source"))
    showValidity(call(c, inbox, 0x0037, "Get Predicted Orbits Data Validity"))
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
        var w = ByteWriter(); w.u32(0xffff); w.u32(0)
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

func locInject(_ args: [String]) {
    var file: String?
    var msg: UInt16 = 0x0035
    var partSize: Int?
    var stopAfter: Int?
    var listen: TimeInterval = 0
    var partTimeout: TimeInterval = 10
    var verbose = false
    var a = args[...]
    while let x = a.popFirst() {
        switch x {
        case "--msg": msg = a.popFirst() == "a7" ? 0x00A7 : 0x0035
        case "--part-size": partSize = a.popFirst().flatMap { Int($0) }
        case "--stop-after": stopAfter = a.popFirst().flatMap { Int($0) }
        case "--listen": listen = a.popFirst().flatMap(Double.init) ?? 0
        case "--part-timeout": partTimeout = a.popFirst().flatMap(Double.init) ?? 10
        case "-v": verbose = true
        default:
            guard file == nil, !x.hasPrefix("-") else {
                fail("usage: qmictl loc-inject FILE [--msg 35|a7] [--part-size N] [--stop-after N] [-v]")
            }
            file = x
        }
    }
    guard let file, let data = FileManager.default.contents(atPath: file) else { fail("cannot read \(file ?? "FILE")") }
    let bytes = [UInt8](data)
    let (dev, c, inbox) = openLOC(verbose: verbose)
    defer { c.release(); dev.close() }

    let sizes = showSource(call(c, inbox, 0x0036, "Get Predicted Orbits Data Source"))
    showValidity(call(c, inbox, 0x0037, "Get Predicted Orbits Data Validity (before)"))
    let part = min(partSize ?? Int(sizes?.maxPart ?? 1024), 1024)
    let total = (bytes.count + part - 1) / part
    print(String(format: "injecting %d bytes in %d parts of %d with 0x%04x", bytes.count, total, part, msg))

    let started = Date()
    var slowest: TimeInterval = 0
    for i in 0..<total {
        if let s = stopAfter, i >= s { print("stopped after \(s) parts"); break }
        let chunk = Array(bytes[(i * part)..<min(bytes.count, (i + 1) * part)])
        var w = ByteWriter(); w.u16(UInt16(chunk.count)); w.append(chunk)
        var tlvs: [TLV] = [.u32(0x01, UInt32(bytes.count)), .u16(0x02, UInt16(total)),
                           .u16(0x03, UInt16(i + 1)), TLV(0x04, w.bytes)]
        if msg == 0x0035 { tlvs.append(.u32(0x10, 0)) }
        let mark = inbox.mark
        let t0 = Date()
        do {
            try c.request(msg, tlvs, timeout: 5)
        } catch {
            print("part \(i + 1)/\(total): response: \(error)")
            break
        }
        let partNo: (QMIMessage) -> Bool = { m in
            guard let v = m[tlv: 0x10], v.count >= 2 else { return true }
            return Int(UInt16(v[0]) | UInt16(v[1]) << 8) == i + 1
        }
        guard let (ind, at) = inbox.wait(msg, after: mark, timeout: partTimeout, where: partNo) else {
            print("part \(i + 1)/\(total): no indication within \(Int(partTimeout)) s")
            break
        }
        let dt = at.timeIntervalSince(t0)
        slowest = max(slowest, dt)
        let st = LOCInbox.status(ind) ?? 99
        if st != 0 || i == 0 || i == total - 1 || verbose {
            print(String(format: "part %d/%d: %.0f ms,", i + 1, total, dt * 1000)
                  + LOCInbox.describe(ind, at: at.timeIntervalSince(inbox.start)).dropFirst(2))
        }
        if st != 0 { break }
    }
    print(String(format: "inject: %.1f s total, slowest part %.0f ms", Date().timeIntervalSince(started), slowest * 1000))
    Thread.sleep(forTimeInterval: 1)
    showValidity(call(c, inbox, 0x0037, "Get Predicted Orbits Data Validity (after)"))
    if listen > 0 {
        print("listening \(Int(listen)) s…")
        inbox.printAll = true
        Thread.sleep(forTimeInterval: listen)
    }
}

// qmictl loc-fix [--timeout SECONDS] [--after-fix SECONDS] [--log FILE] [-v]
// A periodic 1 Hz session: satellite summaries, engine/session state, fixes, time to first fix.
// On screen, coordinates are rounded to 0.01°; --log gets the full indications.
func locFix(_ args: [String]) {
    var timeout: TimeInterval = 600
    var afterFix: TimeInterval = 15
    var logPath: String?
    var verbose = false
    var noRegister = false                  // check: does a session report without Register Events?
    var releaseAfter: TimeInterval?         // check: release the client without Stop; watch engine state on a 2nd client
    var noStop = false
    var mask: UInt32 = 0x183                 // position, SV info, engine state, fix session state
    var injectFile: String?                  // "lat lon uncertainty_m": Inject Position (0x0039) before Start
    var a = args[...]
    while let x = a.popFirst() {
        switch x {
        case "--no-register": noRegister = true
        case "--release-test": releaseAfter = a.popFirst().flatMap(Double.init)
        case "--no-stop": noStop = true
        case "--mask": mask = a.popFirst().flatMap { UInt32($0.replacingOccurrences(of: "0x", with: ""), radix: 16) } ?? mask
        case "--inject-file": injectFile = a.popFirst()
        case "--timeout": timeout = a.popFirst().flatMap(Double.init) ?? timeout
        case "--after-fix": afterFix = a.popFirst().flatMap(Double.init) ?? afterFix
        case "--log": logPath = a.popFirst()
        case "-v": verbose = true
        default: fail("usage: qmictl loc-fix [--timeout S] [--after-fix S] [--log FILE] [--no-register] [--release-test S] [--no-stop] [--mask HEX] [--inject-file F] [-v]")
        }
    }
    FileManager.default.createFile(atPath: logPath ?? "/dev/null", contents: nil)
    let log = logPath.flatMap { FileHandle(forWritingAtPath: $0) }
    let (dev, c, inbox) = openLOC(verbose: verbose)
    defer { c.release(); dev.close() }

    let lock = NSLock()
    var started = Date()
    var firstFix: TimeInterval?
    var lastSV = Date.distantPast
    var counts: [String: Int] = [:]
    let systems: [UInt32: String] = [1: "GPS", 2: "GAL", 3: "SBAS", 4: "BDS", 5: "GLO", 6: "QZSS"]

    func f32(_ v: [UInt8], _ o: Int) -> Float { Float(bitPattern: (0..<4).reduce(UInt32(0)) { $0 | UInt32(v[o + $1]) << (8 * UInt32($1)) }) }
    func f64(_ v: [UInt8]) -> Double? { v.count >= 8 ? Double(bitPattern: u64(v)) : nil }
    func u32v(_ v: [UInt8]?) -> UInt32? { guard let v, v.count >= 4 else { return nil }; var r = ByteReader(v); return try? r.u32() }

    dev.onIndication = { m in
        guard m.service == .loc else { return }
        inbox.add(m)
        lock.lock(); counts[String(format: "cid %d 0x%04x", m.clientID, m.messageID), default: 0] += 1; lock.unlock()
        let t = Date().timeIntervalSince(started)
        log?.write(Data((String(format: "[%8.3f] ", t) + LOCInbox.describe(m, at: t) + "\n").utf8))
        switch m.messageID {
        case 0x0025:                                   // GNSS SV Info
            lock.lock(); defer { lock.unlock() }
            // TLV 0x11 (29-byte entries) on LOC 2.x firmware, 0x10 (28 bytes) in libqmi's definition.
            let ext = m[tlv: 0x11] != nil
            guard Date().timeIntervalSince(lastSV) >= 5, let v = m[tlv: 0x11] ?? m[tlv: 0x10], !v.isEmpty else { return }
            let size = ext ? 29 : 28
            lastSV = Date()
            let n = Int(v[0])
            var tracked: [String: Int] = [:], searching = 0
            var snrs: [Float] = []
            for i in 0..<n {
                let o = 1 + i * size
                guard o + size <= v.count else { break }
                var r = ByteReader(v, offset: o)
                _ = try? r.u32()
                let sys = (try? r.u32()) ?? 0
                _ = try? r.u16(); _ = try? r.u8()
                let status = (try? r.u32()) ?? 0
                let snr = f32(v, o + 24)
                // Qualcomm's IDL: 1 idle, 2 searching, 3 tracking
                if status == 3 { tracked[systems[sys] ?? "\(sys)", default: 0] += 1; snrs.append(snr) }
                else if status == 2 { searching += 1 }
            }
            let best = snrs.sorted(by: >).prefix(4).map { String(format: "%.0f", $0) }.joined(separator: ",")
            let tr = tracked.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            print(String(format: "[%5.0f s] sats: %d listed, tracking %@%@, searching %d",
                         t, n, tr.isEmpty ? "none" : tr, best.isEmpty ? "" : " (best C/N0 \(best) dB-Hz)", searching))
        case 0x0024:                                   // Position Report
            let status = u32v(m[tlv: 0x01]) ?? 99
            let lat = m[tlv: 0x10].flatMap(f64), lon = m[tlv: 0x11].flatMap(f64)
            let hunc = m[tlv: 0x12].map { $0.count >= 4 ? f32($0, 0) : -1 }
            let alt = m[tlv: 0x1A].map { $0.count >= 4 ? f32($0, 0) : .nan }
            let tech = u32v(m[tlv: 0x23])
            let used = m[tlv: 0x2C].map { Int($0.first ?? 0) }
            let names = ["success", "in progress", "general failure", "timeout", "user ended", "bad parameter", "phone offline/engine locked"]
            var s = String(format: "[%5.0f s] position: %@", t, Int(status) < names.count ? names[Int(status)] : "status \(status)")
            if let lat, let lon { s += String(format: ", %.2f, %.2f", lat, lon) }
            if let hunc { s += String(format: ", ±%.0f m", hunc) }
            if let alt, !alt.isNaN { s += String(format: ", alt %.0f m", alt) }
            if let used { s += ", \(used) sats used" }
            if let tech { s += String(format: ", tech 0x%x", tech) }
            print(s)
            lock.lock()
            if status == 0, lat != nil, firstFix == nil {
                firstFix = t
                print(String(format: "==> first fix after %.1f s", t))
            }
            lock.unlock()
        case 0x002B:                                   // TLV 0x01 is the state here, not a status
            print(String(format: "[%5.0f s] engine %@ (client %d)", t, u32v(m[tlv: 0x01]) == 1 ? "on" : "off", m.clientID))
        case 0x002C, 0x0026:
            break
        default:
            print(LOCInbox.describe(m, at: t))
        }
    }

    validity(c, inbox)
    func register(_ cl: QMIClient, _ mask: UInt32) {
        var w = ByteWriter(); w.u32(mask); w.u32(0)
        call(cl, inbox, 0x0021, String(format: "Register Events 0x%x on client %d", mask, cl.id), [TLV(0x01, w.bytes), .u32(0x11, 1)], wait: 0)
    }
    if noRegister { print("(no Register Events: session reports should not arrive)") }
    else { register(c, mask) }
    if let injectFile {
        // Coordinates stay off the screen: only the uncertainty and the modem's answer are printed.
        let f = ((try? String(contentsOfFile: injectFile, encoding: .utf8)) ?? "").split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        guard f.count == 3 else { fail("--inject-file: want \"lat lon uncertainty\"") }
        func d(_ type: UInt8, _ v: Double) -> TLV { var w = ByteWriter(); w.u32(UInt32(v.bitPattern & 0xffff_ffff)); w.u32(UInt32(v.bitPattern >> 32)); return TLV(type, w.bytes) }
        func fl(_ type: UInt8, _ v: Float) -> TLV { .u32(type, v.bitPattern) }
        let ind = call(c, inbox, 0x0039, String(format: "Inject Position (±%.0f m, cell ID source)", f[2]),
                       [d(0x10, f[0]), d(0x11, f[1]), fl(0x12, Float(f[2])), .u8(0x13, 68), .u32(0x14, 3), .u32(0x1D, 1)], quiet: true)
        let st = ind?[tlv: 0x01].flatMap { u32v($0) }
        print("inject position: " + (ind == nil ? "no answer" : "status \(st.map(String.init) ?? "?")") + (st == 0 ? " (accepted)" : ""))
    }
    started = Date()
    // Start: session 1, periodic fixes, intermediate reports on, 1000 ms between reports.
    call(c, inbox, 0x0022, "Start", [.u8(0x01, 1), .u32(0x10, 1), .u32(0x12, 1), .u32(0x13, 1000)], wait: 0)
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
        register(b, 0x183)
        print(String(format: "[%5.0f s] releasing client %d without Stop; watching on client %d", Date().timeIntervalSince(started), c.id, b.id))
        c.release()
        Thread.sleep(forTimeInterval: 15)
        call(b, inbox, 0x0023, "Stop on client \(b.id) (cleanup)", [.u8(0x01, 1)], wait: 0)
        b.release()
    } else if !noStop {
        call(c, inbox, 0x0023, "Stop", [.u8(0x01, 1)], wait: 0)
    }
    lock.lock()
    print("indications: " + counts.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))
    lock.unlock()
}

private func validity(_ c: QMIClient, _ inbox: LOCInbox) {
    guard let ind = call(c, inbox, 0x0037, "XTRA validity", quiet: true), let v = ind[tlv: 0x10], v.count >= 10 else {
        return print("XTRA validity: unreadable")
    }
    let start = Date(timeIntervalSince1970: TimeInterval(u64(v)))
    let hours = Int(UInt16(v[8]) | UInt16(v[9]) << 8)
    print("XTRA: from \(ISO8601DateFormatter().string(from: start)), \(hours) h, \(Int(start.addingTimeInterval(Double(hours) * 3600).timeIntervalSinceNow / 3600)) h left")
}
