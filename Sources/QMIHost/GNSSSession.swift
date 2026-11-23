import Foundation
import QMIDAPI
import QMIKit

// The location session qmid runs while client apps want positions: one LOC client with event
// registration and a periodic session. The client exists only while a session is wanted;
// releasing it also turns the engine off. A session doesn't survive a modem reset, so Manager
// makes a new one when the modem comes back. Requests run on `work`; handle() and the
// callbacks run on the manager queue. See docs/QMI-loc.md.
final class GNSSSession {
    struct Want: Equatable {
        var interval: Int                   // ms between reports
        var satellites: Bool
        var nmea: Bool
    }

    // On the manager queue.
    var onLocation: ((QMIDLocation) -> Void)?
    var onSatellites: ((QMIDSatellites) -> Void)?
    var onNMEA: ((String) -> Void)?
    var onEngine: ((Bool) -> Void)?

    private let device: QMIDevice
    private let work = DispatchQueue(label: "qmid.gnss.session")
    private let idLock = NSLock()
    private var currentID: UInt8?           // the LOC client's ID, under idLock (read on the manager queue)
    private var client: QMIClient?          // on `work`
    private var applied: Want?              // on `work`: what the modem runs now

    // Manager queue: what the last fix used, for the satellites' `used`; the satellite throttle.
    private var used: Set<SignalKey> = []
    private var usedIDs: Set<Int> = []
    private var lastSatellites = Date.distantPast
    private var lastShape: Set<String> = []     // tracked / used signals in the last satellites event
    static let satelliteInterval: TimeInterval = 5

    private struct SignalKey: Hashable { let id: Int; let signal: UInt64? }

    init(device: QMIDevice) {
        self.device = device
    }

    func owns(_ clientID: UInt8) -> Bool {
        idLock.lock(); defer { idLock.unlock() }
        return currentID == clientID
    }

    // Brings the modem to `want` (nil: no session, client released). `restart`: register and
    // Start again although nothing changed (after wake). `beforeStart` runs on `work` with the
    // LOC client right before a new session's Start (not on a restart or interval change): the
    // place for Inject UTC Time and Inject Position. `done` runs on `work`.
    func apply(_ want: Want?, restart: Bool = false, beforeStart: ((QMIClient) -> Void)? = nil,
               done: @escaping (String?) -> Void) {
        work.async {
            do {
                try self.bring(want, restart: restart, beforeStart: beforeStart)
                done(nil)
            } catch {
                done("\(error)")
            }
        }
    }

    // Runs `step` on `work` with the LOC client, after any pending apply; not at all if the
    // session has no client by then (stopped, or its Start failed).
    func withClient(_ step: @escaping (QMIClient) -> Void) {
        work.async {
            guard let c = self.client else { return }
            step(c)
        }
    }

    private func bring(_ want: Want?, restart: Bool, beforeStart: ((QMIClient) -> Void)?) throws {
        guard let want else {
            if let c = client {
                _ = try? c.request(LOC.stop, LOC.stopRequest(), timeout: 3)
                c.release()
            }
            client = nil
            applied = nil
            setID(nil)
            return
        }
        if restart { applied = nil }
        let c: QMIClient
        if let existing = client {
            c = existing
        } else {
            c = try device.allocateClient(.loc)
            client = c
            applied = nil
            setID(c.id)
        }
        let before = applied
        var events: LOC.EventMask = [.position, .engineState]
        if want.satellites { events.insert(.satellites) }
        if want.nmea { events.insert(.nmea) }
        if before == nil || before?.satellites != want.satellites || before?.nmea != want.nmea {
            try c.request(LOC.registerEvents, LOC.registerEventsRequest(events), timeout: 5)
        }
        if before?.interval != want.interval {
            if before != nil {
                _ = try? c.request(LOC.stop, LOC.stopRequest(), timeout: 3)
                applied = nil                   // stopped: if Start fails, the next apply starts afresh
            }
            if before == nil, !restart { beforeStart?(c) }
            try c.request(LOC.start, LOC.startRequest(intervalMs: UInt32(want.interval)), timeout: 5)
        }
        applied = want
    }

    private func setID(_ id: UInt8?) {
        idLock.lock(); currentID = id; idLock.unlock()
    }

    // MARK: - Indications (manager queue)

    func handle(_ m: QMIMessage) {
        switch m.messageID {
        case LOC.positionReport:
            guard let p = LOC.parsePosition(m) else { return }
            if p.status == 0 {
                used = Set(p.used.map { SignalKey(id: Int($0.id), signal: $0.signal) })
                usedIDs = Set(p.used.map { Int($0.id) })
            }
            onLocation?(Self.location(p))
        case LOC.satelliteInfo:
            let sats = LOC.parseSatellites(m).map { s -> QMIDSatellite in
                let key = SignalKey(id: Int(s.id), signal: s.signal)
                return QMIDSatellite(system: LOC.systemName(s.system) ?? "system \(s.system)", id: Int(s.id),
                                     signal: s.signal.flatMap(LOC.signalName), tracking: s.tracking,
                                     elevation: s.elevation.map(Double.init), azimuth: s.azimuth.map(Double.init),
                                     cn0: s.cn0.map(Double.init),
                                     used: s.signal == nil ? usedIDs.contains(key.id) : used.contains(key))
            }
            // Every 5 s, or sooner when a signal is gained, lost or starts / stops being used.
            let shape = Set(sats.filter { $0.tracking || $0.used }.map { "\($0.system) \($0.id) \($0.signal ?? "") \($0.used)" })
            guard shape != lastShape || Date().timeIntervalSince(lastSatellites) >= Self.satelliteInterval else { return }
            lastShape = shape
            lastSatellites = Date()
            onSatellites?(QMIDSatellites(satellites: sats, time: Date()))
        case LOC.nmea:
            if let s = LOC.parseNMEA(m) { onNMEA?(s) }
        case LOC.engineState:
            if let on = LOC.parseEngineOn(m) { onEngine?(on) }
        default:
            break
        }
    }

    static let technologies: [(bit: UInt32, name: String)] = [
        (1 << 0, "satellite"), (1 << 1, "cellular"), (1 << 2, "wifi"), (1 << 3, "sensors"),
        (1 << 4, "reference"), (1 << 5, "injected"), (1 << 6, "aflt"), (1 << 7, "hybrid"),
    ]

    static func location(_ p: LOC.Position) -> QMIDLocation {
        var l = QMIDLocation(fix: p.status == 0 ? .fix : p.status == 1 ? .intermediate : .failed)
        guard p.status <= 1 else { return l }
        l.latitude = p.latitude
        l.longitude = p.longitude
        l.horizontalAccuracy = p.horizontalAccuracy.map(Double.init)
        l.altitude = p.altitude.map(Double.init)
        l.altitudeMSL = p.altitudeMSL.map(Double.init)
        l.verticalAccuracy = p.verticalAccuracy.map(Double.init)
        l.speed = p.speed.map(Double.init)
        l.verticalSpeed = p.verticalSpeed.map(Double.init)
        l.heading = p.heading.map(Double.init)
        l.time = p.timeKnown ? p.time : nil
        l.satellitesUsed = p.used.isEmpty ? nil : Set(p.used.map(\.id)).count
        l.technology = p.technology.map { t in technologies.filter { t & $0.bit != 0 }.map(\.name) } ?? []
        return l
    }
}
