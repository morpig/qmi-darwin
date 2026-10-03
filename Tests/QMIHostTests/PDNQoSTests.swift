@testable import QMIHost
import QMIKit
import XCTest

// How Event Reports and snapshots combine into a PDN's bearer list.
final class PDNQoSTests: XCTestCase {
    private func tlv(_ type: UInt8, _ v: [UInt8]) -> [UInt8] { [type, UInt8(v.count & 0xff), UInt8(v.count >> 8)] + v }

    // An Event Report for one flow: state 1 created, 2 modified, 3 deleted, 5/6 flow control.
    private func report(_ id: UInt32, state: UInt8, filters: Int = 1, network: Bool? = nil) -> QMIMessage {
        var flow = tlv(0x10, [UInt8(id & 0xff), UInt8(id >> 8 & 0xff), 0, 0, state == 1 ? 1 : 0, state])
        if state == 1 || state == 2 {
            let f = (0..<filters).map { i in
                tlv(0x10, tlv(0x23, [UInt8(i), 1]) + tlv(0x22, [UInt8(i), 0]) + tlv(0x13, [1, 1, 1, UInt8(i), 0xff, 0xff, 0xff, 0xff]) + tlv(0x11, [4]))
            }.flatMap { $0 }
            flow += tlv(0x13, f) + tlv(0x11, tlv(0x10, tlv(0x1F, [4])))
            if let n = network { flow += tlv(0x15, [n ? 1 : 0]) + tlv(0x16, [0x37]) }
        }
        return QMIMessage(service: .qos, clientID: 1, kind: .indication, transactionID: 1, messageID: QoS.eventReport, tlvs: [TLV(0x10, flow)])
    }

    func testCreateModifyDelete() {
        let created = PDNQoS.apply(report(0xc3d, state: 1, network: true), to: [])
        XCTAssertEqual(created.bearers.map(\.qosID), [0xc3d])
        XCTAssertEqual(created.touched, [0xc3d])
        XCTAssertEqual(created.bearers[0].networkInitiated, true)

        // Modify: three filters now; the creation-only fields stay.
        let modified = PDNQoS.apply(report(0xc3d, state: 2, filters: 3), to: created.bearers)
        XCTAssertEqual(modified.bearers[0].uplinkFilters.count, 3)
        XCTAssertEqual(modified.bearers[0].networkInitiated, true)
        XCTAssertEqual(modified.bearers[0].bearerID, 0x37)

        // The same report again (the modem sends each twice) and flow control change nothing.
        XCTAssertEqual(PDNQoS.apply(report(0xc3d, state: 2, filters: 3), to: modified.bearers).bearers, modified.bearers)
        XCTAssertEqual(PDNQoS.apply(report(0xc3d, state: 5), to: modified.bearers).bearers, modified.bearers)
        XCTAssertEqual(PDNQoS.apply(report(0, state: 6), to: modified.bearers).bearers, modified.bearers)

        let deleted = PDNQoS.apply(report(0xc3d, state: 3), to: modified.bearers)
        XCTAssertEqual(deleted.bearers, [])
        XCTAssertEqual(deleted.deleted, [0xc3d])
    }

    func testDeletionOfUnlistedBearerDuringSnapshot() {
        // A snapshot is reading bearer 1 when its deletion arrives, before the list has it: the
        // deletion is still reported, so combine() doesn't bring it back.
        let deleted = PDNQoS.apply(report(1, state: 3), to: [])
        XCTAssertEqual(deleted.bearers, [])
        XCTAssertEqual(deleted.deleted, [1])
        XCTAssertEqual(PDNQoS.combine(snapshot: [bearer(1)], current: deleted.bearers,
                                      touchedSince: deleted.touched, deletedSince: deleted.deleted), [])
    }

    func testRecreatedDuringSnapshot() {
        // The snapshot lists bearer 1; it's deleted and created again before the snapshot ends:
        // the latest event wins, so it stays.
        let gone = PDNQoS.apply(report(1, state: 3), to: [bearer(1)])
        let back = PDNQoS.apply(report(1, state: 1), to: gone.bearers)
        var touched = gone.touched, deleted = gone.deleted
        touched.subtract(back.deleted); touched.formUnion(back.touched)
        deleted.subtract(back.touched); deleted.formUnion(back.deleted)
        XCTAssertEqual(deleted, [])
        XCTAssertEqual(PDNQoS.combine(snapshot: [bearer(1)], current: back.bearers,
                                      touchedSince: touched, deletedSince: deleted).map(\.qosID), [1])
    }

    func testSecondBearer() {
        // A network may open a second QCI 4 bearer once the first has ~14 filters.
        let one = PDNQoS.apply(report(0xf8b, state: 1, filters: 14), to: [])
        let two = PDNQoS.apply(report(0xf8c, state: 1, filters: 2), to: one.bearers)
        XCTAssertEqual(two.bearers.map(\.qosID), [0xf8b, 0xf8c])
        XCTAssertEqual(two.bearers.map { $0.uplinkFilters.count }, [14, 2])
    }

    private func bearer(_ id: UInt32, filters: Int = 0) -> QoS.Bearer {
        var b = QoS.Bearer(qosID: id)
        b.uplink = QoS.Flow(qci: 4)
        b.uplinkFilters = (0..<filters).map { QoS.PacketFilter(id: UInt8($0), precedence: UInt16($0), ipVersion: 4) }
        return b
    }

    func testSnapshotAtConnect() {
        // Bearers that exist already: granted QCI and rates, filters with their next report.
        XCTAssertEqual(PDNQoS.combine(snapshot: [bearer(1), bearer(2)], current: [], touchedSince: [], deletedSince: []),
                       [bearer(1), bearer(2)])
    }

    func testSnapshotKeepsReportedFilters() {
        // A report arrived (with filters) while the snapshot ran: the reported version wins.
        let reported = bearer(1, filters: 5)
        XCTAssertEqual(PDNQoS.combine(snapshot: [bearer(1)], current: [reported], touchedSince: [1], deletedSince: []),
                       [reported])
        // After wake: known bearers keep their filters, ones gone while asleep disappear.
        XCTAssertEqual(PDNQoS.combine(snapshot: [bearer(1)], current: [reported, bearer(2, filters: 1)],
                                      touchedSince: [], deletedSince: []), [reported])
    }

    func testSnapshotAndReportsRace() {
        // Created after the snapshot's query: kept. Deleted after it: not brought back.
        XCTAssertEqual(PDNQoS.combine(snapshot: [bearer(1), bearer(2)], current: [bearer(1, filters: 2), bearer(3, filters: 1)],
                                      touchedSince: [3], deletedSince: [2]),
                       [bearer(1, filters: 2), bearer(3, filters: 1)])
    }
}
