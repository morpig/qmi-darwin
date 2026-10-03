@testable import QMIKit
import XCTest

final class SIMTests: XCTestCase {
    private func response(_ service: QMIService, _ id: UInt16, _ tlvs: [TLV]) throws -> QMIMessage {
        let m = QMIMessage(service: service, clientID: 1, kind: .response, transactionID: 1, messageID: id,
                           tlvs: [TLV(0x02, [0, 0, 0, 0])] + tlvs)
        return try QMIMessage.decode(m.encoded())
    }

    func testLTEEmergency() throws {
        // Get Sys Info: 0x39 bearers, 0x3E barred (neither here).
        let r = try response(.nas, NAS.getSysInfo, [TLV(0x39, [0]), TLV(0x3E, [0, 0, 0, 0])])
        XCTAssertEqual(NAS.parseLTEEmergency(r), NAS.LTEEmergency(bearers: false, accessBarred: false))
        let yes = try response(.nas, NAS.getSysInfo, [TLV(0x39, [1, 0, 0, 0])])
        XCTAssertEqual(NAS.parseLTEEmergency(yes), NAS.LTEEmergency(bearers: true, accessBarred: nil))
        // The indication carries them one TLV up; the response's numbers mean something else there.
        let ind = QMIMessage(service: .nas, clientID: 1, kind: .indication, transactionID: 1,
                             messageID: NAS.sysInfoIndication, tlvs: [TLV(0x39, [1]), TLV(0x3A, [1]), TLV(0x3F, [0])])
        XCTAssertEqual(NAS.parseLTEEmergency(try QMIMessage.decode(ind.encoded())),
                       NAS.LTEEmergency(bearers: true, accessBarred: false))
        XCTAssertEqual(NAS.parseLTEEmergency(try response(.nas, NAS.getSysInfo, [])), NAS.LTEEmergency())
        // 2 while searching (during a SIM switch): unknown, not "supported".
        let searching = try response(.nas, NAS.getSysInfo, [TLV(0x39, [2, 0, 0, 0]), TLV(0x3E, [0, 1, 0, 0])])
        XCTAssertEqual(NAS.parseLTEEmergency(searching), NAS.LTEEmergency())
    }

    func testHomeNetwork() throws {
        // MCC 001, MNC 01, name "EX".
        let home = try NAS.parseHomeNetwork(response(.nas, NAS.getHomeNetwork,
            [TLV(0x01, [0x01, 0x00, 0x01, 0x00, 2] + Array("EX".utf8)), TLV(0x13, [1, 0])]))
        XCTAssertEqual(home.mccmnc, "00101")
        XCTAssertEqual(home.name, "EX")
        // 3-digit MNC from the PCS-digit flag: 001-026 is not 001-26.
        let t = try NAS.parseHomeNetwork(response(.nas, NAS.getHomeNetwork,
            [TLV(0x01, [0x01, 0x00, 0x1a, 0x00, 0]), TLV(0x13, [1, 1])]))
        XCTAssertEqual(t.mccmnc, "001026")
        XCTAssertNil(t.name)
        // No flag TLV: an MNC above 99 is 3 digits anyway.
        let u = try NAS.parseHomeNetwork(response(.nas, NAS.getHomeNetwork, [TLV(0x01, [0x01, 0x00, 0x04, 0x01, 0])]))
        XCTAssertEqual(u.mccmnc, "001260")
        XCTAssertThrowsError(try NAS.parseHomeNetwork(response(.nas, NAS.getHomeNetwork, [])))
    }

    func testICCIDFromDMS() throws {
        let r = try response(.dms, DMS.uimGetICCID, [TLV(0x01, Array("8900016123456789012F".utf8))])
        XCTAssertEqual(DMS.parseICCID(r), "8900016123456789012")
        XCTAssertNil(DMS.parseICCID(try response(.dms, DMS.uimGetICCID, [TLV(0x01, Array("123".utf8))])))
    }

    func testICCIDFromEF() throws {
        // EF_ICCID bytes for 8900016123456789012 + F padding: nibbles swapped per byte.
        let ef: [UInt8] = [0x98, 0x00, 0x10, 0x16, 0x32, 0x54, 0x76, 0x98, 0x10, 0xF2]
        let r = try response(.uim, UIM.readTransparent, [TLV(0x11, [UInt8(ef.count), 0] + ef)])
        XCTAssertEqual(UIM.parseICCID(r), "8900016123456789012")
        XCTAssertEqual(UIM.readICCIDRequest[1], TLV(0x02, [0xE2, 0x2F, 0x02, 0x00, 0x3F]))
    }

    private func hex(_ s: String) -> [UInt8] { s.split(separator: " ").map { UInt8($0, radix: 16)! } }

    func testNITZName() throws {
        // Get Operator Name Data on a Quectel 2c7c:0122 (layout as captured): packed GSM 7-bit.
        let nitz = TLV(0x14, hex("00 00 00 00 14 45 7c b8 0d 67 97 41 cd b7 38 cd 2e 83 9c 65 fa fd 2d 5f 03 09 45 7c b8 0d 67 97 9d 65 3a"))
        let spn = TLV(0x10, hex("00 0a 45 78 61 6d 70 6c 65 4e 65 74"))
        let n = NAS.parseNITZName(try response(.nas, NAS.getOperatorNameData, [spn, nitz]))
        XCTAssertEqual(n, NAS.NetworkName(longName: "Example Mobile Network", shortName: "ExampleNet"))
        // Detached: only the SPN, no network names.
        XCTAssertNil(NAS.parseNITZName(try response(.nas, NAS.getOperatorNameData, [spn])))
        // UCS-2.
        let u = NAS.parseNITZName(try response(.nas, NAS.getOperatorNameData, [TLV(0x14, [1, 0, 0, 0, 4, 0, 0x45, 0, 0x58, 0])]))
        XCTAssertEqual(u, NAS.NetworkName(longName: "EX"))
    }

    func testGSM7SpareBits() {
        // 7 characters fill 7 bytes with 7 spare bits; they must not read as a trailing "@".
        XCTAssertEqual(NAS.gsm7Unpacked(hex("d4 f2 9c 9e 76 9f 01")), "Testing")
        XCTAssertEqual(NAS.gsm7Unpacked(hex("e8 32 9b fd 06")), "hello")
    }

    func testPLMNName() throws {
        // Get PLMN Name, same modem: SPN, short "EX", long "ExampleNet", unpacked 8-bit.
        let r = try response(.nas, NAS.getPLMNName,
            [TLV(0x10, hex("00 0a 45 78 61 6d 70 6c 65 4e 65 74 00 00 00 02 45 58 00 00 00 0a 45 78 61 6d 70 6c 65 4e 65 74")),
             TLV(0x15, hex("04 00 00 00"))])
        XCTAssertEqual(try NAS.parsePLMNName(r), NAS.NetworkName(longName: "ExampleNet", shortName: "EX"))
        XCTAssertEqual(NAS.plmnNameRequest(mcc: 1, mnc: 2), [TLV(0x01, [0x01, 0x00, 0x02, 0x00])])
        // A PLMN without a table entry: the "names" are the MCC/MNC as text.
        let none = try response(.nas, NAS.getPLMNName,
            [TLV(0x10, [0, 0, 0, 0, 0, 6] + Array("001 01".utf8) + [0, 0, 0, 6] + Array("001 01".utf8))])
        XCTAssertEqual(try NAS.parsePLMNName(none), NAS.NetworkName())
    }

    func testSIMNames() throws {
        // SIM with home 001-01, Get Operator Name Data on a Quectel 2c7c:0122 (layout as
        // captured): SPN, one OPL entry 001-01 → PNN record 1, PNN "Home Mobile" (packed GSM
        // 7-bit) for long and short.
        let r = try response(.nas, NAS.getOperatorNameData, [
            TLV(0x10, hex("00 0b 48 6f 6d 65 20 4d 6f 62 69 6c 65")),
            TLV(0x11, hex("01 00 30 30 31 30 31 46 00 00 ff fe 01")),
            TLV(0x12, hex("01 00 00 01 01 0a c8 77 bb 0c 6a be c5 69 76 19 0a c8 77 bb 0c 6a be c5 69 76 19"))])
        XCTAssertEqual(NAS.parseSPN(r), "Home Mobile")
        XCTAssertNil(NAS.parseNITZName(r))
        let home = NAS.NetworkName(longName: "Home Mobile", shortName: "Home Mobile")
        XCTAssertEqual(NAS.parseSIMPLMNName(r, mccmnc: "00101", home: true), home)
        XCTAssertEqual(NAS.parseSIMPLMNName(r, mccmnc: "00101", home: false), home)   // by OPL
        XCTAssertNil(NAS.parseSIMPLMNName(r, mccmnc: "00102", home: false))
        // Without OPL, PNN record 1 is the home network's name only.
        let noOPL = try response(.nas, NAS.getOperatorNameData, [r.tlvs.first { $0.type == 0x12 }!])
        XCTAssertEqual(NAS.parseSIMPLMNName(noOPL, mccmnc: "00101", home: true), home)
        XCTAssertNil(NAS.parseSIMPLMNName(noOPL, mccmnc: "00101", home: false))
        XCTAssertTrue(NAS.plmnMatches(Array("001D1F".utf8), "00101"))
        XCTAssertFalse(NAS.plmnMatches(Array("001001".utf8), "00101"))
        // UCS-2 SPN, FF padding.
        let u = try response(.nas, NAS.getOperatorNameData, [TLV(0x10, [0, 7, 0x80, 0, 0x45, 0, 0x58, 0xff, 0xff])])
        XCTAssertEqual(NAS.parseSPN(u), "EX")
    }
}
