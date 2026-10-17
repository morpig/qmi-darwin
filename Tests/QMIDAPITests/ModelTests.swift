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
        // An IMS PDN: IPv6 only, QCI 5, APN-AMBR 10.2 Mbps; pdn events carry no bearers.
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
        // 2 Gbps (a fast internet PDN) fits; a half-present AMBR is dropped.
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
            QMIDKey.sim: [QMIDKey.mccmnc: "00101", QMIDKey.iccidSuffix: "…1234", QMIDKey.carrier: "Example",
                          QMIDKey.matchedBy: "mccmnc 00101", QMIDKey.attachAPN: "internet",
                          QMIDKey.attachAPNFromNetwork: false, "futureKey": 1] as NSDictionary,
        ])
        let sim = try XCTUnwrap(s.sim)
        XCTAssertEqual(sim.mccmnc, "00101")
        XCTAssertEqual(sim.carrier, "Example")
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
        let emc = try XCTUnwrap(QMIDPLMN([QMIDKey.mccmnc: "00102", QMIDKey.emergencyBearers: false,
                                          QMIDKey.emergencyAccessBarred: false]))
        XCTAssertEqual(emc.emergencyBearers, false)
        XCTAssertEqual(emc.emergencyAccessBarred, false)
        XCTAssertNil(QMIDPLMN(nil))
        XCTAssertNil(QMIDStatus([QMIDKey.modem: "ready"]).plmn)
    }

    // qmid builds its dictionaries from these types: what it encodes, clients decode unchanged.
    func testPDNRoundTrip() throws {
        var p = QMIDPDN(name: "internet", state: .backoff)
        p.policy = QMIDPolicy.preferCellular.rawValue
        p.role = "internet"
        p.interface = "utun9"
        p.ipv4 = "10.0.0.2"
        p.ipv6 = "2001:db8::1/64"
        p.dns = ["10.0.0.1"]
        p.mtu = 1500
        p.profile = 1
        p.apn = "internet"
        p.serviceID = "ID"
        p.mux = 0x81
        p.wanted = true
        p.uptime = 5
        p.error = "dropped: regular deactivation"
        p.reason = .dropped
        p.causes = [QMIDCause(type: "3GPP", family: 4, code: 36, name: "regular deactivation")]
        p.blocked = ["ipv4: x"]
        p.qci = 9
        p.ambr = QMIDAMBR(uplink: 1, downlink: 2)
        p.bearers = [QMIDBearer(id: 3, qci: 1, uplink: QMIDBitrates(max: 128_000, guaranteed: 128_000))]
        p.linkHeld = true
        let back = try XCTUnwrap(QMIDPDN(p.dictionary))
        XCTAssertEqual(back, p)
        XCTAssertEqual(back.policyKind, .preferCellular)
        XCTAssertTrue(back.linkHeld)

        let minimal = QMIDPDN(name: "ims", state: .idle)
        XCTAssertEqual(QMIDPDN(minimal.dictionary), minimal)
        XCTAssertNil(minimal.dictionary[QMIDKey.dns])          // empty lists are left out
        XCTAssertFalse(try XCTUnwrap(QMIDPDN(imsPDN)).linkHeld) // older qmid: no key
    }

    func testFilterRoundTrip() throws {
        var f = QMIDPacketFilter(id: 1, precedence: 10, ipVersion: 6)
        f.destination = "2001:db8::a/128"
        f.ipProtocol = 17
        f.sourcePorts = 5060...5060
        f.destinationPorts = 1024...65535
        XCTAssertEqual(QMIDPacketFilter(f.dictionary), f)
    }

    func testSIMPLMNPreparedRoundTrip() throws {
        var s = QMIDSIM(mccmnc: "00101", iccidSuffix: "…1234")
        s.carrier = "Example"
        s.matchedBy = "mccmnc 00101"
        s.attachAPN = "internet"
        s.attachAPNFromNetwork = true
        s.pendingSIM = "…5678"
        XCTAssertEqual(QMIDSIM(s.dictionary), s)
        XCTAssertNil(QMIDSIM(mccmnc: "00101").dictionary[QMIDKey.attachAPNFromNetwork])   // only with an APN

        var n = QMIDPLMN(mccmnc: "00101", longName: "Example Mobile", shortName: nil, nameFromNetwork: true)
        n.emergencyBearers = false
        XCTAssertEqual(QMIDPLMN(n.dictionary), n)

        let r = QMIDPreparedSIM(apn: "", carrier: "Example", matchedBy: "iccid 8900")
        XCTAssertEqual(QMIDPreparedSIM(r.dictionary), r)
    }

    func testModemStateAndPolicy() {
        XCTAssertEqual(QMIDStatus([QMIDKey.modem: "ready"]).modemState, .ready)
        XCTAssertTrue(QMIDStatus([QMIDKey.modem: "ready"]).isModemReady)
        XCTAssertNil(QMIDStatus([QMIDKey.modem: "rebooting"]).modemState)   // a newer qmid's state
        XCTAssertEqual(QMIDPolicy.allCases.map(\.rawValue), ["prefer-wifi", "prefer-cellular", "last-resort", "never"])
    }

    func testRadioRoundTripAndBands() throws {
        var c = QMIDCell(rat: .lte, role: .primary)
        c.channel = 1313; c.band = 3; c.pci = 272; c.cellID = 0x01234504; c.bandwidth = 20; c.rsrp = -96; c.snr = 13
        var nr = QMIDCell(rat: .nr, role: .secondary)
        nr.channel = 504990; nr.band = 41; nr.pci = 185; nr.rsrp = -90
        var scell = QMIDCell(rat: .lte, role: .secondary)
        scell.channel = 325; scell.active = true; scell.scellIndex = 1
        let r = QMIDRadio(cells: [c, scell, nr], endcAvailable: true)
        XCTAssertEqual(QMIDRadio(r.dictionary), r)
        XCTAssertEqual(r.serving.count, 3)
        XCTAssertEqual(QMIDCell.band(.lte, channel: 1313), 3)
        XCTAssertEqual(QMIDCell.band(.lte, channel: 325), 1)
        XCTAssertEqual(QMIDCell.band(.lte, channel: 66786), 66)
        XCTAssertEqual(QMIDCell.band(.nr, channel: 504990), 41)
        XCTAssertEqual(QMIDCell.band(.nr, channel: 636666), 78)
        XCTAssertEqual(QMIDCell.band(.nr, channel: 660000), 77)
        XCTAssertNil(QMIDCell.band(.lte, channel: 10400))
    }
}
