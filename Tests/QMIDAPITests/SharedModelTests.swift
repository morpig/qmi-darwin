import QMIDAPI
import XCTest

// Round trips (init(dictionary) == model) of the models qmid builds its replies from, and
// tolerance of values a newer qmid may send.
final class SharedModelTests: XCTestCase {
    private func pdn() -> QMIDPDN {
        var p = QMIDPDN(name: "internet", state: .connected)
        p.role = QMIDRole.internet.rawValue
        p.policy = QMIDPolicy.preferWifi.rawValue
        p.interface = "utun5"
        p.ipv4 = "192.0.2.10"
        p.counters = QMIDCounters(["rx_packets": 10, "rx_bytes": 1500, "tx_packets": 3, "flow_disabled": 1])
        return p
    }

    func testStatusRoundTrip() throws {
        var sim = QMIDSIM(mccmnc: "00101", iccidSuffix: "…1234")
        sim.card = .present
        var sharing = QMIDSharing(pdn: "internet", state: .on, interface: "utun5", bridge: "bridge100",
                                  sharedTo: ["en0"], clients: 2)
        sharing.clients = 1
        let s = QMIDStatus(version: "0.27.0 (1)", modem: QMIDModemState.ready.rawValue, modemError: nil,
                           network: "registered, ps attached, lte", pdns: [pdn()], sim: sim,
                           plmn: QMIDPLMN(mccmnc: "00101", longName: "Test Network"), imei: "001010000000001",
                           airplaneMode: true, gnss: QMIDGNSS(engine: "on"), sharing: sharing,
                           datapath: QMIDCounters(["usb_in_transfers": 7, "unknown_mux_0x83": 1]))
        let d = s.dictionary
        XCTAssertEqual(d[QMIDKey.airplaneMode] as? Bool, true)
        XCTAssertEqual(d[QMIDKey.apiVersion] as? Int, qmidAPIVersion)
        let back = QMIDStatus(d)
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.datapath?["usb_in_transfers"], 7)
        let c = try XCTUnwrap(back.pdn("internet")?.counters)
        XCTAssertEqual(c.rxPackets, 10)
        XCTAssertEqual(c.rxBytes, 1500)
        XCTAssertNil(c.rxDrops)
        XCTAssertEqual(c.flowDisabled, true)
        XCTAssertEqual(back.pdns.first?.roleKind, .internet)
        // An empty status says airplane mode off.
        XCTAssertEqual(QMIDStatus().dictionary[QMIDKey.airplaneMode] as? Bool, false)
        XCTAssertEqual(QMIDStatus(QMIDStatus().dictionary), QMIDStatus())
    }

    func testCountersFromDatapath() {
        // As the datapath reports them: NSNumbers, flow_disabled a Bool.
        let raw: NSDictionary = ["rx_packets": NSNumber(value: UInt64(5)), "flow_disabled": NSNumber(value: false)]
        let c = QMIDCounters(raw)
        XCTAssertEqual(c.rxPackets, 5)
        XCTAssertEqual(c.flowDisabled, false)
        XCTAssertEqual(QMIDCounters(c.dictionary), c)
    }

    func testModemAndEventDictionaries() {
        let m = QMIDModem(state: .ready, network: "registered", error: nil, airplaneMode: true)
        let ev = QMIDEventDictionary.modem(m)
        XCTAssertEqual(ev[QMIDKey.type] as? String, QMIDEventType.modem)
        XCTAssertEqual(QMIDModem(ev), m)
        XCTAssertEqual(QMIDModem(ev).stateKind, .ready)
        XCTAssertEqual(QMIDEvent(ev), .modem(state: "ready", network: "registered", error: nil))
        // airplaneMode only when on, as before.
        XCTAssertNil(QMIDEventDictionary.modem(QMIDModem(state: .absent))[QMIDKey.airplaneMode])

        XCTAssertEqual(QMIDEvent(QMIDEventDictionary.pdn(pdn())), .pdn(pdn()))
        XCTAssertEqual(QMIDEvent(QMIDEventDictionary.config), .config)
        XCTAssertNil(QMIDEventDictionary.sim(nil)[QMIDKey.sim])
        XCTAssertNil(QMIDEventDictionary.radio(nil)[QMIDKey.radio])
        let sats = QMIDSatellites(satellites: [QMIDSatellite(system: "gps", id: 3, tracking: true)],
                                  time: Date(timeIntervalSince1970: 1_800_000_000))
        let se = QMIDEventDictionary.satellites(sats)
        XCTAssertEqual(se[QMIDKey.type] as? String, QMIDEventType.satellites)
        XCTAssertEqual(QMIDSatellites(se), sats)
        XCTAssertEqual(QMIDEventDictionary.bearers(pdn: "ims", [])[QMIDKey.bearers] as? [NSDictionary], [])
    }

    func testOnModemAndOnEvent() {
        let client = QMIDClient(queue: DispatchQueue(label: "test"))
        let modem = expectation(description: "onModem")
        let event = expectation(description: "onEvent")
        client.onModem = { m in
            XCTAssertTrue(m.airplaneMode)
            modem.fulfill()
        }
        client.onEvent = { e in
            XCTAssertEqual(e, .modem(state: "ready", network: nil, error: nil))
            event.fulfill()
        }
        client.qmidEvent(QMIDEventDictionary.modem(QMIDModem(state: .ready, airplaneMode: true)))
        wait(for: [modem, event], timeout: 2)
    }

    func testLocationEventsSkipOnEvent() {
        let client = QMIDClient(queue: DispatchQueue(label: "test"))
        let got = expectation(description: "onNMEA")
        client.onEvent = { _ in XCTFail("nmea reached onEvent") }
        client.onNMEA = { XCTAssertEqual($0, "$GPGGA"); got.fulfill() }
        client.qmidEvent(QMIDEventDictionary.nmea("$GPGGA"))
        wait(for: [got], timeout: 2)
    }

    func testProfileReportRoundTrip() {
        let r = QMIDProfileReport(
            sim: "00101 …1234", carrier: "test by mccmnc 00101", attachAPN: "internet", pending: "…5678",
            pdns: [.init(pdn: "internet", action: "in sync", profile: 1, attach: true, settings: "1: internet ipv4v6"),
                   .init(pdn: "ims", action: "write failed: busy", failed: true, profile: 2)],
            error: "sync failed", learned: ["00101: internet"], modemProfiles: ["1: internet", "2: ims"],
            autoconnect: "off", attachProfile: 1)
        let a = r.array
        XCTAssertEqual(QMIDProfileReport(a), r)
        // The keys qmid has always sent: attach is a Bool in PDN entries, an Int on its own.
        let entries = a as! [NSDictionary]
        XCTAssertEqual(entries[0][QMIDKey.sim] as? String, "00101 …1234")
        XCTAssertEqual(entries[1][QMIDKey.attach] as? Bool, true)
        XCTAssertNil(entries[2][QMIDKey.attach])
        XCTAssertEqual(entries.last?[QMIDKey.attach] as? Int, 1)
        // While the modem isn't open qmid sends [].
        XCTAssertEqual(QMIDProfileReport([]), QMIDProfileReport())
        XCTAssertEqual(QMIDProfileReport().array.count, 0)
        XCTAssertEqual(QMIDProfileReport([[QMIDKey.sim: QMIDProfileReport.simNotRead]]).sim, QMIDProfileReport.simNotRead)
    }

    func testStoreModelsRoundTrip() throws {
        var sim = QMIDSIM(mccmnc: "00101", iccidSuffix: "…1234")
        sim.attachAPN = "internet"
        let m = QMIDStoreModem(state: "ready", network: "registered", vendorID: 0x2c7c, productID: 0x0801,
                               interface: 4, lastError: nil, airplaneMode: true, sim: sim,
                               plmn: QMIDPLMN(mccmnc: "00101"))
        XCTAssertEqual(m.dictionary[QMIDStoreField.vendorID] as? Int, 0x2c7c)
        XCTAssertEqual(QMIDStoreModem(m.dictionary as NSDictionary), m)
        XCTAssertNil(QMIDStoreModem(state: "absent").dictionary[QMIDStoreField.airplaneMode])

        let p = QMIDStorePDN(state: "connected", serviceID: "00000000-0000-3000-8000-000000000001", muxID: 0x81,
                             policy: "prefer-wifi", interfaceName: "utun5", profile: 1, apn: "internet", mtu: 1500,
                             ipv4Address: "192.0.2.10", ipv6Address: "2001:db8::1/64", pcscfv6: ["2001:db8::a"],
                             rat: "lte", qci: 9, ambr: QMIDAMBR(uplink: 50_000_000, downlink: 150_000_000))
        let d = p.dictionary
        XCTAssertEqual(d[QMIDStoreField.state] as? String, "connected")
        XCTAssertNil(d[QMIDStoreField.pcscfv4])
        XCTAssertEqual((d[QMIDStoreField.ambr] as? [String: Any])?[QMIDStoreField.uplink] as? NSNumber, 50_000_000)
        XCTAssertEqual(QMIDStorePDN(d as NSDictionary), p)
    }

    func testUnknownValuesKeepObjects() throws {
        let cell = try XCTUnwrap(QMIDCell([QMIDKey.rat: "umts", QMIDKey.role: "primary", QMIDKey.channel: 10700]))
        XCTAssertNil(cell.ratKind)
        XCTAssertEqual(cell.ratName, "umts")
        XCTAssertEqual(cell.roleKind, .primary)
        XCTAssertEqual(QMIDCell(cell.dictionary), cell)
        let other = try XCTUnwrap(QMIDCell([QMIDKey.rat: "nr", QMIDKey.role: "mcg"]))
        let radio = QMIDRadio([QMIDKey.cells: [cell.dictionary, other.dictionary]])
        XCTAssertEqual(radio.cells.count, 2)
        XCTAssertEqual(radio.serving, [cell])              // unknown role: neither serving nor neighbour
        XCTAssertEqual(radio.neighbors, [])
        XCTAssertNil(QMIDCell([QMIDKey.rat: "lte"]))       // still needs both

        let sharing = try XCTUnwrap(QMIDSharing([QMIDKey.pdn: "internet", QMIDKey.state: "paused"]))
        XCTAssertNil(sharing.stateKind)
        XCTAssertEqual(QMIDSharing(sharing.dictionary), sharing)
        XCTAssertEqual(QMIDSharing(pdn: "internet", state: .notSelected).stateKind, .notSelected)

        let sat = try XCTUnwrap(QMIDSatellite([QMIDKey.system: "gps", QMIDKey.id: 5, QMIDKey.state: "acquiring"]))
        XCTAssertFalse(sat.tracking)
        XCTAssertEqual(sat.stateName, "acquiring")
        XCTAssertEqual(QMIDSatellite(sat.dictionary), sat)
        XCTAssertTrue(QMIDSatellite(system: "gps", id: 1, tracking: true).tracking)
    }

    func testGNSSAssistInit() {
        let a = QMIDGNSSAssist(time: Date(timeIntervalSince1970: 1_800_000_000), result: .injected, server: "supl.example.com:7275",
                               uncertainty: 1500, duration: 0.8, firstFixAfter: 12, firstFixDistance: 340)
        XCTAssertEqual(a.firstFixAfter, 12)
        XCTAssertEqual(QMIDGNSSAssist(a.dictionary), a)
    }

    func testRole() {
        XCTAssertEqual(QMIDRole.allCases.map(\.rawValue), ["internet", "ims", "other"])
        XCTAssertNil(QMIDPDN(name: "x", state: .idle).roleKind)
    }

    func testVersionString() {
        XCTAssertEqual(QMIDVersion.string(info: ["CFBundleShortVersionString": "0.27.0", "CFBundleVersion": "20261123120000"]),
                       "0.27.0 (20261123120000)")
        XCTAssertEqual(QMIDVersion.string(info: ["CFBundleShortVersionString": "0.27.0"]), "0.27.0 (?)")
        XCTAssertNil(QMIDVersion.string(info: ["CFBundleVersion": "1"]))
        XCTAssertNil(QMIDVersion.string(info: nil))
    }

    func testSyncReturnsReplyAndTimesOut() {
        let client = QMIDClient(queue: DispatchQueue(label: "test"))
        let ok: Result<Int, QMIDError> = client.sync(timeout: 2) { done in
            DispatchQueue.global().async { done(.success(7)) }
        }
        XCTAssertEqual(try? ok.get(), 7)
        // No answer: a timeout failure; the late reply is dropped.
        var late: ((Result<Int, QMIDError>) -> Void)?
        let r: Result<Int, QMIDError> = client.sync(timeout: 0.1) { late = $0 }
        guard case .failure(let e) = r else { return XCTFail("expected a timeout") }
        XCTAssertTrue(e.timedOut)
        late?(.success(1))
    }
}
