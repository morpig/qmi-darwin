@testable import QMIHost
import QMIDAPI
import QMIKit
import XCTest

// qmid's bearer dictionaries (Manager.bearerInfo) decoded by the client library (QMIDBearer).
final class BearerEncodingTests: XCTestCase {
    private func filter(_ id: UInt8, _ precedence: UInt16, v: UInt8, src: String? = nil, dst: String? = nil,
                        len: Int, proto: UInt8? = nil, sport: ClosedRange<UInt16>? = nil,
                        dport: ClosedRange<UInt16>? = nil) -> QoS.PacketFilter {
        var f = QoS.PacketFilter(id: id, precedence: precedence, ipVersion: v)
        f.source = src.map { QoS.Prefix(address: $0, length: len) }
        f.destination = dst.map { QoS.Prefix(address: $0, length: len) }
        f.ipProtocol = proto
        f.sourcePorts = sport
        f.destinationPorts = dport
        return f
    }

    // A network-created CDN bearer on a dual-stack internet PDN (merged IPv4 + IPv6 views).
    func testCDNBearerRoundTrip() throws {
        var b = QoS.Bearer(qosID: 0xc3d)
        b.uplink = QoS.Flow(qci: 4, rates: QoS.Bitrates(max: 64_000_000, guaranteed: 2_560_000))
        b.downlink = QoS.Flow(qci: 4, rates: QoS.Bitrates(max: 128_000_000, guaranteed: 2_560_000))
        b.uplinkFilters = [
            filter(1, 190, v: 6, dst: "2001:db8:0:c0::", len: 59),
            filter(0, 191, v: 4, dst: "203.0.113.192", len: 27),
            filter(6, 9, v: 6, dst: "2001:db8:f30a:120::167", len: 128, proto: 6,
                   sport: 53068...53068, dport: 5222...5222),
        ]
        b.downlinkFilters = [filter(0, 191, v: 4, src: "203.0.113.192", len: 27)]
        b.networkInitiated = true
        b.bearerID = 0x37

        let d = Manager.bearerInfo(b)
        XCTAssertNil(d["bearerID"])                         // not exposed
        let c = try XCTUnwrap(QMIDBearer(d))
        XCTAssertEqual(c.id, 0xc3d)
        XCTAssertEqual(c.qci, 4)
        XCTAssertEqual(c.networkInitiated, true)
        XCTAssertTrue(c.isGBR)
        XCTAssertEqual(c.uplink, QMIDBitrates(max: 64_000_000, guaranteed: 2_560_000))
        XCTAssertEqual(c.downlink, QMIDBitrates(max: 128_000_000, guaranteed: 2_560_000))
        XCTAssertEqual(c.uplinkFilters.map(\.destination),
                       ["2001:db8:0:c0::/59", "203.0.113.192/27", "2001:db8:f30a:120::167/128"])
        XCTAssertEqual(c.uplinkFilters.map(\.ipVersion), [6, 4, 6])
        let chat = c.uplinkFilters[2]
        XCTAssertEqual(chat.id, 6)
        XCTAssertEqual(chat.precedence, 9)
        XCTAssertEqual(chat.ipProtocol, 6)
        XCTAssertEqual(chat.sourcePorts, 53068...53068)
        XCTAssertEqual(chat.destinationPorts, 5222...5222)
        XCTAssertNil(chat.source)
        XCTAssertEqual(c.downlinkFilters.map(\.source), ["203.0.113.192/27"])
    }

    // A non-GBR bearer the modem said nothing else about: optional fields stay nil.
    func testSparseBearer() throws {
        var b = QoS.Bearer(qosID: 7)
        b.uplink = QoS.Flow(qci: 8)
        let c = try XCTUnwrap(QMIDBearer(Manager.bearerInfo(b)))
        XCTAssertEqual(c.qci, 8)
        XCTAssertNil(c.networkInitiated)
        XCTAssertFalse(c.isGBR)
        XCTAssertEqual(c.uplink, QMIDBitrates())
        XCTAssertEqual(c.uplinkFilters, [])
    }

    func testAMBRDescription() {
        XCTAssertEqual(Manager.describe(WDS.AMBR(uplink: 10_200_000, downlink: 10_200_000)), "10.2/10.2 Mbps")
        XCTAssertEqual(Manager.describe(WDS.AMBR(uplink: 2_000_000_000, downlink: 2_000_000_000)), "2000/2000 Mbps")
        XCTAssertEqual(Manager.describe(nil), "?")
    }
}
