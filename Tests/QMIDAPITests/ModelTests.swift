import QMIDAPI
import XCTest

final class ModelTests: XCTestCase {
    private let imsPDN: NSDictionary = [
        QMIDKey.name: "ims", QMIDKey.state: "connected", QMIDKey.policy: "never", QMIDKey.role: "ims",
        QMIDKey.interface: "utun9", QMIDKey.ipv6: "2001:db8::1/64", QMIDKey.pcscf: ["2001:db8::a", "2001:db8::b"],
        QMIDKey.mtu: 1500, QMIDKey.profile: 2, QMIDKey.apn: "ims", QMIDKey.mux: 0x82, QMIDKey.wanted: true,
        QMIDKey.uptime: 42, "futureKey": "ignored"
    ]

    func testDecodesPDN() throws {
        let p = try XCTUnwrap(QMIDPDN(imsPDN))
        XCTAssertEqual(p.name, "ims")
        XCTAssertEqual(p.state, .connected)
        XCTAssertTrue(p.isConnected)
        XCTAssertEqual(p.interface, "utun9")
        XCTAssertEqual(p.ipv6Address, "2001:db8::1")
        XCTAssertNil(p.ipv4)
        XCTAssertEqual(p.pcscf, ["2001:db8::a", "2001:db8::b"])
        XCTAssertEqual(p.dns, [])
        XCTAssertEqual(p.profile, 2)
        XCTAssertEqual(p.mux, 0x82)
    }

    func testDecodesQCIAndAMBR() throws {
        // XL ims: IPv6 only, QCI 5, APN-AMBR 10.2 Mbps; pdn events carry no bearers.
        let d = imsPDN.mutableCopy() as! NSMutableDictionary
        d[QMIDKey.qci] = 5
        d[QMIDKey.ambr] = [QMIDKey.uplink: NSNumber(value: UInt64(10_200_000)), QMIDKey.downlink: NSNumber(value: UInt64(10_200_000))]
        let p = try XCTUnwrap(QMIDPDN(d))
        XCTAssertEqual(p.qci, 5)
        XCTAssertEqual(p.ambr, QMIDAMBR(uplink: 10_200_000, downlink: 10_200_000))
        XCTAssertNil(p.bearers)
        let plain = try XCTUnwrap(QMIDPDN(imsPDN))
        XCTAssertNil(plain.qci)
        XCTAssertNil(plain.ambr)
        // 2 Gbps (XL internet) fits; a half-present AMBR is dropped.
        d[QMIDKey.ambr] = [QMIDKey.uplink: NSNumber(value: UInt64(2_000_000_000)), QMIDKey.downlink: NSNumber(value: UInt64(2_000_000_000))]
        XCTAssertEqual(QMIDPDN(d)?.ambr?.downlink, 2_000_000_000)
        d[QMIDKey.ambr] = [QMIDKey.uplink: 1]
        XCTAssertNil(QMIDPDN(d)?.ambr)
    }

    func testStatusBearers() throws {
        let d = imsPDN.mutableCopy() as! NSMutableDictionary
        d[QMIDKey.bearers] = [[QMIDKey.id: 3133, QMIDKey.qci: 1,
                               QMIDKey.uplink: [QMIDKey.max: 128_000, QMIDKey.guaranteed: 128_000],
                               QMIDKey.uplinkFilters: [[QMIDKey.id: 1, QMIDKey.precedence: 10, QMIDKey.ipVersion: 6,
                                                        QMIDKey.destination: "2001:db8::a/128", QMIDKey.ipProtocol: 17,
                                                        QMIDKey.destinationPorts: [1024, 65535]]]],
                              [QMIDKey.qci: 9]]          // no id: dropped
        let p = try XCTUnwrap(QMIDPDN(d))
        let b = try XCTUnwrap(p.bearers?.first)
        XCTAssertEqual(p.bearers?.count, 1)
        XCTAssertEqual(b.qci, 1)
        XCTAssertTrue(b.isGBR)
        XCTAssertEqual(b.downlink, QMIDBitrates())
        let f = try XCTUnwrap(b.uplinkFilters.first)
        XCTAssertEqual(f.destinationPorts, 1024...65535)
        XCTAssertNil(f.sourcePorts)
    }

    func testBearersEventCallback() {
        let client = QMIDClient(queue: DispatchQueue(label: "test"))
        let got = expectation(description: "onBearers")
        let other = expectation(description: "onEvent")
        client.onBearers = { pdn, bearers in
            XCTAssertEqual(pdn, "internet")
            XCTAssertEqual(bearers.map(\.id), [3133])
            got.fulfill()
        }
        client.onEvent = { e in
            XCTAssertEqual(e, .unknown(type: "bearers"))
            other.fulfill()
        }
        client.qmidEvent([QMIDKey.type: QMIDEventType.bearers, QMIDKey.pdn: "internet",
                          QMIDKey.bearers: [[QMIDKey.id: 3133, QMIDKey.qci: 4] as NSDictionary]])
        wait(for: [got, other], timeout: 2)
    }

    func testDecodesReasonAndCauses() throws {
        // A one-shot PDN rejected on both families (3GPP #31).
        let d: NSDictionary = [
            QMIDKey.name: "emergency", QMIDKey.state: "idle", QMIDKey.wanted: false,
            QMIDKey.error: "3GPP #31: Request rejected, unspecified", QMIDKey.reason: "rejected",
            QMIDKey.causes: [
                [QMIDKey.family: 4, QMIDKey.type: "3GPP", QMIDKey.code: 31, QMIDKey.name: "Request rejected, unspecified"],
                [QMIDKey.family: 6, QMIDKey.type: "3GPP", QMIDKey.code: 31],
                [QMIDKey.family: 6],                                   // no type: dropped
            ],
        ]
        let p = try XCTUnwrap(QMIDPDN(d))
        XCTAssertEqual(p.reason, .rejected)
        XCTAssertEqual(p.causes.count, 2)
        XCTAssertEqual(p.causes.map(\.code), [31, 31])
        XCTAssertEqual(p.causes.map(\.family), [4, 6])
        XCTAssertTrue(p.causes.allSatisfy(\.is3GPP))
        XCTAssertNil(p.causes[1].name)
        let plain = try XCTUnwrap(QMIDPDN(imsPDN))
        XCTAssertNil(plain.reason)
        XCTAssertEqual(plain.causes, [])
        let newer = try XCTUnwrap(QMIDPDN([QMIDKey.name: "x", QMIDKey.reason: "some-future-reason"]))
        XCTAssertNil(newer.reason)
        XCTAssertEqual(QMIDReason(rawValue: "not-attached"), .notAttached)
        XCTAssertEqual(QMIDReason(rawValue: "max-uptime"), .maxUptime)
    }

    func testPDNWithoutNameIsRejected() {
        XCTAssertNil(QMIDPDN([QMIDKey.state: "idle"]))
    }

    func testUnknownStateKeepsName() throws {
        let p = try XCTUnwrap(QMIDPDN([QMIDKey.name: "x", QMIDKey.state: "suspended"]))
        XCTAssertNil(p.state)
        XCTAssertEqual(p.stateName, "suspended")
        XCTAssertTrue(p.wanted)
    }

    func testDecodesStatus() {
        let s = QMIDStatus([
            QMIDKey.apiVersion: 1, QMIDKey.modem: "ready", QMIDKey.network: "registered, ps attached, lte",
            QMIDKey.pdns: [imsPDN, [QMIDKey.state: "idle"] as NSDictionary]
        ])
        XCTAssertTrue(s.isModemReady)
        XCTAssertEqual(s.apiVersion, 1)
        XCTAssertEqual(s.pdns.count, 1)
        XCTAssertEqual(s.pdn("ims")?.interface, "utun9")
        XCTAssertNil(s.pdn("internet"))
    }

    func testDecodesEvents() {
        XCTAssertEqual(QMIDEvent([QMIDKey.type: "config"]), .config)
        XCTAssertEqual(QMIDEvent([QMIDKey.type: "modem", QMIDKey.modem: "absent"]),
                       .modem(state: "absent", network: nil, error: nil))
        XCTAssertEqual(QMIDEvent([QMIDKey.type: "pdn", QMIDKey.pdn: imsPDN]), .pdn(QMIDPDN(imsPDN)!))
        XCTAssertEqual(QMIDEvent([QMIDKey.type: "throughput"]), .unknown(type: "throughput"))
        XCTAssertNil(QMIDEvent([QMIDKey.type: "pdn"]))
        XCTAssertNil(QMIDEvent([:]))
    }

    func testLogEntryRoundTrip() throws {
        let e = QMIDLogEntry(time: Date(timeIntervalSince1970: 1_790_000_000.25), level: .notice,
                             category: "qmid", message: "internet: connected on utun9")
        XCTAssertEqual(QMIDLogEntry(e.dictionary), e)
        XCTAssertNil(QMIDLogEntry([QMIDKey.message: "no time"]))
        let unknownLevel = QMIDLogEntry([QMIDKey.time: 1.0, QMIDKey.level: 9, QMIDKey.message: "x"])
        XCTAssertEqual(unknownLevel?.level, .info)
        XCTAssertEqual(unknownLevel?.category, "qmid")
    }

    func testLogLevels() {
        XCTAssertEqual(QMIDLogLevel(name: "debug"), .debug)
        XCTAssertEqual(QMIDLogLevel(name: "error"), .error)
        XCTAssertNil(QMIDLogLevel(name: "verbose"))
        XCTAssertTrue(QMIDLogLevel.debug < .info && QMIDLogLevel.notice < .error)
        XCTAssertEqual(QMIDLogLevel.notice.name, "notice")
    }

    func testDecodesSIM() throws {
        let s = QMIDStatus([
            QMIDKey.modem: "ready",
            QMIDKey.sim: [QMIDKey.mccmnc: "51011", QMIDKey.iccidSuffix: "…1234", QMIDKey.carrier: "XL",
                          QMIDKey.matchedBy: "mccmnc 51011", QMIDKey.attachAPN: "internet",
                          QMIDKey.attachAPNFromNetwork: false, "futureKey": 1] as NSDictionary,
        ])
        let sim = try XCTUnwrap(s.sim)
        XCTAssertEqual(sim.mccmnc, "51011")
        XCTAssertEqual(sim.carrier, "XL")
        XCTAssertEqual(sim.attachAPN, "internet")
        XCTAssertFalse(sim.attachAPNFromNetwork)
        XCTAssertNil(QMIDStatus([QMIDKey.modem: "absent"]).sim)
        XCTAssertNil(QMIDSIM([:]))
    }

    // A "sim" event is new: onEvent sees it as .unknown, so existing switches still compile.
    func testSIMEventIsUnknownToOnEvent() {
        XCTAssertEqual(QMIDEvent([QMIDKey.type: QMIDEventType.sim] as NSDictionary), .unknown(type: "sim"))
    }

    func testDecodesPLMN() throws {
        let p = try XCTUnwrap(QMIDStatus([
            QMIDKey.modem: "ready",
            QMIDKey.plmn: [QMIDKey.mccmnc: "00101", QMIDKey.longName: "Example Mobile Network",
                           QMIDKey.shortName: "ExampleNet", QMIDKey.nameFromNetwork: true] as NSDictionary
        ]).plmn)
        XCTAssertEqual(p.mccmnc, "00101")
        XCTAssertEqual(p.shortName, "ExampleNet")
        XCTAssertTrue(p.nameFromNetwork)
        XCTAssertEqual(p.displayName, "Example Mobile Network")
        let bare = try XCTUnwrap(QMIDPLMN([QMIDKey.mccmnc: "00101"]))
        XCTAssertNil(bare.displayName)
        XCTAssertFalse(bare.nameFromNetwork)
        XCTAssertNil(bare.emergencyBearers)
        XCTAssertNil(bare.emergencyAccessBarred)
        let emc = try XCTUnwrap(QMIDPLMN([QMIDKey.mccmnc: "51010", QMIDKey.emergencyBearers: false,
                                          QMIDKey.emergencyAccessBarred: false]))
        XCTAssertEqual(emc.emergencyBearers, false)
        XCTAssertEqual(emc.emergencyAccessBarred, false)
        XCTAssertNil(QMIDPLMN(nil))
        XCTAssertNil(QMIDStatus([QMIDKey.modem: "ready"]).plmn)
    }
}
