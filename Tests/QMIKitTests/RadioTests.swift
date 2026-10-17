@testable import QMIKit
import XCTest

final class RadioTests: XCTestCase {
    private func response(_ id: UInt16, _ tlvs: [(UInt8, String)]) throws -> QMIMessage {
        let m = QMIMessage(service: .nas, clientID: 1, kind: .response, transactionID: 1, messageID: id,
                           tlvs: [TLV(0x02, [0, 0, 0, 0])] + tlvs.map { TLV($0.0, [UInt8](hex: $0.1)!) })
        return try QMIMessage.decode(m.encoded())
    }

    // RM551E on LTE B3 + B1 (SCell configured, not activated), EN-DC available, NR on n41.
    // PLMN, TAC and cell ID replaced by test values (001-01, TAC 0x1234, ECI 0x01234504).
    func testLTECarrierAggregationAndNR() throws {
        let sys = try response(NAS.getSysInfo, [(0x4A, "00 00 00"), (0x4E, "01"), (0x54, "b9 00"), (0x60, "9e b4 07 00")])
        let loc = try response(NAS.getCellLocationInfo, [
            (0x13, "00 00 f1 10 34 12 04 45 23 01 21 05 10 01 00 00 00 00 02 10 01 65 ff 31 fc 6a fd 00 00 ef 00 4c ff 14 fc 18 fd 00 00"),
            (0x14, "00 01 45 01 00 00 00 02 42 00 53 ff 05 fc 11 fd 00 00 ef 00 52 ff 09 fc 11 fd 00 00"),
            (0x27, "21 05 00 00"), (0x28, "01 45 01 00 00"), (0x2E, "9e b4 07 00"),
        ])
        let sig = try response(NAS.getSignalInfo, [(0x14, "bd f2 a0 ff 82 00"), (0x17, "a6 ff 69 00"), (0x18, "f5 ff")])
        let rf = try response(NAS.getRFBandInfo, [(0x01, "01 08 7a 00 21 05"), (0x12, "01 08 05 00 00 00")])
        let ca = try response(NAS.getLTECPHYCAInfo, [
            (0x13, "10 01 21 05 05 00 00 00 7a 00"),
            (0x15, "01 42 00 45 01 04 00 00 00 78 00 01 00 00 00 01"),
            (0x19, "01 42 00 45 01 00 00 04 00 00 00 78 00 01 00 00 00 01 00"),
        ])
        let info = NAS.radioCells(sysInfo: sys, cellLocation: loc, signal: sig, rfBand: rf, ca: ca)
        XCTAssertEqual(info.endcAvailable, true)
        XCTAssertEqual(info.cells.count, 5)

        var pcell = NAS.Cell(rat: .lte, role: .primary)
        pcell.channel = 1313; pcell.pci = 272; pcell.cellID = 0x01234504; pcell.tac = 0x1234
        pcell.bandwidthMHz = 20; pcell.rssi = -67; pcell.rsrq = -14; pcell.rsrp = -96; pcell.snr = 13
        XCTAssertEqual(info.cells[0], pcell)

        var nr = NAS.Cell(rat: .nr, role: .secondary)
        nr.channel = 504990; nr.pci = 185; nr.rsrp = -90; nr.snr = 10.5; nr.rsrq = -11
        XCTAssertEqual(info.cells[2], nr)

        var scell = NAS.Cell(rat: .lte, role: .secondary)
        scell.channel = 325; scell.pci = 66; scell.bandwidthMHz = 15; scell.active = false; scell.scellIndex = 1
        scell.rsrq = -17.3; scell.rsrp = -101.9; scell.rssi = -75.1
        XCTAssertEqual(info.cells[1], scell)

        XCTAssertEqual(info.cells[3...].map { "\($0.channel!)/\($0.pci!)/\($0.role)" }, ["1313/239/neighbor", "325/239/neighbor"])
        XCTAssertEqual(info.cells[3].rsrp, -100.4)
    }

    // COEX Get WWAN State on n41: SSB at NR-ARFCN 531870 (2659.35 MHz) inside the 60 MHz DL
    // carrier centred on 2660.010 MHz (AT+QCAINFO: bandwidth code 8).
    func testNRBandwidthFromCOEX() throws {
        let loc = try response(NAS.getCellLocationInfo, [(0x2E, "9e 1d 08 00")])
        let coex = try response(NAS.coexGetWWANState, [
            (0x22, "02 aa 96 28 00 00 87 93 03 02 00 00 00 00 00 00 00 aa 96 28 00 00 87 93 03 01 00 00 00 00 00 00 00"),
        ])
        let info = NAS.radioCells(sysInfo: nil, cellLocation: loc, signal: nil, rfBand: nil, ca: nil, coex: coex)
        XCTAssertEqual(info.cells.first?.channel, 531870)
        XCTAssertEqual(info.cells.first?.bandwidthMHz, 60)
    }

    // NR5G Cell Information (0x2F): PLMN 001-01, TAC 0x000102 (most significant byte first),
    // NCI 0x123456789, PCI 185.
    func testNRCellInformation() throws {
        let loc = try response(NAS.getCellLocationInfo, [
            (0x2F, "00 f1 10 00 01 02 89 67 45 23 01 00 00 00 b9 00 92 ff 2e fc 9b 00"),
        ])
        let nr = try XCTUnwrap(NAS.radioCells(sysInfo: nil, cellLocation: loc, signal: nil, rfBand: nil, ca: nil).cells.first)
        XCTAssertEqual(nr.tac, 0x000102)
        XCTAssertEqual(nr.cellID, 0x123456789)
        XCTAssertEqual(nr.pci, 185)
    }

    func testNothingReported() {
        XCTAssertEqual(NAS.radioCells(sysInfo: nil, cellLocation: nil, signal: nil, rfBand: nil, ca: nil), NAS.RadioInfo())
    }
}
