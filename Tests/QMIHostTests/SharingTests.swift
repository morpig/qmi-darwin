@testable import QMIHost
import QMIDAPI
import XCTest

final class SharingTests: XCTestCase {
    func testServiceEntity() {
        let e = Sharing.serviceEntity(pdn: "internet", device: "utun9")
        XCTAssertEqual(e["UserDefinedName"] as? String, "Cellular (internet)")
        XCTAssertEqual(e[Sharing.markerKey] as? String, "internet")
        let i = e["Interface"] as? [String: Any]
        XCTAssertEqual(i?["Type"] as? String, "Ethernet")
        XCTAssertEqual(i?["DeviceName"] as? String, "utun9")
        // No IP settings: IPConfiguration must leave the utun alone.
        XCTAssertNil(e["IPv4"])
        XCTAssertNil(e["IPv6"])
        XCTAssertTrue(Sharing.isCurrent(e, pdn: "internet"))
    }

    func testIsCurrentIgnoresDeviceName() {
        // The plugin finds the interface through State:, so a changed utun number needs no rewrite.
        XCTAssertTrue(Sharing.isCurrent(Sharing.serviceEntity(pdn: "internet", device: "utun12"), pdn: "internet"))
        XCTAssertFalse(Sharing.isCurrent(nil, pdn: "internet"))
        XCTAssertFalse(Sharing.isCurrent(Sharing.serviceEntity(pdn: "other", device: "utun9"), pdn: "internet"))
        var edited = Sharing.serviceEntity(pdn: "internet", device: "utun9")
        edited["IPv4"] = ["ConfigMethod": "DHCP"]
        XCTAssertFalse(Sharing.isCurrent(edited, pdn: "internet"))
        var foreign = Sharing.serviceEntity(pdn: "internet", device: "utun9")
        foreign[Sharing.markerKey] = nil
        XCTAssertFalse(Sharing.isCurrent(foreign, pdn: "internet"))
    }

    func testNATSettings() {
        let n = Sharing.NAT(["Enabled": 1, "PrimaryService": "ABC", "SharingDevices": ["en0"],
                             "AirPort": ["Enabled": 0]])
        XCTAssertTrue(n.enabled)
        XCTAssertEqual(n.source, "ABC")
        XCTAssertEqual(n.sharedTo, ["en0"])
        XCTAssertEqual(n.subnet, "192.168.2.0")
        XCTAssertEqual(n.mask, "255.255.255.0")
        XCTAssertFalse(Sharing.NAT(nil).enabled)
        XCTAssertEqual(Sharing.NAT(["Enabled": 0, "SharingNetworkNumberStart": "192.0.2.0"]).subnet, "192.0.2.0")
    }

    func testNoBridgeForUnusedSubnet() {
        var n = Sharing.NAT()
        n.subnet = "192.0.2.0"                       // TEST-NET-1: no interface of this Mac has it
        XCTAssertNil(Sharing.bridge(for: n))
        XCTAssertEqual(Sharing.clients(on: "nonexistent0"), 0)
    }

    func testConfigValidation() throws {
        func config(_ sharing: String) throws -> QMIDConfig {
            try QMIDConfig.decode(Data("""
            { "pdns": [ { "name": "internet", "apn": "a" }, { "name": "ims", "apn": "ims" } ], \(sharing) }
            """.utf8))
        }
        XCTAssertEqual(try config(#""sharing": { "pdn": "internet" }"#).sharing?.pdn, "internet")
        XCTAssertThrowsError(try config(#""sharing": { "pdn": "missing" }"#))
        XCTAssertThrowsError(try config(#""sharing": { "pdn": "ims" }"#))   // not an internet PDN
        XCTAssertNil(try config(#""xtra": {}"#).sharing)
    }

    func testStatusModelRoundTrip() throws {
        let s = QMIDSharing(pdn: "internet", state: .on, interface: "utun9", bridge: "bridge100", sharedTo: ["en0"], clients: 2)
        XCTAssertEqual(QMIDSharing(s.dictionary), s)
        let st = QMIDStatus([QMIDKey.modem: "ready", QMIDKey.sharing: s.dictionary])
        XCTAssertEqual(st.sharing, s)
        XCTAssertNil(QMIDStatus([QMIDKey.modem: "ready"]).sharing)
        XCTAssertEqual(QMIDSharing([QMIDKey.pdn: "internet", QMIDKey.state: "not-selected"])?.state, .notSelected)
        XCTAssertNil(QMIDSharing([QMIDKey.pdn: "internet", QMIDKey.state: "future-state"]))
    }
}
