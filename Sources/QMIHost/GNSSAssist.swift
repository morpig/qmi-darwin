import Foundation
import QMIDAPI
import QMIKit

// GNSS assistance data (XTRA) on one modem: reading what it holds and loading a file. Each call
// uses a LOC client of its own (the replies need no event registration) and blocks while the
// modem answers, so callers run it off the manager queue. Behaviour as checked on the RM551E;
// see docs/QMI-loc.md.
final class GNSSAssist {
    enum Failure: Error, CustomStringConvertible {
        case empty
        case tooLarge(Int, Int)
        case rejected(part: Int, of: Int, LOC.IndicationStatus)
        case noAck(part: Int, of: Int)
        case failed(part: Int, of: Int, Error)
        case stuck(String)

        var description: String {
            switch self {
            case .empty: return "empty XTRA file"
            case .tooLarge(let n, let max): return "XTRA file of \(n) bytes; the modem takes at most \(max)"
            case .rejected(let p, let n, let s): return "the modem refused part \(p) of \(n): \(s)"
            // The modem acknowledges a bad file's last part with silence (the data it held stays).
            case .noAck(let p, let n) where p == n: return "the modem did not take the file (no answer to its last part); its XTRA data is unchanged"
            case .noAck(let p, let n): return "no answer to part \(p) of \(n)"
            case .failed(let p, let n, let e): return "part \(p) of \(n): \(e)"
            case .stuck(let s): return s
            }
        }
    }

    private let device: QMIDevice
    private let log: (String, QMIDLogLevel) -> Void
    // The inject message this modem takes; 0x00A7 until it answers NotSupported.
    private var injectMessage = LOC.injectXTRAData

    init(device: QMIDevice, log: @escaping (String, QMIDLogLevel) -> Void) {
        self.device = device
        self.log = log
    }

    func status() throws -> QMIDXTRA {
        try withClient { c in
            let source: LOC.XTRASource
            do {
                source = LOC.parseSource(try reply(c, LOC.getPredictedOrbitsDataSource))
            } catch QMIHostError.protocolError(.notSupported, _) {
                return QMIDXTRA(supported: false)
            }
            let v: LOC.XTRAValidity?
            do {
                v = try validity(c)
            } catch QMIHostError.protocolError(let e, _) where e.rawValue == 1 {
                // MalformedMessage (AT+QGPSXTRADATA? answers ERROR alike) after a load left unfinished.
                throw Failure.stuck("XTRA state unreadable: a load was left unfinished; a complete load or a modem restart clears it")
            }
            return QMIDXTRA(supported: true, validFrom: v?.start, validHours: v?.hours, servers: source.servers)
        }
    }

    // Injects `data` part by part, each acknowledged before the next; then reads the validity
    // again. A transfer left unfinished keeps the modem's XTRA unreadable (to everyone) until a
    // complete one or a modem reset, so a failure before the last part is followed by one
    // complete retry from part 1.
    func load(_ data: [UInt8]) throws -> QMIDXTRA {
        guard !data.isEmpty else { throw Failure.empty }
        return try withClient { c in
            let source = LOC.parseSource(try reply(c, LOC.getPredictedOrbitsDataSource))
            if let max = source.maxFileSize, max > 0, data.count > max { throw Failure.tooLarge(data.count, max) }
            let partSize = min(source.maxPartSize.flatMap { $0 > 0 ? $0 : nil } ?? LOC.maxPartSize, LOC.maxPartSize)
            let started = Date()
            do {
                try inject(c, data, partSize: partSize)
            } catch Failure.failed(let p, let n, let e) where p < n {
                log("XTRA: part \(p) of \(n) failed (\(e)); loading again from part 1", .notice)
                do {
                    try inject(c, data, partSize: partSize)
                } catch {
                    throw Failure.stuck("\(error); the modem's XTRA state stays unreadable until a complete load or a modem restart")
                }
            }
            let v = try validity(c)
            log(String(format: "XTRA: loaded %d bytes in %.1f s, valid %@", data.count, Date().timeIntervalSince(started),
                       v.map { "from \(ISO8601DateFormatter().string(from: $0.start)) for \($0.hours) h" } ?? "?"), .notice)
            return QMIDXTRA(supported: true, validFrom: v?.start, validHours: v?.hours, servers: source.servers)
        }
    }

    private func inject(_ c: QMIClient, _ data: [UInt8], partSize: Int) throws {
        var parts = LOC.injectRequests(data, message: injectMessage, partSize: partSize)
        let total = parts.count
        guard total > 0 else { throw Failure.tooLarge(data.count, partSize * Int(UInt16.max)) }
        var i = 0
        var busy = 0
        while i < total {
            let n = i + 1
            let ack: QMIMessage
            do {
                // The last part takes ~0.5 s (the modem checks the file); the others ~30 ms.
                ack = try c.requestIndication(injectMessage, parts[i], timeout: 5, indicationTimeout: 5) {
                    LOC.injectedPart($0).map { $0 == n } ?? true
                }
            } catch QMIHostError.protocolError(.notSupported, _) where n == 1 && injectMessage == LOC.injectXTRAData {
                log("XTRA: Inject XTRA Data not supported; using Inject Predicted Orbits Data", .info)
                injectMessage = LOC.injectPredictedOrbitsData
                parts = LOC.injectRequests(data, message: injectMessage, partSize: partSize)
                continue
            } catch QMIHostError.timeout {
                // At the last part this is how the modem turns down a bad file; before it, the
                // transfer is left open.
                if n == total { throw Failure.noAck(part: n, of: total) }
                throw Failure.failed(part: n, of: total, Failure.noAck(part: n, of: total))
            } catch {
                throw Failure.failed(part: n, of: total, error)
            }
            let status = LOC.indicationStatus(ack) ?? .success
            if status == .engineBusy, busy < 3 {
                busy += 1
                Thread.sleep(forTimeInterval: 0.5)
                continue                            // the same part again
            }
            guard status == .success else {
                if n == total { throw Failure.rejected(part: n, of: total, status) }
                throw Failure.failed(part: n, of: total, Failure.rejected(part: n, of: total, status))
            }
            busy = 0
            i += 1
        }
    }

    private func validity(_ c: QMIClient) throws -> LOC.XTRAValidity? {
        LOC.parseValidity(try reply(c, LOC.getPredictedOrbitsDataValidity))
    }

    // A request and its reply indication; a status other than success is an error.
    private func reply(_ c: QMIClient, _ message: UInt16, _ tlvs: [TLV] = []) throws -> QMIMessage {
        let ind = try c.requestIndication(message, tlvs, timeout: 5, indicationTimeout: 5)
        if let s = LOC.indicationStatus(ind), s != .success {
            throw QMIHostError.transport(String(format: "loc 0x%04x: %@", message, s.description))
        }
        return ind
    }

    private func withClient<T>(_ body: (QMIClient) throws -> T) throws -> T {
        let c = try device.allocateClient(.loc)
        defer { c.release() }
        return try body(c)
    }
}
