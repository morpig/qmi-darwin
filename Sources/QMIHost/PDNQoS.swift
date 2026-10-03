import Foundation
import QMIKit

// The QoS side of one connected PDN (docs/QMI-bearers.md): its default bearer's QCI,
// its APN-AMBR and its dedicated bearers.
//
// One QoS client, bound to the PDN's mux and to one IP family whose call is up (IPv4 when it
// is); a bearer is one EPS bearer whatever the family, and Event Reports carry the filters of
// both. Dedicated bearers follow the Event Reports (each create or modify report has the whole
// bearer). A snapshot at connect and after wake reads what exists already: the QoS IDs with
// their granted QCI and rates (filters arrive with the bearer's next report), the default
// bearer's QCI and the AMBR. Snapshot queries run on their own queue, since the modem can be
// slow to answer while the network changes bearers; results come back on `callbackQueue`.
final class PDNQoS {
    struct State: Equatable {
        var qci: UInt32?
        var ambr: WDS.AMBR?
        var bearers: [QoS.Bearer] = []
    }

    private let name: String
    private let log: (String) -> Void
    private let callbackQueue: DispatchQueue
    private let work = DispatchQueue(label: "qmid.qos")
    private var client: QMIClient?
    private var ambrClient: QMIClient?            // the chosen family's call (WDS) client

    private static let timeout: TimeInterval = 8

    init(device: QMIDevice, session: PDNSession, callbackQueue: DispatchQueue, log: @escaping (String) -> Void) {
        name = session.config.name
        self.log = { m in callbackQueue.async { log(m) } }   // the Manager's log runs on its queue
        self.callbackQueue = callbackQueue
        guard let family = session.settings.keys.sorted().first else { return }
        do {
            let c = try device.allocateClient(.qos)
            client = c
            try c.request(QoS.bindDataPort, QoS.bindDataPortRequest(interface: UInt32(device.modem.interfaceNumber),
                                                                     muxID: session.config.muxID))
            try c.request(QoS.setClientIPPref, QoS.clientIPPrefRequest(family: family))
            try c.request(QoS.eventReport, QoS.eventReportRequest())
        } catch {
            log("\(name): qos: \(error)")
            client?.release()
            client = nil
        }
        ambrClient = session.client(family: family)
        do { try ambrClient?.request(WDS.indicationRegister, WDS.ambrIndicationRequest()) }
        catch { log("\(name): AMBR indication: \(error)") }
    }

    // The QoS client, whose Event Reports are ours.
    var indicationClientID: UInt8? { client?.id }

    func close(release: Bool) {
        let c = client
        client = nil
        work.async { if release { c?.release() } }
    }

    // Reads the AMBR, the default bearer's QCI and the dedicated bearers that exist (without
    // filters). `done` runs on the callback queue, with nil when the modem didn't answer.
    func snapshot(done: @escaping (State?) -> Void) {
        let client = self.client, ambrClient = self.ambrClient, name = self.name, log = self.log
        work.async {
            var s = State()
            let t = Self.timeout
            do {
                if let c = ambrClient { s.ambr = WDS.parseAMBR(try c.request(WDS.getAMBRInfo, timeout: t)) }
                if let c = client {
                    s.qci = QoS.parseDefaultQCI(try c.request(QoS.getQoSInfo, QoS.qosIDRequest(0), timeout: t))
                    s.bearers = try QoS.parseQoSIDs(try c.request(QoS.getQoSIDs, timeout: t)).map {
                        QoS.parseGrantedQoS(try c.request(QoS.getGrantedQoS, QoS.qosIDRequest($0), timeout: t), qosID: $0)
                    }
                }
            } catch {
                log("\(name): qos: \(error)")
                self.callbackQueue.async { done(nil) }
                return
            }
            self.callbackQueue.async { done(s) }
        }
    }

    // MARK: Changes (pure, on the caller's queue)

    // The bearers after an Event Report, and the IDs it reported by their last event (also
    // deletions of bearers not in the list, which a running snapshot may still return).
    static func apply(_ m: QMIMessage, to bearers: [QoS.Bearer]) -> (bearers: [QoS.Bearer], touched: Set<UInt32>, deleted: Set<UInt32>) {
        var out = bearers, touched = Set<UInt32>(), deleted = Set<UInt32>()
        for r in QoS.parseEventReport(m) where r.changesBearer {
            if r.isDeleted {
                out.removeAll { $0.qosID == r.qosID }
                touched.remove(r.qosID)
                deleted.insert(r.qosID)
            } else if var b = r.bearer {
                if let i = out.firstIndex(where: { $0.qosID == r.qosID }) {
                    // Modify reports don't repeat the creation-only fields.
                    b.networkInitiated = b.networkInitiated ?? out[i].networkInitiated
                    b.bearerID = b.bearerID ?? out[i].bearerID
                    out[i] = b
                } else {
                    out.append(b)
                }
                touched.insert(r.qosID)
                deleted.remove(r.qosID)
            }
        }
        return (out, touched, deleted)
    }

    // A snapshot's bearers combined with what reports said meanwhile: what the snapshot lists,
    // minus what was deleted since it started, taking the reported (fuller) version where there
    // is one; plus bearers reported since that the snapshot didn't see.
    static func combine(snapshot: [QoS.Bearer], current: [QoS.Bearer],
                        touchedSince: Set<UInt32>, deletedSince: Set<UInt32>) -> [QoS.Bearer] {
        let byID = Dictionary(current.map { ($0.qosID, $0) }, uniquingKeysWith: { a, _ in a })
        let listed = Set(snapshot.map(\.qosID))
        return snapshot.filter { !deletedSince.contains($0.qosID) }.map { byID[$0.qosID] ?? $0 }
            + current.filter { touchedSince.contains($0.qosID) && !listed.contains($0.qosID) }
    }

    static func changes(from old: [QoS.Bearer], to new: [QoS.Bearer]) -> [String] {
        func describe(_ b: QoS.Bearer) -> String {
            let gbr = [b.uplink.rates.guaranteed, b.downlink.rates.guaranteed].contains { $0 != nil } ? " GBR" : ""
            return String(format: "0x%x", b.qosID) + " qci \(b.qci.map(String.init) ?? "?")\(gbr), " +
                "\(b.uplinkFilters.count) up / \(b.downlinkFilters.count) down filters"
        }
        let before = Dictionary(old.map { ($0.qosID, $0) }, uniquingKeysWith: { a, _ in a })
        var lines: [String] = []
        for b in new {
            if let o = before[b.qosID] { if o != b { lines.append("bearer changed: \(describe(b))") } }
            else { lines.append("bearer added: \(describe(b))\(b.networkInitiated == true ? " (network)" : "")") }
        }
        let now = Set(new.map(\.qosID))
        for o in old where !now.contains(o.qosID) { lines.append("bearer removed: " + String(format: "0x%x", o.qosID)) }
        return lines
    }
}
