@testable import QMIKit
import XCTest

final class QoSTests: XCTestCase {
    // "0x11=[03 40 …] 0x12=[…]" as printed by qmid's trace.
    private func message(_ id: UInt16, _ text: String, kind: QMIMessage.Kind = .response, service: QMIService = .qos) -> QMIMessage {
        let re = try! NSRegularExpression(pattern: #"0x([0-9a-f]{2})=\[([0-9a-f ]*)\]"#)
        let ns = text as NSString
        let tlvs = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            TLV(UInt8(ns.substring(with: $0.range(at: 1)), radix: 16)!, [UInt8](hex: ns.substring(with: $0.range(at: 2)))!)
        }
        return QMIMessage(service: service, clientID: 1, kind: kind, transactionID: 1, messageID: id, tlvs: tlvs)
    }

    // Live captures (RM551E-GL, 2026-10-02).

    // A network creating a CDN bearer: QCI 4 GBR, one IPv4 /27 filter each way,
    // network-initiated, bearer ID 0x37.
    private let reportCreated = """
    0x10=[10 06 00 3d 0c 00 00 01 01 14 1c 00 10 19 00 23 02 00 00 01 22 02 00 bf 00 12 08 00 c0 c0 90 39 e0 ff ff ff 11 01 00 04 13 1c 00 10 19 00 23 02 00 00 01 22 02 00 bf \
     00 13 08 00 c0 c0 90 39 e0 ff ff ff 11 01 00 04 12 29 00 10 26 00 11 01 00 01 12 08 00 00 20 a1 07 00 10 27 00 20 10 00 00 20 a1 07 00 00 00 00 00 10 27 00 00 00 00 00 1 \
    f 01 00 04 11 29 00 10 26 00 11 01 00 01 12 08 00 00 90 d0 03 00 10 27 00 20 10 00 00 90 d0 03 00 00 00 00 00 10 27 00 00 00 00 00 1f 01 00 04 15 01 00 01 16 01 00 37]
    """

    // A modification of the same kind of bearer (IPv4 + IPv6 prefixes, TCP 5-tuples).
    private let reportModified = """
    0x10=[10 06 00 ef 08 00 00 00 02 14 1e 01 10 22 00 23 02 00 08 01 22 02 00 b8 00 16 11 00 2a 03 28 80 f3 60 00 c0 00 00 00 00 00 00 00 00 3b 11 01 00 06 10 2b 00 23 02 00 \
     01 01 22 02 00 01 00 1c 04 00 85 eb 00 00 1b 04 00 bb 01 00 00 14 01 00 06 12 08 00 e5 8c 9f a2 ff ff ff ff 11 01 00 04 10 19 00 23 02 00 0b 01 22 02 00 bc 00 12 08 00 c \
    0 18 90 39 e0 ff ff ff 11 01 00 04 10 22 00 23 02 00 0e 01 22 02 00 ba 00 16 11 00 24 04 00 c0 5c 00 00 05 fa ce b0 0c 33 33 0a 3f 80 11 01 00 06 10 34 00 23 02 00 07 01  \
    22 02 00 04 00 1c 04 00 9b ea 00 00 1b 04 00 bb 01 00 00 14 01 00 06 16 11 00 24 04 68 00 40 03 0c 04 00 00 00 00 00 00 00 84 80 11 01 00 06 10 19 00 23 02 00 05 01 22 02 \
     00 bd 00 12 08 00 80 c0 90 39 c0 ff ff ff 11 01 00 04 10 34 00 23 02 00 03 01 22 02 00 03 00 1c 04 00 44 ea 00 00 1b 04 00 bb 01 00 00 14 01 00 06 16 11 00 2a 03 28 80 f \
    3 0a 01 20 fa ce b0 0c 00 00 01 67 80 11 01 00 06 13 1e 01 10 19 00 23 02 00 05 01 22 02 00 bd 00 13 08 00 80 c0 90 39 c0 ff ff ff 11 01 00 04 10 19 00 23 02 00 0b 01 22  \
    02 00 bc 00 13 08 00 c0 18 90 39 e0 ff ff ff 11 01 00 04 10 22 00 23 02 00 0e 01 22 02 00 ba 00 17 11 00 24 04 00 c0 5c 00 00 05 fa ce b0 0c 33 33 0a 3f 80 11 01 00 06 10 \
     22 00 23 02 00 08 01 22 02 00 b8 00 17 11 00 2a 03 28 80 f3 60 00 c0 00 00 00 00 00 00 00 00 3b 11 01 00 06 10 34 00 23 02 00 07 01 22 02 00 04 00 1c 04 00 bb 01 00 00 1 \
    b 04 00 9b ea 00 00 14 01 00 06 17 11 00 24 04 68 00 40 03 0c 04 00 00 00 00 00 00 00 84 80 11 01 00 06 10 34 00 23 02 00 03 01 22 02 00 03 00 1c 04 00 bb 01 00 00 1b 04  \
    00 44 ea 00 00 14 01 00 06 17 11 00 2a 03 28 80 f3 0a 01 20 fa ce b0 0c 00 00 01 67 80 11 01 00 06 10 2b 00 23 02 00 01 01 22 02 00 01 00 1c 04 00 bb 01 00 00 1b 04 00 85 \
     eb 00 00 14 01 00 06 13 08 00 e5 8c 9f a2 ff ff ff ff 11 01 00 04 12 29 00 10 26 00 11 01 00 01 12 08 00 00 20 a1 07 00 10 27 00 20 10 00 00 20 a1 07 00 00 00 00 00 10 2 \
    7 00 00 00 00 00 1f 01 00 04 11 25 00 10 22 00 12 08 00 00 90 d0 03 00 10 27 00 20 10 00 00 90 d0 03 00 00 00 00 00 10 27 00 00 00 00 00 1f 01 00 04]
    """

    // Get Granted QoS of a dedicated bearer: QCI 4, 64/128 Mbps max, 2.56 Mbps guaranteed.
    private let granted = """
    0x12=[10 26 00 11 01 00 01 12 08 00 00 20 a1 07 00 10 27 00 20 10 00 00 20 a1 07 00 00 00 00 00 10 27 00 00 00 00 00 1f 01 00 04] 0x11=[10 26 00 11 01 00 01 12 08 00 00 9 \
    0 d0 03 00 10 27 00 20 10 00 00 90 d0 03 00 00 00 00 00 10 27 00 00 00 00 00 1f 01 00 04]
    """

    // Get QoS Info for QoS ID 0 (default bearer): QCI 6.
    private let defaultBearer = """
    0x11=[01 40 00 00 00 00 00 00 02 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 \
     00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 06 00 00 00] 0x12=[01 40 00 00 00 00 00 00 02 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  \
    00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 06 00 00 00]
    """

    func testEventReportCreated() throws {
        let reports = QoS.parseEventReport(message(QoS.eventReport, reportCreated, kind: .indication))
        let r = try XCTUnwrap(reports.first)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(r.qosID, 0xc3d)
        XCTAssertTrue(r.changesBearer)
        let b = try XCTUnwrap(r.bearer)
        XCTAssertEqual(b.qci, 4)
        XCTAssertEqual(b.uplink.rates, QoS.Bitrates(max: 64_000_000, guaranteed: 2_560_000))
        XCTAssertEqual(b.downlink.rates, QoS.Bitrates(max: 128_000_000, guaranteed: 2_560_000))
        XCTAssertEqual(b.networkInitiated, true)
        XCTAssertEqual(b.bearerID, 0x37)
        XCTAssertEqual(b.uplinkFilters.map { $0.destination?.description }, ["57.144.192.192/27"])
        XCTAssertEqual(b.downlinkFilters.map { $0.source?.description }, ["57.144.192.192/27"])
        XCTAssertEqual(b.downlinkFilters.first?.id, 0)
        XCTAssertEqual(b.downlinkFilters.first?.precedence, 191)
    }

    func testEventReportModified() throws {
        let r = try XCTUnwrap(QoS.parseEventReport(message(QoS.eventReport, reportModified, kind: .indication)).first)
        XCTAssertEqual(r.qosID, 0x8ef)
        let b = try XCTUnwrap(r.bearer)
        XCTAssertNil(b.networkInitiated)                           // creation-only
        XCTAssertEqual(b.uplinkFilters.count, b.downlinkFilters.count)
        XCTAssertEqual(Set(b.uplinkFilters.map(\.id)), Set(b.downlinkFilters.map(\.id)))
        XCTAssertEqual(b.uplinkFilters.map(\.precedence), b.uplinkFilters.map(\.precedence).sorted())
        let tcp = try XCTUnwrap(b.downlinkFilters.first { $0.id == 1 })
        XCTAssertEqual(tcp.ipVersion, 4)
        XCTAssertEqual(tcp.source?.description, "162.159.140.229/32")
        XCTAssertEqual(tcp.ipProtocol, 6)
        XCTAssertEqual(tcp.sourcePorts, 443...443)
        XCTAssertEqual(tcp.destinationPorts, 60293...60293)
        let upTCP = try XCTUnwrap(b.uplinkFilters.first { $0.id == 1 })
        XCTAssertEqual(upTCP.destination?.description, "162.159.140.229/32")
        XCTAssertEqual(upTCP.sourcePorts, 60293...60293)
        XCTAssertEqual(upTCP.destinationPorts, 443...443)
        let v6 = try XCTUnwrap(b.downlinkFilters.first { $0.id == 8 })
        XCTAssertEqual(v6.ipVersion, 6)
        XCTAssertEqual(v6.source?.description, "2a03:2880:f360:c0::/59")
        XCTAssertEqual(v6.precedence, 0xb8)
    }

    func testEventReportFlowControlAndDelete() {
        let fc = QoS.parseEventReport(message(QoS.eventReport,
            "0x10=[10 06 00 00 00 00 00 00 06 17 02 00 00 00] 0x10=[10 06 00 3d 0c 00 00 00 05 17 02 00 00 00]", kind: .indication))
        XCTAssertEqual(fc.map(\.qosID), [0, 0xc3d])
        XCTAssertFalse(fc.contains { $0.changesBearer })
        XCTAssertNil(fc[1].bearer)
        let del = try? XCTUnwrap(QoS.parseEventReport(message(QoS.eventReport, "0x10=[10 06 00 3d 0c 00 00 00 03]", kind: .indication)).first)
        XCTAssertEqual(del?.isDeleted, true)
        XCTAssertEqual(del?.changesBearer, true)
        XCTAssertNil(del?.bearer)
    }

    func testGrantedQoS() {
        let b = QoS.parseGrantedQoS(message(QoS.getGrantedQoS, granted), qosID: 0x892)
        XCTAssertEqual(b.qci, 4)
        XCTAssertEqual(b.uplink.rates, QoS.Bitrates(max: 64_000_000, guaranteed: 2_560_000))
        XCTAssertEqual(b.downlink.rates, QoS.Bitrates(max: 128_000_000, guaranteed: 2_560_000))
        XCTAssertEqual(b.uplinkFilters, [])
    }

    func testDefaultQCI() {
        XCTAssertEqual(QoS.parseDefaultQCI(message(QoS.getQoSInfo, defaultBearer)), 6)
        var m = message(QoS.getQoSInfo, "")
        m.tlvs = [.u32(0x16, 9)]                                    // 5G SA: 5QI only
        XCTAssertEqual(QoS.parseDefaultQCI(m), 9)
        XCTAssertNil(QoS.parseDefaultQCI(message(QoS.getQoSInfo, "")))
    }

    func testQoSIDs() {
        XCTAssertEqual(QoS.parseQoSIDs(message(QoS.getQoSIDs, "0x10=[02 91 08 00 00 92 08 00 00]")), [0x891, 0x892])
        XCTAssertEqual(QoS.parseQoSIDs(message(QoS.getQoSIDs, "0x10=[00]")), [])
        XCTAssertEqual(QoS.parseQoSIDs(message(QoS.getQoSIDs, "")), [])
    }

    func testAMBR() {
        // An ims APN-AMBR: 10.2 Mbps both ways.
        var m = message(WDS.getAMBRInfo, "0x10=[c0 a3 9b 00 00 00 00 00] 0x11=[c0 a3 9b 00 00 00 00 00]", service: .wds)
        XCTAssertEqual(WDS.parseAMBR(m), WDS.AMBR(uplink: 10_200_000, downlink: 10_200_000))
        m.tlvs.removeLast()
        XCTAssertNil(WDS.parseAMBR(m))
    }

    // MARK: IP families (synthetic reports in the captured format)

    private func tlv(_ type: UInt8, _ v: [UInt8]) -> [UInt8] { [type, UInt8(v.count & 0xff), UInt8(v.count >> 8)] + v }

    private func filter(id: UInt8, prec: UInt16, v4src: [UInt8]? = nil, v4dst: [UInt8]? = nil, v4len: Int = 32,
                        v6src: [UInt8]? = nil, v6dst: [UInt8]? = nil, v6len: UInt8 = 128,
                        udp: (UInt16, UInt16)? = nil) -> [UInt8] {
        var b = tlv(0x23, [id, 1]) + tlv(0x22, [UInt8(prec & 0xff), UInt8(prec >> 8)])
        let mask = UInt32.max << (32 - UInt32(v4len))
        let m = (0..<4).map { UInt8((mask >> (8 * UInt32($0))) & 0xff) }
        if let a = v4src { b += tlv(0x12, a.reversed() + m) }
        if let a = v4dst { b += tlv(0x13, a.reversed() + m) }
        if let a = v6src { b += tlv(0x16, a + [v6len]) }
        if let a = v6dst { b += tlv(0x17, a + [v6len]) }
        if let (s, d) = udp {
            b += tlv(0x1D, [UInt8(s & 0xff), UInt8(s >> 8), 0, 0]) + tlv(0x1E, [UInt8(d & 0xff), UInt8(d >> 8), 0, 0]) + tlv(0x14, [17])
        }
        b += tlv(0x11, [v6src != nil || v6dst != nil ? 6 : 4])
        return tlv(0x10, b)
    }

    private func report(_ id: UInt32, state: UInt8 = 2, qci: UInt8 = 1, up: [[UInt8]], down: [[UInt8]]) -> QMIMessage {
        func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xff) } }
        let spec = tlv(0x10, tlv(0x20, le64(128_000) + le64(128_000)) + tlv(0x1F, [qci]))
        let head = tlv(0x10, [UInt8(id & 0xff), UInt8(id >> 8 & 0xff), 0, 0, 0, state])
        let flow = head + tlv(0x13, up.flatMap { $0 }) + tlv(0x14, down.flatMap { $0 }) + tlv(0x11, spec) + tlv(0x12, spec)
        return QMIMessage(service: .qos, clientID: 1, kind: .indication, transactionID: 1, messageID: QoS.eventReport, tlvs: [TLV(0x10, flow)])
    }

    private let ims6: [UInt8] = [0x20, 0x01, 0x0d, 0xb8, 0x20, 0x00, 0x00, 0x08] + [UInt8](repeating: 0, count: 7) + [1]

    func testIPv4OnlyPDN() throws {
        // Some networks: internet and ims IPv4 only.
        let b = try XCTUnwrap(QoS.parseEventReport(report(5, up: [filter(id: 0, prec: 1, v4dst: [10, 0, 0, 120], udp: (5060, 5060))],
                                                            down: [filter(id: 0, prec: 1, v4src: [10, 0, 0, 120], udp: (5060, 5060))])).first?.bearer)
        XCTAssertEqual(b.qci, 1)
        XCTAssertEqual(b.uplink.rates, QoS.Bitrates(max: 128_000, guaranteed: 128_000))
        XCTAssertEqual(b.uplinkFilters.first?.destination?.description, "10.0.0.120/32")
        XCTAssertEqual(b.uplinkFilters.first?.ipProtocol, 17)
        XCTAssertEqual(b.uplinkFilters.first?.destinationPorts, 5060...5060)
        XCTAssertEqual(b.downlinkFilters.first?.source?.description, "10.0.0.120/32")
        XCTAssertEqual(b.downlinkFilters.first?.sourcePorts, 5060...5060)
    }

    func testIPv6OnlyPDN() throws {
        // Many networks' ims: IPv6 only, e.g. a voice bearer to the P-CSCF.
        let b = try XCTUnwrap(QoS.parseEventReport(report(9, state: 1, up: [filter(id: 2, prec: 3, v6dst: ims6, udp: (49152, 1234))],
                                                            down: [filter(id: 2, prec: 3, v6src: ims6, udp: (1234, 49152))])).first?.bearer)
        XCTAssertEqual(b.uplinkFilters.first?.destination?.description, "2001:db8:2000:8::1/128")
        XCTAssertEqual(b.uplinkFilters.first?.ipVersion, 6)
        XCTAssertEqual(b.downlinkFilters.first?.destinationPorts, 49152...49152)
    }

    func testDualStackPDN() throws {
        // Dual-stack internet: one bearer, filters of both families in the same report.
        let b = try XCTUnwrap(QoS.parseEventReport(report(0xc3d, qci: 4,
            up: [filter(id: 1, prec: 190, v6dst: [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0xc0] + [UInt8](repeating: 0, count: 8), v6len: 59),
                 filter(id: 0, prec: 191, v4dst: [203, 0, 113, 192], v4len: 27)],
            down: [filter(id: 0, prec: 191, v4src: [203, 0, 113, 192], v4len: 27),
                   filter(id: 1, prec: 190, v6src: [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0xc0] + [UInt8](repeating: 0, count: 8), v6len: 59)])).first?.bearer)
        XCTAssertEqual(b.uplinkFilters.map(\.ipVersion), [6, 4])           // sorted by precedence
        XCTAssertEqual(b.downlinkFilters.map { $0.source?.description }, ["2001:db8:0:c0::/59", "203.0.113.192/27"])
    }
}
