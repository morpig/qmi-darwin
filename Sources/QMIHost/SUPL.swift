import Foundation
import Network

// A minimal SUPL 2.0 client (OMA ULP over TLS, LPP payload), for one thing only: the server's
// reference location for the serving LTE cell, which qmid injects into the modem (LOC Inject
// Position) before starting a session, so the GNSS search starts near the right place instead
// of from a country-wide guess. SET-initiated, SET-based, nothing but the reference location
// requested. The SET identity sent is a fixed test IMSI (001-01), not the SIM's.
//
// Messages are hand-encoded unaligned PER (X.691) for exactly the fields used; the decoder
// reads the server's SUPL RESPONSE / POS / END and, inside the LPP Provide Assistance Data, the
// GNSS reference location. Both were checked byte for byte against pycrate's ULP and LPP
// modules (Tests/QMIHostTests/SUPLTests.swift). See docs/QMI-loc.md, "Position from SUPL".

enum SUPL {
    struct Cell: Equatable {
        var mcc: String                     // 3 digits
        var mnc: String                     // 2 or 3 digits
        var cellID: UInt32                  // ECI, 28 bits
        var tac: UInt16
        var pci: UInt16                     // 0–503
        var description: String { "\(mcc)-\(mnc) tac \(tac) cell \(cellID) pci \(pci)" }
    }

    struct ReferenceLocation: Equatable {
        var latitude: Double
        var longitude: Double
        var semiMajor: Double               // m
        var semiMinor: Double               // m
        var confidence: Int                 // %
        var altitude: Double?               // m; nil when the server sent its "unknown" (uncertainty 127)
    }

    enum Failure: Error, CustomStringConvertible, Equatable {
        case encoding(String)
        case decoding(String)
        case server(String)                 // SUPL END with a status, or an unexpected message
        case noLocation                     // the session ended without a reference location
        case transport(String)

        var description: String {
            switch self {
            case .encoding(let s): return "SUPL encoding: \(s)"
            case .decoding(let s): return "SUPL decoding: \(s)"
            case .server(let s): return "SUPL server: \(s)"
            case .noLocation: return "SUPL: no reference location for this cell"
            case .transport(let s): return "SUPL: \(s)"
            }
        }
    }

    static let testIMSI = "001010123456789"

    // MARK: - Encoding

    // ULP message choice indices (root alternatives of UlpMessage)
    static let msSUPLSTART = 1, msSUPLRESPONSE = 2, msSUPLPOSINIT = 3, msSUPLPOS = 4, msSUPLEND = 5

    static func start(_ cell: Cell, sessionID: UInt16 = 1) throws -> [UInt8] {
        try pdu(sessionID: sessionID, slp: nil, message: msSUPLSTART) { w in
            w.bit(false)                    // msSUPLSTART: no extensions
            w.bit(false)                    // qoP absent
            capabilities(&w)
            try locationID(&w, cell)
        }
    }

    // `slp`: the server's slpSessionID, as the bits it sent (SlpSessionID.raw).
    static func posInit(_ cell: Cell, slp: Bits, sessionID: UInt16 = 1) throws -> [UInt8] {
        try pdu(sessionID: sessionID, slp: slp, message: msSUPLPOSINIT) { w in
            w.bit(false)                    // no extensions
            w.bits(0b1000, 4)               // requestedAssistData present; position, suplpos, ver absent
            capabilities(&w)
            // RequestedAssistData: no extensions, navigationModelData absent, then the 9 booleans:
            // almanac, utcModel, ionosphericModel, dgpsCorrections, referenceLocation,
            // referenceTime, acquisitionAssistance, realTimeIntegrity, navigationModel.
            w.bit(false); w.bit(false)
            w.bits(0b0000_1000_0, 9)
            try locationID(&w, cell)
        }
    }

    private static func pdu(sessionID: UInt16, slp: Bits?, message: Int, _ body: (inout BitWriter) throws -> Void) throws -> [UInt8] {
        var w = BitWriter()
        w.bits(0, 16)                       // length, set below
        w.bits(2, 8); w.bits(0, 8); w.bits(0, 8)    // version 2.0.0
        w.bit(true); w.bit(slp != nil)      // setSessionID, slpSessionID
        w.bits(UInt64(sessionID), 16)
        w.bit(false); w.bits(3, 3)          // SETId: no extension, imsi
        for b in tbcd(testIMSI) { w.bits(UInt64(b), 8) }
        if let slp { w.append(slp) }
        w.bit(false); w.bits(UInt64(message), 3)    // UlpMessage: root alternative
        try body(&w)
        var bytes = w.bytes
        guard bytes.count <= 0xffff else { throw Failure.encoding("message too long") }
        bytes[0] = UInt8(bytes.count >> 8); bytes[1] = UInt8(bytes.count & 0xff)
        return bytes
    }

    // SET capabilities: SET-based A-GPS and autonomous; SET-based preferred; LPP 12.0.0.
    private static func capabilities(_ w: inout BitWriter) {
        w.bit(false)                        // SETCapabilities: no extensions
        w.bit(false)                        // PosTechnology: no extensions
        w.bits(0b0110000, 7)                // agpsSETassisted, agpsSETBased, autonomousGPS, aflt, ecid, eotd, otdoa
        w.bits(1, 2)                        // prefMethod agpsSETBasedPreferred
        w.bit(true)                         // PosProtocol: extensions present
        w.bits(0b000, 3)                    // tia801, rrlp, rrc
        var ext = BitWriter()               // ver2-PosProtocol-extension
        ext.bit(false)                      // no extensions
        ext.bits(0b0001, 4)                 // versions: RRLP, RRC, TIA-801 absent; LPP present
        ext.bit(true)                       // lpp
        ext.bit(false); ext.bits(12, 8); ext.bits(0, 8); ext.bits(0, 8)
        w.extensionBitmap([ext])
    }

    private static func locationID(_ w: inout BitWriter, _ c: Cell) throws {
        guard c.mcc.count == 3, (2...3).contains(c.mnc.count),
              let mcc = digits(c.mcc), let mnc = digits(c.mnc) else { throw Failure.encoding("PLMN \(c.mcc)-\(c.mnc)") }
        guard c.cellID < 1 << 28, c.pci <= 503 else { throw Failure.encoding("cell \(c.cellID) pci \(c.pci)") }
        w.bit(false)                        // LocationId: no extensions
        w.bit(true)                         // CellInfo: extension alternative
        var lte = BitWriter()               // ver2-CellInfo-extension
        lte.bit(false); lte.bits(2, 3)      // no extension; lteCell
        lte.bit(false)                      // LteCellInformation: no extensions (earfcn left out)
        lte.bits(0, 4)                      // rsrpResult, rsrqResult, ta, measResultListEUTRA absent
        lte.bit(false)                      // CellGlobalIdEUTRA: no extensions
        lte.bit(true)                       // PLMN-Identity: mcc present
        for d in mcc { lte.bits(UInt64(d), 4) }
        lte.bits(UInt64(mnc.count - 2), 1)
        for d in mnc { lte.bits(UInt64(d), 4) }
        lte.bits(UInt64(c.cellID), 28)
        lte.bits(UInt64(c.pci), 9)
        lte.bits(UInt64(c.tac), 16)
        w.smallNumber(0)                    // the first extension alternative
        w.openType(lte)
        w.bit(false); w.bits(1, 2)          // status: no extension; current
    }

    private static func digits(_ s: String) -> [Int]? {
        let d = s.compactMap(\.wholeNumberValue)
        return d.count == s.count ? d : nil
    }

    static func tbcd(_ digits: String) -> [UInt8] {
        let d = Array(digits.compactMap(\.hexDigitValue)) + (digits.count % 2 == 1 ? [0xF] : [])
        return stride(from: 0, to: d.count, by: 2).map { UInt8(d[$0 + 1] << 4 | d[$0]) }
    }

    // MARK: - Decoding

    enum Message: Equatable {
        case response
        case pos(lpp: [[UInt8]])
        case end(status: Int?)              // StatusCode root index, when sent (and readable)
        case other(Int)
    }

    struct Decoded: Equatable {
        var slp: Bits?                      // the server's slpSessionID, verbatim, to echo back
        var message: Message
    }

    static func decode(_ bytes: [UInt8]) throws -> Decoded {
        var r = BitReader(bytes)
        let length = try r.bits(16)
        guard length == bytes.count else { throw Failure.decoding("length \(length), got \(bytes.count) bytes") }
        let major = try r.bits(8); _ = try r.bits(16)
        guard major == 2 || major == 1 else { throw Failure.decoding("version \(major)") }
        let hasSET = try r.bit(), hasSLP = try r.bit()
        if hasSET {
            _ = try r.bits(16)
            guard try !r.bit() else { throw Failure.decoding("SETId extension") }
            switch try r.bits(3) {
            case 0, 1, 3: try r.skip(64)                         // msisdn, mdn, imsi
            case 2: try r.skip(34)                               // min
            case 4: try r.skip(Int(try r.bits(10) + 1) * 7)      // nai, IA5String (1..1000)
            case 5: try r.skip(try r.bit() ? 128 : 32)           // iPAddress
            default: throw Failure.decoding("SETId")
            }
        }
        var slp: Bits?
        if hasSLP {
            let from = r.position
            try r.skip(32)                                       // sessionID, 4 octets
            guard try !r.bit() else { throw Failure.decoding("SLPAddress extension") }
            if try !r.bit() {                                    // iPAddress
                try r.skip(try r.bit() ? 128 : 32)
            } else {                                             // fqdn: 1..255 characters, 6 bits each
                try r.skip(Int(try r.bits(8) + 1) * 6)
            }
            slp = r.slice(from: from)
        }
        guard try !r.bit() else { return Decoded(slp: slp, message: .other(-1)) }   // an extension message
        let index = Int(try r.bits(3))
        switch index {
        case msSUPLRESPONSE:
            return Decoded(slp: slp, message: .response)
        case msSUPLEND:
            _ = try r.bit()                                      // extensions
            let position = try r.bit(), status = try r.bit()
            _ = try r.bit()                                      // ver
            var code: Int?
            if status, !position {                               // a position comes first: not parsed
                code = try r.bit() ? 100 + Int(try r.bits(7)) : Int(try r.bits(5))
            }
            return Decoded(slp: slp, message: .end(status: code))
        case msSUPLPOS:
            _ = try r.bit()                                      // extensions
            _ = try r.bit()                                      // velocity (after the payload)
            guard try r.bit() else { throw Failure.decoding("SUPL POS without an LPP payload (RRLP / RRC / TIA-801)") }
            guard try !r.bit(), try r.bits(6) == 0 else { throw Failure.decoding("PosPayLoad extension") }
            var inner = BitReader(try r.openType())
            _ = try inner.bit()                                  // extensions
            let hasLPP = try inner.bit(); _ = try inner.bit()
            guard hasLPP else { return Decoded(slp: slp, message: .pos(lpp: [])) }
            let n = Int(try inner.bits(2)) + 1
            var out: [[UInt8]] = []
            for _ in 0..<n {
                let len = Int(try inner.bits(16)) + 1            // OCTET STRING (1..60000)
                out.append(try inner.octets(len))
            }
            return Decoded(slp: slp, message: .pos(lpp: out))
        default:
            return Decoded(slp: slp, message: .other(index))
        }
    }

    // The GNSS reference location in an LPP Provide Assistance Data, or nil if the message
    // has none. Stops reading right after it.
    static func referenceLocation(lpp bytes: [UInt8]) throws -> ReferenceLocation? {
        var r = BitReader(bytes)
        let hasTransaction = try r.bit(), hasSequence = try r.bit(), hasAck = try r.bit(), hasBody = try r.bit()
        if hasTransaction {
            _ = try r.bit()                                      // extensions
            guard try !r.bit() else { throw Failure.decoding("Initiator extension") }
            try r.skip(1 + 8)                                    // initiator, transactionNumber
        }
        _ = try r.bit()                                          // endTransaction
        if hasSequence { try r.skip(8) }
        if hasAck { let indicator = try r.bit(); try r.skip(1 + (indicator ? 8 : 0)) }
        guard hasBody, try !r.bit() else { return nil }          // c1
        guard try r.bits(4) == 3 else { return nil }             // provideAssistanceData
        guard try !r.bit(), try r.bits(2) == 0 else { return nil } // criticalExtensions c1, -r9
        _ = try r.bit()                                          // extensions
        let common = try r.bit(), agnss = try r.bit(); try r.skip(2)
        if common {                                              // CommonIEsProvideAssistanceData: extensions only
            if try r.bit() { try r.skipExtensions() }
        }
        guard agnss else { return nil }
        _ = try r.bit()
        guard try r.bit() else { return nil }                    // gnss-CommonAssistData
        try r.skip(2)                                            // generic, error
        _ = try r.bit()
        let refTime = try r.bit(), refLocation = try r.bit(); try r.skip(2)
        guard !refTime else { throw Failure.decoding("reference time before the location (not requested, not parsed)") }
        guard refLocation else { return nil }
        _ = try r.bit()                                          // GNSS-ReferenceLocation extensions
        // EllipsoidPointWithAltitudeAndUncertaintyEllipsoid (TS 23.032)
        let south = try r.bit()
        let lat = Double(try r.bits(23)) * 90 / Double(1 << 23)
        let lon = Double(Int(try r.bits(24)) - (1 << 23)) * 360 / Double(1 << 24)
        let depth = try r.bit()
        let altitude = Double(try r.bits(15))
        let major = Int(try r.bits(7)), minor = Int(try r.bits(7))
        try r.skip(8)                                            // orientation of the major axis
        let altUnc = Int(try r.bits(7))
        let confidence = Int(try r.bits(7))
        func unc(_ k: Int) -> Double { 10 * (pow(1.1, Double(k)) - 1) }
        return ReferenceLocation(latitude: south ? -lat : lat, longitude: lon, semiMajor: unc(major), semiMinor: unc(minor),
                                 confidence: confidence, altitude: altUnc == 127 ? nil : (depth ? -altitude : altitude))
    }

    // MARK: - The exchange

    // One session with `host`: START → RESPONSE, POS INIT → POS (→ END, not waited for once the
    // location is in). Blocks for at most
    // `timeout`; run it off the manager queue. `log` gets each step.
    static func query(host: String, port: UInt16, cell: Cell, timeout: TimeInterval,
                      log sink: LogSink) throws -> ReferenceLocation {
        func log(_ s: String) { sink(.info, s) }
        let conn = try Connection(host: host, port: port, deadline: Date().addingTimeInterval(timeout))
        defer { conn.close() }
        log("SUPL: connected to \(host):\(port) (\(conn.path))")
        try conn.send(try start(cell))
        log("SUPL: sent SUPL START for \(cell.description)")
        let first = try decode(try conn.receive())
        switch first.message {
        case .response: break
        case .end(let s): throw Failure.server("SUPL END after START\(s.map { ", status \($0)" } ?? "")")
        case let m: throw Failure.server("unexpected \(m) after START")
        }
        guard let slp = first.slp else { throw Failure.decoding("SUPL RESPONSE without an SLP session ID") }
        log("SUPL: SUPL RESPONSE")
        try conn.send(try posInit(cell, slp: slp))
        log("SUPL: sent SUPL POS INIT (reference location only)")
        var found: ReferenceLocation?       // stays nil until returned
        while true {
            let m = try decode(try conn.receive())
            switch m.message {
            case .pos(let lpp):
                log("SUPL: SUPL POS with \(lpp.count) LPP message\(lpp.count == 1 ? "" : "s") (\(lpp.map(\.count).reduce(0, +)) bytes)")
                for p in lpp where found == nil { found = try referenceLocation(lpp: p) }
                // The server sends SUPL END about 2 s later; nothing more is needed from it.
                if let found { log("SUPL: reference location received; closing without waiting for SUPL END"); return found }
            case .end(let s):
                log("SUPL: SUPL END\(s.map { ", status \($0)" } ?? "")")
                guard let found else { throw s.map { Failure.server("status \($0)") } ?? Failure.noLocation }
                return found
            case let other:
                throw Failure.server("unexpected \(other)")
            }
        }
    }

    // A TLS connection with blocking send / receive of length-prefixed ULP PDUs.
    private final class Connection {
        private let conn: NWConnection
        private let queue = DispatchQueue(label: "qmid.supl")
        private let deadline: Date
        private var buffer: [UInt8] = []
        private(set) var path = ""

        init(host: String, port: UInt16, deadline: Date) throws {
            self.deadline = deadline
            guard let p = NWEndpoint.Port(rawValue: port) else { throw Failure.transport("port \(port)") }
            let params = NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options())
            conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: params)
            // The path once ready, nil when it failed. `waiting` and `failure` are written on
            // `queue` and read there once the handler is gone. No `self` in the handler: a
            // connection that never gets ready is dropped with its handler cleared.
            let ready = BlockingValue<String?>()
            var waiting: String?, failure: String?
            conn.stateUpdateHandler = { [conn] state in
                switch state {
                case .ready: ready.put(conn.currentPath?.availableInterfaces.first.map { "via \($0.name)" } ?? "")
                case .waiting(let e): waiting = "\(e)"          // no route yet: keep waiting until the deadline
                case .failed(let e): failure = "\(e)"; ready.put(nil)
                case .cancelled: failure = failure ?? "cancelled"; ready.put(nil)
                default: break
                }
            }
            conn.start(queue: queue)
            let outcome = ready.wait(timeout: remaining)
            if case let path?? = outcome {
                self.path = path
                return
            }
            close()
            let (w, f) = queue.sync { (waiting, failure) }
            guard outcome != nil else {
                throw Failure.transport("no connection to \(host) within the time limit\(w.map { " (\($0))" } ?? "")")
            }
            throw Failure.transport("connecting to \(host): \(f ?? "cancelled")")
        }

        private var remaining: TimeInterval { deadline.timeIntervalSinceNow }

        func send(_ bytes: [UInt8]) throws {
            let done = BlockingValue<NWError?>()
            conn.send(content: Data(bytes), completion: .contentProcessed { done.put($0) })
            guard let failure = done.wait(timeout: remaining) else { throw Failure.transport("send timed out") }
            if let failure { throw Failure.transport("send: \(failure)") }
        }

        func receive() throws -> [UInt8] {
            while true {
                if buffer.count >= 2 {
                    let n = Int(buffer[0]) << 8 | Int(buffer[1])
                    guard n >= 2 else { throw Failure.decoding("PDU length \(n)") }
                    if buffer.count >= n {
                        let pdu = Array(buffer[..<n])
                        buffer.removeFirst(n)
                        return pdu
                    }
                }
                let done = BlockingValue<(chunk: Data?, failure: NWError?, closed: Bool)>()
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, complete, e in
                    done.put((d, e, complete))
                }
                guard let r = done.wait(timeout: remaining) else { throw Failure.transport("no answer within the time limit") }
                if let failure = r.failure { throw Failure.transport("receive: \(failure)") }
                if let chunk = r.chunk { buffer += chunk }
                if r.closed, r.chunk?.isEmpty ?? true { throw Failure.transport("the server closed the connection") }
            }
        }

        func close() { conn.stateUpdateHandler = nil; conn.cancel() }
    }
}

// MARK: - Unaligned PER bits

struct Bits: Equatable {
    var bytes: [UInt8] = []
    var count = 0
}

struct BitWriter {
    private(set) var bits = Bits()
    var bytes: [UInt8] { bits.bytes }
    var count: Int { bits.count }

    mutating func bit(_ b: Bool) {
        if bits.count % 8 == 0 { bits.bytes.append(0) }
        if b { bits.bytes[bits.bytes.count - 1] |= 0x80 >> UInt8(bits.count % 8) }
        bits.count += 1
    }

    mutating func bits(_ v: UInt64, _ n: Int) {
        for i in stride(from: n - 1, through: 0, by: -1) { bit(v >> UInt64(i) & 1 == 1) }
    }

    mutating func append(_ b: Bits) {
        for i in 0..<b.count { bit(b.bytes[i / 8] & (0x80 >> UInt8(i % 8)) != 0) }
    }

    // A normally small non-negative whole number (≤ 63).
    mutating func smallNumber(_ n: Int) { bit(false); bits(UInt64(n), 6) }

    // An open type: the encoding padded to whole octets (at least one), with its length.
    mutating func openType(_ inner: BitWriter) {
        let content = inner.bytes.isEmpty ? [0] : inner.bytes
        lengthDeterminant(content.count)
        for b in content { bits(UInt64(b), 8) }
    }

    // A SEQUENCE's extension additions, each present (none absent in this client).
    mutating func extensionBitmap(_ additions: [BitWriter]) {
        smallNumber(additions.count - 1)
        for _ in additions { bit(true) }
        for a in additions { openType(a) }
    }

    mutating func lengthDeterminant(_ n: Int) {
        if n < 128 { bits(UInt64(n), 8) } else { bits(0b10, 2); bits(UInt64(n), 14) }
    }
}

struct BitReader {
    let bytes: [UInt8]
    private(set) var position = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func bit() throws -> Bool {
        guard position < bytes.count * 8 else { throw SUPL.Failure.decoding("message ends early") }
        defer { position += 1 }
        return bytes[position / 8] & (0x80 >> UInt8(position % 8)) != 0
    }

    mutating func bits(_ n: Int) throws -> UInt64 {
        var v: UInt64 = 0
        for _ in 0..<n { v = v << 1 | (try bit() ? 1 : 0) }
        return v
    }

    mutating func skip(_ n: Int) throws {
        guard position + n <= bytes.count * 8 else { throw SUPL.Failure.decoding("message ends early") }
        position += n
    }

    mutating func octets(_ n: Int) throws -> [UInt8] {
        try (0..<n).map { _ in UInt8(try bits(8)) }
    }

    mutating func lengthDeterminant() throws -> Int {
        if try !bit() { return Int(try bits(7)) }
        guard try !bit() else { throw SUPL.Failure.decoding("fragmented length") }
        return Int(try bits(14))
    }

    mutating func openType() throws -> [UInt8] { try octets(try lengthDeterminant()) }

    // A SEQUENCE's extension additions (after its extension bit was 1): skipped.
    mutating func skipExtensions() throws {
        guard try !bit() else { throw SUPL.Failure.decoding("too many extension additions") }
        let n = Int(try bits(6)) + 1
        var present = 0
        for _ in 0..<n where try bit() { present += 1 }
        for _ in 0..<present { _ = try openType() }
    }

    func slice(from: Int) -> Bits {
        var w = BitWriter()
        for i in from..<position { w.bit(bytes[i / 8] & (0x80 >> UInt8(i % 8)) != 0) }
        return w.bits
    }
}
