@testable import QMIKit
import XCTest

final class LOCTests: XCTestCase {
    private func indication(_ id: UInt16, _ tlvs: [(UInt8, String)]) throws -> QMIMessage {
        let m = QMIMessage(service: .loc, clientID: 1, kind: .indication, transactionID: 1, messageID: id,
                           tlvs: tlvs.map { TLV($0.0, [UInt8](hex: $0.1)!) })
        return try QMIMessage.decode(m.encoded())
    }

    // Byte layout as the RM551E sends it: start 1793419200 (2026-10-31 04:00 UTC), 168 h.
    func testValidity() throws {
        let m = try indication(LOC.getPredictedOrbitsDataValidity, [(0x01, "00 00 00 00"), (0x10, "c0 67 e5 6a 00 00 00 00 a8 00")])
        XCTAssertEqual(LOC.indicationStatus(m), .success)
        let v = try XCTUnwrap(LOC.parseValidity(m))
        XCTAssertEqual(v.start, Date(timeIntervalSince1970: 1_793_419_200))
        XCTAssertEqual(v.hours, 168)
        XCTAssertEqual(v.expires, Date(timeIntervalSince1970: 1_793_419_200 + 168 * 3600))
        // No data: zero start or duration, a missing or short TLV.
        XCTAssertNil(LOC.parseValidity(try indication(0x37, [(0x10, "00 00 00 00 00 00 00 00 00 00")])))
        XCTAssertNil(LOC.parseValidity(try indication(0x37, [(0x10, "c0 67 e5 6a 00 00 00 00 00 00")])))
        XCTAssertNil(LOC.parseValidity(try indication(0x37, [(0x10, "c0 67 e5 6a")])))
        XCTAssertNil(LOC.parseValidity(try indication(0x37, [])))
    }

    func testSource() throws {
        func list(_ urls: [String]) -> String {
            ([UInt8(urls.count)] + urls.flatMap { [UInt8($0.utf8.count)] + Array($0.utf8) }).hex
        }
        let urls = ["https://xtra1.example.com/a.bin", "https://xtra2.example.com/a.bin"]
        // As the RM551E answers: no sizes TLV.
        let a = LOC.parseSource(try indication(LOC.getPredictedOrbitsDataSource, [(0x01, "00 00 00 00"), (0x11, list(urls))]))
        XCTAssertEqual(a, LOC.XTRASource(maxFileSize: nil, maxPartSize: nil, servers: urls))
        let b = LOC.parseSource(try indication(0x36, [(0x10, "00 00 01 00 00 02 00 00"), (0x11, list(urls))]))
        XCTAssertEqual(b.maxFileSize, 65536)
        XCTAssertEqual(b.maxPartSize, 512)
        // A list cut short keeps the complete entries.
        let cut = [UInt8](hex: list(urls))!.dropLast(3)
        XCTAssertEqual(LOC.parseSource(try indication(0x36, [(0x11, Array(cut).hex)])).servers, [urls[0]])
    }

    func testInjectParts() throws {
        let data = (0..<2500).map { UInt8($0 & 0xff) }
        let parts = LOC.injectRequests(data, message: LOC.injectXTRAData)
        XCTAssertEqual(parts.count, 3)
        for (i, p) in parts.enumerated() {
            let m = QMIMessage(service: .loc, clientID: 1, messageID: LOC.injectXTRAData, tlvs: p)
            XCTAssertEqual(m[tlv: 0x01], [0xc4, 0x09, 0, 0])               // 2500
            XCTAssertEqual(m[tlv: 0x02], [3, 0])
            XCTAssertEqual(m[tlv: 0x03], [UInt8(i + 1), 0])
            let v = try XCTUnwrap(m[tlv: 0x04])
            let len = Int(v[0]) | Int(v[1]) << 8
            XCTAssertEqual(len, i < 2 ? 1024 : 452)
            XCTAssertEqual(Array(v.dropFirst(2)), Array(data[(i * 1024)..<(i * 1024 + len)]))
            XCTAssertNil(m[tlv: 0x10])                                      // 0x00A7 has no format
        }
        // 0x0035 adds format XTRA (0).
        let old = LOC.injectRequests(data, message: LOC.injectPredictedOrbitsData)
        XCTAssertEqual(old[0].first { $0.type == 0x10 }?.value, [0, 0, 0, 0])
        XCTAssertEqual(LOC.injectRequests(Array(data[0..<2048]), message: LOC.injectXTRAData).count, 2)
        XCTAssertEqual(LOC.injectRequests([7], message: LOC.injectXTRAData).count, 1)
        XCTAssertEqual(LOC.injectRequests([], message: LOC.injectXTRAData).count, 0)
        // Part size: at most 1024, whatever is asked.
        XCTAssertEqual(LOC.injectRequests(data, message: LOC.injectXTRAData, partSize: 4096).count, 3)
        XCTAssertEqual(LOC.injectRequests(data, message: LOC.injectXTRAData, partSize: 500).count, 5)
    }

    func testInjectAck() throws {
        let mid = try indication(LOC.injectXTRAData, [(0x01, "00 00 00 00"), (0x10, "01 00")])
        XCTAssertEqual(LOC.injectedPart(mid), 1)
        let last = try indication(LOC.injectXTRAData, [(0x01, "00 00 00 00"), (0x10, "3c 00"), (0x11, "1f 00 00 00 00 00 00 00")])
        XCTAssertEqual(LOC.injectedPart(last), 60)
        let busy = try indication(LOC.injectXTRAData, [(0x01, "04 00 00 00"), (0x10, "02 00")])
        XCTAssertEqual(LOC.indicationStatus(busy), .engineBusy)
        XCTAssertEqual(LOC.indicationStatus(busy)?.description, "engine busy")
        XCTAssertEqual(LOC.IndicationStatus(rawValue: 9).description, "status 9")
    }

    func testRegisterEvents() {
        let tlvs = LOC.registerEventsRequest(0x1_0000_0183)
        XCTAssertEqual(tlvs[0], TLV(0x01, [0x83, 0x01, 0, 0, 0x01, 0, 0, 0]))
        XCTAssertEqual(tlvs[1], TLV(0x11, [1, 0, 0, 0]))               // client type 1: required on the RM551E
    }
}
