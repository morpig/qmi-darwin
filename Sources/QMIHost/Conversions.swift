import Foundation
import QMIDAPI
import QMIKit

// What the modem reports (QMIKit) as clients see it (QMIDAPI).

// A PLMN as NAS reports it (Serving System).
struct PLMNID: Equatable {
    let mcc: UInt16
    let mnc: UInt16

    // 3-digit MNCs below 100 can't be told from 2-digit ones here: written with 2 digits.
    var mccmnc: String { String(format: "%03d", mcc) + String(format: mnc > 99 ? "%03d" : "%02d", mnc) }

    // On the SIM's home network (its MCC/MNC, "00101" / "001001").
    func isHome(_ home: String?) -> Bool {
        guard let h = home, h.count >= 5 else { return false }
        return Int(h.prefix(3)) == Int(mcc) && Int(h.dropFirst(3)) == Int(mnc)
    }
}

extension UIM.Card {
    // The card a status reports for: the first present one, else the first.
    static func main(of cards: [UIM.Card]) -> UIM.Card? { cards.first { $0.isPresent } ?? cards.first }

    var simCardState: QMIDSIM.CardState {
        switch cardState {
        case .absent: return .absent
        case .present: return .present
        case .error, .unknown: return .error
        }
    }
}

extension UIM.Card.PIN {
    var simState: QMIDSIM.PINState {
        switch state {
        case 0, 3: return .disabled
        case 1: return .required
        case 2: return .verified
        case 4: return .pukRequired
        case 5: return .blocked
        default: return .unknown
        }
    }
}

extension QMIDRRCState {
    // Get ARFCN List RRC states (NAS IDL enums).
    init?(lte v: UInt32) {
        switch v {
        case 1, 2, 7: self = .idle
        case 3: self = .connecting
        case 4: self = .connected
        case 5: self = .releasing
        case 6: self = .inactive
        case 8: self = .suspended
        default: return nil
        }
    }

    init?(nr v: UInt32) {
        guard let s = [0: Self.idle, 1: .connected, 2: .inactive][v] else { return nil }
        self = s
    }
}

extension QMIDCell {
    init(_ c: NAS.Cell) {
        let rat: RAT = c.rat == .lte ? .lte : .nr
        self.init(rat: rat, role: c.role == .primary ? .primary : c.role == .secondary ? .secondary : .neighbor)
        channel = c.channel.map(Int.init)
        band = c.band ?? channel.flatMap { Self.band(rat, channel: $0) }   // the modem's, else from the channel
        pci = c.pci.map(Int.init)
        cellID = c.cellID
        tac = c.tac.map(Int.init)
        bandwidth = c.bandwidthMHz
        rsrp = c.rsrp
        rsrq = c.rsrq
        rssi = c.rssi
        snr = c.snr
        active = c.active
        scellIndex = c.scellIndex.map(Int.init)
        pscell = c.pscell
    }
}

extension QMIDRadio {
    // What a radio event is pushed for: the serving cells (as QMIDRadio.serving counts them) without their signal, EN-DC and the
    // RRC states. Signal and neighbours change all the time.
    static func eventKey(_ d: NSDictionary) -> NSDictionary {
        let signal: Set<String> = [QMIDKey.rsrp, QMIDKey.rsrq, QMIDKey.rssi, QMIDKey.snr]
        let serving = (d[QMIDKey.cells] as? [NSDictionary] ?? [])
            .filter { [QMIDCell.Role.primary.rawValue, QMIDCell.Role.secondary.rawValue].contains($0[QMIDKey.role] as? String) }
            .map { c in (c as? [String: Any] ?? [:]).filter { !signal.contains($0.key) } as NSDictionary }
        var k: [String: Any] = [QMIDKey.cells: serving]
        for key in [QMIDKey.endcAvailable, QMIDKey.lteRRC, QMIDKey.nrRRC] { k[key] = d[key] }
        return k as NSDictionary
    }
}

extension QMIDAMBR {
    init(_ a: WDS.AMBR) { self.init(uplink: a.uplink, downlink: a.downlink) }
}

extension QMIDBearer {
    init(_ b: QoS.Bearer) {
        func rates(_ r: QoS.Bitrates) -> QMIDBitrates { QMIDBitrates(max: r.max, guaranteed: r.guaranteed) }
        func filter(_ f: QoS.PacketFilter) -> QMIDPacketFilter {
            var q = QMIDPacketFilter(id: Int(f.id), precedence: Int(f.precedence), ipVersion: Int(f.ipVersion))
            q.source = f.source?.description
            q.destination = f.destination?.description
            q.ipProtocol = f.ipProtocol.map(Int.init)
            q.sourcePorts = f.sourcePorts.map { Int($0.lowerBound)...Int($0.upperBound) }
            q.destinationPorts = f.destinationPorts.map { Int($0.lowerBound)...Int($0.upperBound) }
            return q
        }
        self.init(id: Int(b.qosID), qci: b.qci.map(Int.init), networkInitiated: b.networkInitiated,
                  uplink: rates(b.uplink.rates), downlink: rates(b.downlink.rates),
                  uplinkFilters: b.uplinkFilters.map(filter), downlinkFilters: b.downlinkFilters.map(filter))
    }
}
