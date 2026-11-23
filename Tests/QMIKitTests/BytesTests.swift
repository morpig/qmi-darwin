@testable import QMIKit
import XCTest

final class BytesTests: XCTestCase {
    func testWideAndFloatRoundTrip() throws {
        var w = ByteWriter()
        w.u64(0x0102_0304_0506_0708)
        w.f32(1.5)
        w.f64(-90.25)
        XCTAssertEqual(Array(w.bytes.prefix(8)), [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01])
        XCTAssertEqual(Array(w.bytes[8..<12]), [0x00, 0x00, 0xC0, 0x3F])
        var r = ByteReader(w.bytes)
        XCTAssertEqual(try r.u64(), 0x0102_0304_0506_0708)
        XCTAssertEqual(try r.f32(), 1.5)
        XCTAssertEqual(try r.f64(), -90.25)
        XCTAssertTrue(r.isAtEnd)
        XCTAssertThrowsError(try r.u64())
        var short = ByteReader([1, 2, 3, 4, 5, 6, 7])
        XCTAssertThrowsError(try short.u64())
        XCTAssertEqual(short.offset, 0)
    }

    func testCountedLists() throws {
        // u8 count 3, but only two whole u16s.
        var lenient = ByteReader([3, 0x01, 0x00, 0x02, 0x00, 0x03])
        XCTAssertEqual(lenient.partialList { try $0.u16() }, [1, 2])
        XCTAssertEqual(lenient.remaining, 1)                     // stopped before the cut item
        var strict = ByteReader([3, 0x01, 0x00, 0x02, 0x00, 0x03])
        XCTAssertThrowsError(try strict.list { try $0.u16() })
        var wide = ByteReader([2, 0, 0x2A, 0x2B])
        XCTAssertEqual(try wide.list(count: .u16) { try $0.u8() }, [0x2A, 0x2B])
        var empty = ByteReader([])
        XCTAssertEqual(empty.partialList { try $0.u8() }, [])
        XCTAssertThrowsError(try empty.list { try $0.u8() })
    }

    func testBitIndexes() {
        XCTAssertEqual([UInt8]([0x05, 0x80]).bitIndexes, [0, 2, 15])
        XCTAssertEqual([UInt8]([0, 0]).bitIndexes, [])
        XCTAssertEqual([UInt8]().bitIndexes, [])
    }

    func testTLVLists() throws {
        let bytes: [UInt8] = [0x10, 1, 0, 0xAA, 0x11, 2, 0, 0xBB, 0xCC, 0x10, 1, 0, 0xDD]
        let tlvs = try TLV.decodeList(bytes)
        XCTAssertEqual(tlvs, [TLV(0x10, [0xAA]), TLV(0x11, [0xBB, 0xCC]), TLV(0x10, [0xDD])])
        XCTAssertEqual(tlvs.valuesByType, [0x10: [0xAA], 0x11: [0xBB, 0xCC]])   // first wins
        let cut = bytes + [0x12, 5, 0, 1]
        XCTAssertThrowsError(try TLV.decodeList(cut))
        XCTAssertEqual(TLV.decodePartialList(cut), tlvs)
    }

    func testScalarTLVAccessorsAndDump() {
        let m = QMIMessage(service: .wds, clientID: 1, kind: .response, messageID: 0x0020,
                           tlvs: [TLV(0x02, [0, 0, 0, 0]), TLV(0x10, [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]),
                                  TLV(0x11, [0x01, 0x02, 0x03])])
        XCTAssertEqual(m.u8(tlv: 0x10), 0x01)
        XCTAssertEqual(m.u16(tlv: 0x10), 0x0201)
        XCTAssertEqual(m.u32(tlv: 0x10), 0x0403_0201)
        XCTAssertEqual(m.u64(tlv: 0x10), 0x0807_0605_0403_0201)
        XCTAssertEqual(m.u16(tlv: 0x11), 0x0201)
        XCTAssertNil(m.u32(tlv: 0x11))                           // too short
        XCTAssertNil(m.u8(tlv: 0x12))                            // absent
        XCTAssertEqual(m.tlvDump(prefix: "  "), ["  0x10 (8): 01 02 03 04 05 06 07 08", "  0x11 (3): 01 02 03"])
        var request = m
        request.kind = .request                                  // 0x02 is an ordinary TLV here
        XCTAssertEqual(request.tlvDump().first, "0x02 (4): 00 00 00 00")
    }

    func testEndpoint() {
        XCTAssertEqual(WDA.endpoint(interface: 4), [2, 0, 0, 0, 4, 0, 0, 0])
        XCTAssertEqual(QoS.bindDataPortRequest(interface: 4, muxID: 0x81)[0], TLV(0x10, [2, 0, 0, 0, 4, 0, 0, 0]))
    }

    func testProtocolErrorNames() {
        XCTAssertEqual(QMIProtocolError.malformedMessage.description, "MalformedMessage (0x0001)")
        XCTAssertEqual(QMIProtocolError.invalidHandle.description, "InvalidHandle (0x0009)")
    }
}
