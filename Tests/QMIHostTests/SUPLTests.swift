import XCTest
@testable import QMIHost

// Vectors from pycrate's ULP and LPP modules (unaligned PER), test PLMN 001-01 and made-up
// cells and positions.
final class SUPLTests: XCTestCase {
    private func hex(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map { UInt8(s.dropFirst($0).prefix(2), radix: 16)! }
    }
    private let cell = SUPL.Cell(mcc: "001", mnc: "01", cellID: 0x1234567, tac: 0x0102, pci: 301)
    private let slpFQDN = "0023020000c0004c000404850d961fe404080c110fe3ad7106af66cb5c6a068d322008"   // a SUPL RESPONSE

    func testStart() throws {
        XCTAssertEqual(try SUPL.start(cell),
                       hex("002602000080004c000404850d961fe441830020818300000800b20200201123456796808102"))
        XCTAssertEqual(try SUPL.start(SUPL.Cell(mcc: "001", mnc: "001", cellID: 0xFFFFFFF, tac: 0xFFFF, pci: 503)),
                       hex("002702000080004c000404850d961fe441830020818300000800c202003001ffffffffbffff802"))
    }

    func testStartRejectsBadCell() {
        XCTAssertThrowsError(try SUPL.start(SUPL.Cell(mcc: "01", mnc: "01", cellID: 1, tac: 1, pci: 1)))
        XCTAssertThrowsError(try SUPL.start(SUPL.Cell(mcc: "001", mnc: "01", cellID: 1 << 28, tac: 1, pci: 1)))
        XCTAssertThrowsError(try SUPL.start(SUPL.Cell(mcc: "001", mnc: "01", cellID: 1, tac: 1, pci: 504)))
    }

    func testResponseAndPosInitEchoesSLPSession() throws {
        let r = try SUPL.decode(hex(slpFQDN))
        XCTAssertEqual(r.message, .response)
        let slp = try XCTUnwrap(r.slp)
        XCTAssertEqual(try SUPL.posInit(cell, slp: slp),
                       hex("0039020000c0004c000404850d961fe404080c110fe3ad7106af66cb5c6a068d32340c1801040c180000020800b20200201123456796808102"))
    }

    func testPosInitIPv4Session() throws {
        // slpSessionID 0a0b0c0d with an IPv4 SLP address, as raw bits taken from a full PDU
        let full = hex("0030020000c0004c000404850d961fe4282c3034600001009a060c0082060c0000010400590100100891a2b3cb404081")
        var w = BitWriter()
        var r = BitReader(full)
        _ = try r.bits(16 + 24 + 2 + 16 + 1 + 3 + 64)     // up to the slpSessionID
        let from = r.position
        _ = try r.bits(32 + 1 + 1 + 1 + 32)
        w.append(r.slice(from: from))
        XCTAssertEqual(try SUPL.posInit(cell, slp: w.bits), full)
    }

    func testPosWithReferenceLocation() throws {
        let pos = try SUPL.decode(hex("003b020000c0004c000404850d961fe404080c110fe3ad7106af66cb5c6a068d3242005d0002720023046210000010000000190f945aff10000000"))
        guard case .pos(let lpp) = pos.message else { return XCTFail("\(pos.message)") }
        XCTAssertEqual(lpp, [hex("900118231080000080000000c87ca2d7f8800000")])
        let loc = try XCTUnwrap(try SUPL.referenceLocation(lpp: lpp[0]))
        XCTAssertEqual(loc.latitude, 45, accuracy: 1e-9)          // 4194304 of 2^23 × 90°, north
        XCTAssertEqual(loc.longitude, -90, accuracy: 1e-9)        // -4194304 of 2^24 × 360°
        XCTAssertEqual(loc.semiMajor, 10 * (pow(1.1, 31) - 1), accuracy: 0.01)   // ~182 m
        XCTAssertEqual(loc.semiMinor, 10 * (pow(1.1, 20) - 1), accuracy: 0.01)
        XCTAssertEqual(loc.confidence, 68)
        XCTAssertNil(loc.altitude)                                 // uncertainty 127: unknown
    }

    func testEnd() throws {
        XCTAssertEqual(try SUPL.decode(hex("0022020000c0004c000404850d961fe404080c110fe3ad7106af66cb5c6a068d3250")).message, .end(status: nil))
        XCTAssertEqual(try SUPL.decode(hex("0023020000c0004c000404850d961fe404080c110fe3ad7106af66cb5c6a068d32523c")).message,
                       .end(status: 15))                          // positioningNotPermitted
    }

    func testDecodeRejectsBadLength() {
        XCTAssertThrowsError(try SUPL.decode(hex("00230200")))
        XCTAssertThrowsError(try SUPL.decode(hex(String(slpFQDN.dropLast(2)))))
    }

    func testTBCD() {
        XCTAssertEqual(SUPL.tbcd("001010123456789"), hex("000101214365879f").map { $0 } .enumerated().map { $0.offset == 7 ? 0xF9 : $0.element })
    }
}

final class SUPLConfigTests: XCTestCase {
    func testEndpoint() {
        XCTAssertEqual(QMIDConfig.SUPLSettings().endpoint?.host, "supl.google.com")
        XCTAssertEqual(QMIDConfig.SUPLSettings().endpoint?.port, 7275)
        XCTAssertTrue(QMIDConfig.SUPLSettings().on)
        XCTAssertEqual(QMIDConfig.SUPLSettings(enabled: false, server: "supl.example.com:7276").endpoint?.port, 7276)
        XCTAssertNil(QMIDConfig.SUPLSettings(enabled: true, server: "supl.example.com").endpoint)
        XCTAssertNil(QMIDConfig.SUPLSettings(enabled: true, server: ":7275").endpoint)
    }

    func testDistance() {
        XCTAssertEqual(Manager.distance(0, 0, 0, 1), 111_195, accuracy: 1)
        XCTAssertEqual(Manager.distance(10, 20, 10, 20), 0, accuracy: 1e-6)
    }
}
