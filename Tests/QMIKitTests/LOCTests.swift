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

    // MARK: - Sessions

    private func le<T>(_ v: T) -> String { withUnsafeBytes(of: v) { Array($0) }.hex }

    func testSessionRequests() {
        XCTAssertEqual(LOC.startRequest(intervalMs: 1000),
                       [.u8(0x01, 1), .u32(0x10, 1), .u32(0x12, 1), .u32(0x13, 1000)])
        XCTAssertEqual(LOC.stopRequest(), [.u8(0x01, 1)])
        XCTAssertEqual(LOC.injectUTCTimeRequest(Date(timeIntervalSince1970: 1_793_439_462.5), uncertaintyMs: 500),
                       [TLV(0x01, [UInt8](hex: le(UInt64(1_793_439_462_500)))!), .u32(0x02, 500)])
        let mask: LOC.EventMask = [.position, .satellites, .engineState, .fixSessionState]
        XCTAssertEqual(mask.rawValue, 0x183)
        XCTAssertEqual(LOC.registerEventsRequest(mask), LOC.registerEventsRequest(0x183))
    }

    // Test coordinates; layout as the RM551E reports a fix.
    func testPosition() throws {
        let m = try indication(LOC.positionReport, [
            (0x01, "00 00 00 00"), (0x02, "01"),
            (0x10, le(Double(1.5))), (0x11, le(Double(-2.25))),
            (0x12, le(Float(7.5))), (0x18, le(Float(0))), (0x1A, le(Float(38))), (0x1B, le(Float(35.5))),
            (0x1C, le(Float(10.875))), (0x1F, le(Float(0))), (0x23, "01 00 00 00"),
            (0x25, le(UInt64(1_793_439_462_000))),
            // 5 used, once per signal: GPS 1 (L1, L5), BeiDou 201 (B1I, B2a), QZSS 195 (L1).
            (0x2C, "05 01 00 01 00 c9 00 c9 00 c3 00"),
            (0x37, "05" + le(UInt64(0x1)) + le(UInt64(0x8)) + le(UInt64(0x200)) + le(UInt64(0x80000)) + le(UInt64(0x2000))),
        ])
        let p = try XCTUnwrap(LOC.parsePosition(m))
        XCTAssertEqual(p.status, 0)
        XCTAssertEqual(p.latitude, 1.5)
        XCTAssertEqual(p.longitude, -2.25)
        XCTAssertEqual(p.horizontalAccuracy, 7.5)
        XCTAssertEqual(p.altitude, 38)
        XCTAssertEqual(p.altitudeMSL, 35.5)
        XCTAssertNil(p.heading)
        XCTAssertEqual(p.time, Date(timeIntervalSince1970: 1_793_439_462))
        XCTAssertEqual(p.used.map(\.id), [1, 1, 201, 201, 195])
        XCTAssertEqual(p.used.map(\.signal), [0x1, 0x8, 0x200, 0x80000, 0x2000])
        XCTAssertNil(LOC.parsePosition(try indication(LOC.positionReport, [])))
    }

    private func entry(valid: UInt32 = 0xfb, system: UInt32, id: UInt16, status: UInt32,
                       el: Float = 40, az: Float = 90, cn0: Float = 30) -> String {
        le(valid) + le(system) + le(id) + " 00 " + le(status) + " 03 " + le(el) + " " + le(az) + " " + le(cn0) + " 00"
    }

    func testSatellites() throws {
        let list = "04" + entry(system: 1, id: 1, status: 3) + entry(system: 6, id: 201, status: 3, cn0: 33)
            + entry(system: 7, id: 195, status: 2) + entry(system: 1, id: 9, status: 1)
        let types = "04" + le(UInt64(0x1)) + le(UInt64(0x200)) + le(UInt64(0x2000)) + le(UInt64(0x1))
        let sats = LOC.parseSatellites(try indication(LOC.satelliteInfo, [(0x01, "00"), (0x11, list), (0x12, types)]))
        XCTAssertEqual(sats.count, 3)                                       // idle (status 1) left out
        XCTAssertEqual(sats.map(\.id), [1, 201, 195])
        XCTAssertEqual(sats.map(\.tracking), [true, true, false])
        XCTAssertEqual(sats.map { $0.signal.flatMap(LOC.signalName) }, ["L1", "B1I", "L1"])
        XCTAssertEqual(sats.map { LOC.systemName($0.system) }, ["gps", "beidou", "qzss"])
        XCTAssertEqual(sats[1].cn0, 33)
        XCTAssertEqual(sats[0].elevation, 40)
        // Values the valid mask leaves out are nil.
        let bare = LOC.parseSatellites(try indication(0x25, [(0x11, "01" + entry(valid: 0x1f, system: 1, id: 3, status: 3))]))
        XCTAssertNil(bare.first?.cn0)
        XCTAssertNil(bare.first?.signal)
        // libqmi's layout: TLV 0x10, 28-byte entries.
        let old = "01" + String(entry(system: 5, id: 70, status: 3).dropLast(3))
        XCTAssertEqual(LOC.parseSatellites(try indication(0x25, [(0x10, old)])).map(\.id), [70])
        XCTAssertEqual(LOC.signalName(0x80000), "B2a")
        XCTAssertNil(LOC.systemName(4))
    }

    func testEngineAndNMEA() throws {
        XCTAssertEqual(LOC.parseEngineOn(try indication(LOC.engineState, [(0x01, "01 00 00 00")])), true)
        XCTAssertEqual(LOC.parseEngineOn(try indication(LOC.engineState, [(0x01, "02 00 00 00")])), false)
        XCTAssertEqual(LOC.parseNMEA(try indication(LOC.nmea, [(0x01, Array("$GPGGA,1*00\r\n".utf8).hex + " 00")])), "$GPGGA,1*00\r\n")
    }
}
