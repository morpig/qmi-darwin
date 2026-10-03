@testable import QMIKit
import XCTest

final class WDATests: XCTestCase {
    // What the RM551E grants for WDA.Request's defaults.
    private func granted(_ extra: [TLV] = []) -> WDA.Granted {
        let m = QMIMessage(service: .wda, clientID: 1, kind: .response, transactionID: 1,
                           messageID: WDA.setDataFormat,
                           tlvs: [.u8(0x10, 0), .u32(0x11, 2), .u32(0x12, 5), .u32(0x13, 5),
                                  .u32(0x15, 32), .u32(0x16, 31744), .u32(0x17, 32), .u32(0x18, 16384)] + extra)
        return WDA.parseGranted(m)
    }

    func testUsableGrant() {
        let g = granted()
        XCTAssertEqual(g.uplinkAggregation, WDA.Aggregation.qmap.rawValue)
        XCTAssertEqual(g.uplinkMaxSize, 16384)
        XCTAssertNil(g.datapathProblem)
    }

    func testRefusesOtherFormats() {
        var g = granted()
        g.uplinkAggregation = WDA.Aggregation.disabled.rawValue
        XCTAssertEqual(g.datapathProblem, "uplink aggregation 0, not QMAP")

        g = granted()
        g.downlinkAggregation = WDA.Aggregation.qmapV5.rawValue
        XCTAssertEqual(g.datapathProblem, "downlink aggregation 9, not QMAP")

        g = granted()
        g.linkLayer = WDA.LinkLayer.ethernet.rawValue
        XCTAssertEqual(g.datapathProblem, "link layer 1, not raw IP")

        g = granted()
        g.qosFormat = true
        XCTAssertEqual(g.datapathProblem, "QoS header on")
    }

    func testAbsentTLVs() {
        // Link layer and downlink must be there; absent uplink/QoS are taken as requested.
        var g = granted()
        g.uplinkAggregation = nil
        g.qosFormat = nil
        XCTAssertNil(g.datapathProblem)
        g.downlinkAggregation = nil
        XCTAssertEqual(g.datapathProblem, "downlink aggregation absent, not QMAP")
        XCTAssertEqual(WDA.Granted().datapathProblem, "link layer absent, not raw IP")
    }
}
