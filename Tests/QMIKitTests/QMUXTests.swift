import QMIDatapath
@testable import QMIKit
import XCTest

final class QMUXTests: XCTestCase {
    // CTL Get Client ID for WDS, tx 1: the canonical first request of a QMI host.
    func testEncodeCTLGetClientID() {
        let m = QMIMessage(service: .ctl, clientID: 0, transactionID: 1, messageID: CTL.getClientID,
                           tlvs: CTL.getClientIDRequest(.wds))
        XCTAssertEqual(m.encoded(), [UInt8](hex: "01 0f 00 00 00 00 00 01 22 00 04 00 01 01 00 01"))
    }

    func testDecodeCTLGetClientIDResponse() throws {
        let bytes = [UInt8](hex: "01 17 00 80 00 00 01 01 22 00 0c 00 02 04 00 00 00 00 00 01 02 00 01 05")!
        let m = try QMIMessage.decode(bytes)
        XCTAssertEqual(m.service, .ctl)
        XCTAssertEqual(m.kind, .response)
        XCTAssertEqual(m.transactionID, 1)
        XCTAssertEqual(m.result, QMIResult(success: true, error: .none))
        let (svc, cid) = try CTL.parseAllocatedClient(m)
        XCTAssertEqual(svc, .wds)
        XCTAssertEqual(cid, 5)
    }

    func testServiceRoundTripUsesTwoByteTransaction() throws {
        let m = QMIMessage(service: .wds, clientID: 7, transactionID: 0x1234, messageID: WDS.setIPFamily,
                           tlvs: [.u8(0x01, 6)])
        let bytes = m.encoded()
        XCTAssertEqual(bytes.count, 1 + 5 + 7 + 4)
        XCTAssertEqual(Array(bytes[6...8]), [0x00, 0x34, 0x12])   // flags, tx LE
        let back = try QMIMessage.decode(bytes)
        XCTAssertEqual(back.transactionID, 0x1234)
        XCTAssertEqual(back.messageID, WDS.setIPFamily)
        XCTAssertEqual(back[tlv: 0x01], [6])
    }

    func testDecodeIndicationAndErrorResult() throws {
        // WDS packet service status indication: disconnected, 3GPP cause 33.
        let ind = QMIMessage(service: .wds, clientID: 3, kind: .indication, transactionID: 0,
                             messageID: WDS.getPacketServiceStatus,
                             tlvs: [TLV(0x01, [1, 0]), .u16(0x10, 2), TLV(0x11, [6, 0, 33, 0])])
        let back = try QMIMessage.decode(ind.encoded())
        XCTAssertEqual(back.kind, .indication)
        let s = try XCTUnwrap(WDS.parsePacketServiceStatus(back))
        XCTAssertEqual(s.connectionName, "disconnected")
        XCTAssertEqual(s.callEnd.verboseReason, 33)

        let err = QMIMessage(service: .wds, clientID: 3, kind: .response, transactionID: 9,
                             messageID: WDS.startNetworkInterface, tlvs: [TLV(0x02, [1, 0, 0x1A, 0])])
        XCTAssertEqual(try QMIMessage.decode(err.encoded()).result?.error, .noEffect)
    }

    func testRequestHasNoResult() throws {
        // UIM Read Transparent: TLV 0x02 is the file ID (2FE2 under 3F00), not a result code.
        let req = QMIMessage(service: .uim, clientID: 2, kind: .request, transactionID: 1, messageID: 0x0020,
                             tlvs: UIM.readICCIDRequest)
        XCTAssertNil(try QMIMessage.decode(req.encoded()).result)
    }

    func testTruncatedFrameThrows() {
        XCTAssertThrowsError(try QMIMessage.decode([0x01, 0x20, 0x00, 0x80]))
        // A QMUX length shorter than the SDU it carries: not parsed from the bytes beyond it.
        var bytes = [UInt8](hex: "01 17 00 80 00 00 01 01 22 00 0c 00 02 04 00 00 00 00 00 01 02 00 01 05")!
        bytes[1] = 0x00
        XCTAssertThrowsError(try QMIMessage.decode(bytes))
        bytes[1] = 0x10
        XCTAssertThrowsError(try QMIMessage.decode(bytes))
    }

    func testVersionInfo() throws {
        let m = QMIMessage(service: .ctl, clientID: 0, kind: .response, transactionID: 2, messageID: CTL.getVersionInfo,
                           tlvs: [TLV(0x02, [0, 0, 0, 0]), TLV(0x01, [2, 0x01, 1, 0, 0x5a, 0, 0x1a, 1, 0, 0x14, 0])])
        let v = try CTL.parseVersions(try QMIMessage.decode(m.encoded()))
        XCTAssertEqual(v, [CTL.ServiceVersion(service: .wds, major: 1, minor: 90),
                           CTL.ServiceVersion(service: .wda, major: 1, minor: 20)])
    }

    func testRuntimeSettings() throws {
        var v6 = [UInt8](hex: "20 01 0d b8 01 68 7e b9 00 00 00 00 00 00 00 01")!
        v6.append(64)
        let m = QMIMessage(service: .wds, clientID: 1, kind: .response, transactionID: 4, messageID: WDS.getRuntimeSettings,
                           tlvs: [TLV(0x02, [0, 0, 0, 0]),
                                  TLV(0x1E, [0x27, 0x00, 0x00, 0x0A]),        // 10.0.0.39
                                  TLV(0x15, [0x08, 0x08, 0x08, 0x08]),
                                  .u32(0x29, 1500),
                                  TLV(0x25, v6),
                                  TLV(0x23, [1, 0x01, 0x02, 0x10, 0x0A])])  // 10.16.2.1
        let s = WDS.parseRuntimeSettings(try QMIMessage.decode(m.encoded()))
        XCTAssertEqual(s.ipv4Address?.description, "10.0.0.39")
        XCTAssertEqual(s.ipv4DNS.map(\.description), ["8.8.8.8"])
        XCTAssertEqual(s.mtu, 1500)
        XCTAssertEqual(s.ipv6Address?.description, "2001:db8:168:7eb9::1/64")
        XCTAssertEqual(s.pcscfIPv4.map(\.description), ["10.16.2.1"])
    }

    func testDataFormatRequest() {
        let t = WDA.Request(endpointInterface: 4).tlvs
        XCTAssertEqual(t.first { $0.type == 0x11 }?.value, [2, 0, 0, 0])            // raw IP
        XCTAssertEqual(t.first { $0.type == 0x13 }?.value, [5, 0, 0, 0])            // QMAP
        XCTAssertEqual(t.first { $0.type == 0x17 }?.value, [2, 0, 0, 0, 4, 0, 0, 0]) // HSUSB, if 4
    }
}

final class QMAPTests: XCTestCase {
    private func frames(_ buf: [UInt8]) -> (frames: [(UInt8, Bool, [UInt8])], status: qd_qmap_status) {
        var out: [(UInt8, Bool, [UInt8])] = []
        var off = 0
        var f = qd_qmap_frame()
        let st: qd_qmap_status = buf.withUnsafeBufferPointer { p in
            while true {
                let s = qd_qmap_next(p.baseAddress!, p.count, &off, &f)
                if s != QD_QMAP_OK { return s }
                out.append((f.mux_id, f.is_command, Array(UnsafeBufferPointer(start: f.payload, count: f.payload_len))))
            }
        }
        return (out, st)
    }

    func testAggregatedFramesWithPadding() {
        // mux 0x81: 5-byte payload + 3 pad; mux 0x82: 4-byte payload; then zero filler.
        let buf: [UInt8] = [0x03, 0x81, 0x00, 0x08, 0x45, 1, 2, 3, 4, 0, 0, 0,
                            0x00, 0x82, 0x00, 0x04, 0x60, 9, 9, 9,
                            0, 0, 0, 0, 0, 0]
        let r = frames(buf)
        XCTAssertEqual(r.status, QD_QMAP_END)
        XCTAssertEqual(r.frames.count, 2)
        XCTAssertEqual(r.frames[0].0, 0x81)
        XCTAssertEqual(r.frames[0].2, [0x45, 1, 2, 3, 4])
        XCTAssertEqual(r.frames[1].0, 0x82)
        XCTAssertEqual(r.frames[1].2, [0x60, 9, 9, 9])
    }

    func testCommandFrameAndTruncation() {
        let cmd: [UInt8] = [0x80, 0x81, 0x00, 0x08, 1, 0, 0, 0, 0, 0, 0, 7]
        let r = frames(cmd)
        XCTAssertEqual(r.frames.first?.1, true)
        XCTAssertEqual(r.frames.first?.2.first, 1)

        let truncated: [UInt8] = [0x00, 0x81, 0x00, 0x10, 0x45, 0]
        XCTAssertEqual(frames(truncated).status, QD_QMAP_TRUNCATED)

        let badPad: [UInt8] = [0x08, 0x81, 0x00, 0x04, 0x45, 0, 0, 0]
        XCTAssertEqual(frames(badPad).status, QD_QMAP_BAD)
    }

    func testWriteHeader() {
        var h = [UInt8](repeating: 0, count: 4)
        qd_qmap_write_header(&h, false, 0x82, 1401, qd_qmap_pad_for(1401))
        XCTAssertEqual(h, [0x03, 0x82, 0x05, 0x7C])   // 1401 + 3 pad = 1404
    }
}
