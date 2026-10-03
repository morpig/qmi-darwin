@testable import QMIHost
import QMIKit
import XCTest

final class ConfigTests: XCTestCase {
    private func decode(_ json: String) throws -> QMIDConfig {
        try JSONDecoder().decode(QMIDConfig.self, from: Data(json.utf8))
    }

    private func pdn(_ name: String, profile: Int? = nil, apn: String? = "x", role: String? = nil,
                     attach: Bool? = nil, auth: String? = nil, policy: String? = nil) -> QMIDConfig.PDN {
        QMIDConfig.PDN(name: name, profile: profile, apn: apn, family: nil, policy: policy, autoconnect: nil,
                       role: role, attach: attach, username: nil, password: nil, auth: auth)
    }

    func testDecodesCurrentConfig() throws {
        let c = try decode("""
        { "pdns": [
          { "name": "internet", "role": "internet", "apn": "internet", "family": "ipv4v6", "policy": "prefer-wifi", "autoconnect": true },
          { "name": "ims", "role": "ims", "apn": "ims", "profile": 2, "family": "ipv6", "policy": "never", "autoconnect": true },
          { "name": "corp", "apn": "corp.test", "family": "ipv4", "username": "u1", "password": "p1", "auth": "pap", "autoconnect": false }
        ] }
        """)
        XCTAssertNoThrow(try c.validate())
        XCTAssertEqual(c.pdns.map(\.families), [[4, 6], [6], [4]])
        XCTAssertEqual(c.pdns.map(\.effectiveRole), ["internet", "ims", "other"])
        XCTAssertEqual(c.pdns.map(\.isAttach), [true, false, false])
        XCTAssertEqual(c.pdns[1].profile, 2)
    }

    func testBuiltInIsValid() {
        XCTAssertNoThrow(try QMIDConfig.builtIn.validate())
        XCTAssertEqual(QMIDConfig.builtIn.pdns.map(\.name), ["internet", "ims"])
    }

    func testValidationErrors() {
        func invalid(_ pdns: [QMIDConfig.PDN], file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try QMIDConfig(interface: nil, pdns: pdns).validate(), file: file, line: line)
        }
        invalid([pdn("a"), pdn("a")])                                  // duplicate name
        invalid([pdn("")])                                             // empty name
        invalid([pdn("a", apn: nil)])                                  // neither profile nor apn
        invalid([pdn("a", profile: 0)])                                // profile out of range
        invalid([pdn("a", auth: "md5")])                               // unknown auth
        invalid([pdn("a", policy: "always")])                          // unknown policy
        invalid([pdn("a", profile: 2), pdn("b", profile: 2)])          // same pinned profile
        invalid([pdn("a", attach: true), pdn("b", attach: true)])      // two attach PDNs
        invalid([pdn("internet"), pdn("b", role: "internet")])         // both default to attach
        invalid((0..<9).map { pdn("p\($0)", role: "other") })          // more than 8 PDNs
    }

    func testOneShotKeys() throws {
        let c = try decode("""
        { "pdns": [
          { "name": "internet", "profile": 1 },
          { "name": "emergency", "profile": 3, "apnType": ["emergency"], "redial": false, "maxUptime": 300 }
        ] }
        """)
        XCTAssertNoThrow(try c.validate())
        let e = c.pdns[1]
        XCTAssertTrue(e.oneShot)
        XCTAssertFalse(e.autoconnects)                                 // redial false implies no autoconnect
        XCTAssertEqual(e.maxUptime, 300)
        XCTAssertEqual(e.apnTypeMask, .emergency)
        XCTAssertFalse(c.pdns[0].oneShot)
        XCTAssertTrue(c.pdns[0].autoconnects)
        XCTAssertNil(c.pdns[0].apnTypeMask)
    }

    func testOneShotValidation() {
        func invalid(_ p: QMIDConfig.PDN, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try QMIDConfig(interface: nil, pdns: [p]).validate(), file: file, line: line)
        }
        var p = pdn("e", role: "other")
        p.redial = false
        p.autoconnect = true
        invalid(p)                                                     // one-shot can't autoconnect
        p.autoconnect = nil
        p.maxUptime = 0
        invalid(p)                                                     // maxUptime must be positive
        p.maxUptime = 60
        XCTAssertNoThrow(try QMIDConfig(interface: nil, pdns: [p]).validate())
        p.redial = nil
        invalid(p)                                                     // maxUptime needs redial false
        var t = pdn("t", role: "other")
        t.apnType = ["default", "sos"]
        invalid(t)                                                     // unknown APN type
    }

    func testApnTypeOverridesRole() {
        XCTAssertEqual(WDS.APNTypeMask(names: ["default", "SUPL"]), [.default, .supl])
        XCTAssertEqual(WDS.APNTypeMask(names: []), [])
        XCTAssertNil(WDS.APNTypeMask(names: ["sos"]))
    }

    func testRoleDefaults() {
        XCTAssertEqual(pdn("internet").effectiveRole, "internet")
        XCTAssertEqual(pdn("ims").effectiveRole, "ims")
        XCTAssertEqual(pdn("mms").effectiveRole, "other")
        XCTAssertTrue(pdn("internet").isAttach)
        XCTAssertFalse(pdn("internet", attach: false).isAttach)
        XCTAssertFalse(pdn("ims").isAttach)
    }
}

final class ServiceEntityTests: XCTestCase {
    private var settings: WDS.RuntimeSettings {
        var s = WDS.RuntimeSettings()
        s.ipv4Address = IPv4([10, 0, 0, 206])
        s.ipv4Gateway = IPv4([10, 0, 0, 205])
        s.ipv4DNS = [IPv4([192, 0, 2, 53])]
        s.ipv6Address = IPv6Prefix(address: IPv6([0x20, 0x01, 0x0d, 0xb8] + [UInt8](repeating: 0, count: 11) + [1]), length: 64)
        s.ipv6Gateway = IPv6Prefix(address: IPv6([0x20, 0x01, 0x0d, 0xb8] + [UInt8](repeating: 0, count: 11) + [2]), length: 64)
        return s
    }

    func testServiceIDIsStableNameBasedUUID() {
        let a = ServicePublisher.serviceID(for: "internet")
        XCTAssertEqual(a, ServicePublisher.serviceID(for: "internet"))
        XCTAssertNotEqual(a, ServicePublisher.serviceID(for: "ims"))
        XCTAssertEqual(a, "373F7112-A4F9-3604-8047-4950CDFE8C75")    // the ID configd has seen
        XCTAssertEqual(Array(a)[14], "3")                           // version 3
    }

    func testEntities() throws {
        let id = ServicePublisher.serviceID(for: "internet")
        let e = ServicePublisher.entities(pdnName: "internet", interface: "utun9", settings: settings, policy: .preferWifi)
        let service = try XCTUnwrap(e[ServicePublisher.serviceKey(id)])
        XCTAssertNil(service["PrimaryRank"])                        // prefer-wifi: unordered, no rank
        let v4 = try XCTUnwrap(e[ServicePublisher.serviceKey(id, "IPv4")])
        XCTAssertEqual(v4["Router"] as? String, "10.0.0.205")    // IPMonitor needs Router
        XCTAssertEqual(v4["DestAddresses"] as? [String], ["10.0.0.205"])
        XCTAssertEqual(v4["InterfaceName"] as? String, "utun9")
        let v6 = try XCTUnwrap(e[ServicePublisher.serviceKey(id, "IPv6")])
        XCTAssertEqual(v6["PrefixLength"] as? [Int], [64])
        XCTAssertEqual(v6["Router"] as? String, "2001:db8::2")
        let dns = try XCTUnwrap(e[ServicePublisher.serviceKey(id, "DNS")])
        XCTAssertEqual(dns["ServerAddresses"] as? [String], ["192.0.2.53"])
    }

    func testPolicyRanks() throws {
        func rank(_ p: ServicePublisher.Policy) -> String? {
            let e = ServicePublisher.entities(pdnName: "x", interface: "utun9", settings: settings, policy: p)
            return e[ServicePublisher.serviceKey(ServicePublisher.serviceID(for: "x"))]?["PrimaryRank"] as? String
        }
        XCTAssertNil(rank(.preferWifi))
        XCTAssertEqual(rank(.preferCellular), "First")
        XCTAssertEqual(rank(.lastResort), "Last")
        XCTAssertEqual(rank(.never), "Never")
    }

    func testIPv4WithoutGatewayUsesOwnAddress() throws {
        var s = settings
        s.ipv4Gateway = nil
        let id = ServicePublisher.serviceID(for: "x")
        let e = ServicePublisher.entities(pdnName: "x", interface: "utun9", settings: s, policy: .never)
        XCTAssertEqual(e[ServicePublisher.serviceKey(id, "IPv4")]?["Router"] as? String, "10.0.0.206")
    }

    func testUtunBatchSwitch() throws {
        func decode(_ json: String) throws -> QMIDConfig { try JSONDecoder().decode(QMIDConfig.self, from: Data(json.utf8)) }
        XCTAssertNil(try decode(#"{ "pdns": [] }"#).utunBatch)
        XCTAssertEqual(try decode(#"{ "utunBatch": false, "pdns": [] }"#).utunBatch, false)
    }

    func testVendorIDs() throws {
        func decode(_ json: String) throws -> QMIDConfig { try JSONDecoder().decode(QMIDConfig.self, from: Data(json.utf8)) }
        XCTAssertEqual(QMIDevice.vendorIDs().first, 0x2C7C)
        let c = try decode(#"{ "vendorIDs": ["1234", "1199"], "pdns": [] }"#)
        XCTAssertNoThrow(try c.validate())
        let ids = QMIDevice.vendorIDs(extra: c.usbVendorIDs)
        XCTAssertEqual(Array(ids.prefix(3)), [0x1234, 0x1199, 0x2C7C])     // configured first
        XCTAssertEqual(ids.filter { $0 == 0x1199 }.count, 1)               // no duplicates
        XCTAssertThrowsError(try decode(#"{ "vendorIDs": ["2c7"], "pdns": [] }"#).validate())
        XCTAssertThrowsError(try decode(#"{ "vendorIDs": ["0x2c7c"], "pdns": [] }"#).validate())
    }

}

final class CarrierConfigTests: XCTestCase {

    private func carriersConfig() throws -> QMIDConfig {
        try JSONDecoder().decode(QMIDConfig.self, from: Data("""
        { "pdns": [
            { "name": "internet", "role": "internet", "profile": 1 },
            { "name": "ims", "role": "ims", "profile": 2, "apn": "ims" } ],
          "carriers": [
            { "name": "Home", "mccmnc": ["00101"], "apn": "internet" },
            { "name": "Home MVNO", "mccmnc": ["00101"], "iccid": ["890001"], "apn": "mvno" },
            { "name": "Home MVNO pro", "iccid": ["8900019"], "apn": "mvno.pro", "username": "u", "password": "p" },
            { "name": "Other", "mccmnc": ["00102", "00103"], "apn": "other" },
            { "name": "Home again", "mccmnc": ["00101"], "apn": "never" } ] }
        """.utf8))
    }

    func testCarrierMatching() throws {
        let c = try carriersConfig()
        XCTAssertNoThrow(try c.validate())
        func match(_ m: String?, _ i: String?) -> String? {
            c.carrier(for: SIMIdentity(mccmnc: m, iccid: i)).map { "\($0.carrier.name) by \($0.matchedBy)" }
        }
        XCTAssertEqual(match("00101", "8900101234567890123"), "Home by mccmnc 00101")          // first of equals
        XCTAssertEqual(match("00101", "8900011234567890123"), "Home MVNO by iccid 890001")     // iccid beats mccmnc
        XCTAssertEqual(match("00101", "8900019234567890123"), "Home MVNO pro by iccid 8900019") // longer prefix
        XCTAssertEqual(match("00103", nil), "Other by mccmnc 00103")
        XCTAssertEqual(match(nil, "8900019000000000000"), "Home MVNO pro by iccid 8900019")
        XCTAssertNil(match("99999", "8999000000000000000"))
    }

    func testResolvedAttachPDN() throws {
        let c = try carriersConfig()
        func attach(_ sim: SIMIdentity?) -> QMIDConfig.PDN { c.resolvedPDNs(for: sim)[0] }

        let home = attach(SIMIdentity(mccmnc: "00101", iccid: "8900101234567890123"))
        XCTAssertEqual([home.apn, home.username, home.password, home.auth], ["internet", "", "", "none"])
        let pro = attach(SIMIdentity(mccmnc: "00101", iccid: "8900019234567890123"))
        XCTAssertEqual([pro.apn, pro.username, pro.password, pro.auth], ["mvno.pro", "u", "p", "pap-chap"])
        // No match and no top-level apn: empty APN, the network's default bearer.
        let other = attach(SIMIdentity(mccmnc: "99999", iccid: nil))
        XCTAssertEqual([other.apn, other.username, other.auth], ["", "", "none"])
        // SIM not read yet: attach profile untouched.
        XCTAssertEqual([attach(nil).apn, attach(nil).username, attach(nil).auth], [nil, nil, nil])
        // ICCID read but home network not yet, and no ICCID entry matches: an "mccmnc" entry
        // may still match, so untouched too (not the no-match fallback).
        let unknown = SIMIdentity(mccmnc: nil, iccid: "8900101234567890123")
        XCTAssertFalse(c.identifies(unknown))
        XCTAssertEqual([attach(unknown).apn, attach(unknown).username, attach(unknown).auth], [nil, nil, nil])
        // An ICCID entry decides without the home network.
        let mvno = SIMIdentity(mccmnc: nil, iccid: "8900019234567890123")
        XCTAssertTrue(c.identifies(mvno))
        XCTAssertEqual(attach(mvno).apn, "mvno.pro")
        XCTAssertTrue(c.identifies(SIMIdentity(mccmnc: "99999")))
        // IMS is the same on every SIM.
        XCTAssertEqual(c.resolvedPDNs(for: SIMIdentity(mccmnc: "00101"))[1], c.pdns[1])
        // Without "carriers" nothing changes per SIM.
        var plain = c
        plain.carriers = nil
        XCTAssertEqual(plain.resolvedPDNs(for: SIMIdentity(mccmnc: "00101")), plain.pdns)
    }

    func testNoMatchUsesTopLevelAttachSettings() throws {
        var c = try carriersConfig()
        c.pdns[0].apn = "fallback"
        c.pdns[0].username = "fu"
        let p = c.resolvedPDNs(for: SIMIdentity(mccmnc: "99999"))[0]
        XCTAssertEqual([p.apn, p.username, p.auth], ["fallback", "fu", "pap-chap"])
    }

    func testSIMIdentityKeepsFieldsAcrossFailedReads() {
        let known = SIMIdentity(mccmnc: "00102", iccid: "8900210000000001245")
        // Get Home Network fails while re-registering: same card keeps its MCC/MNC.
        XCTAssertEqual(SIMIdentity(mccmnc: nil, iccid: known.iccid).merged(over: known), known)
        // ICCID unreadable: keeps the ICCID.
        XCTAssertEqual(SIMIdentity(mccmnc: "00102").merged(over: known), known)
        // A different card takes the read as is, even without its MCC/MNC.
        let swapped = SIMIdentity(mccmnc: nil, iccid: "8900110000000000000")
        XCTAssertEqual(swapped.merged(over: known), swapped)
        // Nothing known yet.
        XCTAssertEqual(swapped.merged(over: nil), swapped)
        // Same card, MCC/MNC now readable.
        XCTAssertEqual(known.merged(over: SIMIdentity(iccid: known.iccid)), known)
    }

    func testCarrierValidation() throws {
        func invalid(_ carriers: String, _ pdns: String = #"{ "name": "internet", "profile": 1 }"#,
                     file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try QMIDConfig.decode(Data("{ \"pdns\": [\(pdns)], \"carriers\": [\(carriers)] }".utf8)),
                                 file: file, line: line)
        }
        invalid(#"{ "name": "", "mccmnc": ["51011"] }"#)                     // no name
        invalid(#"{ "name": "a" }"#)                                          // no match
        invalid(#"{ "name": "a", "mccmnc": ["5101"] }"#)                      // too short
        invalid(#"{ "name": "a", "mccmnc": ["001-01"] }"#)                    // not digits
        invalid(#"{ "name": "a", "iccid": ["89F"] }"#)                        // not digits
        invalid(#"{ "name": "a", "mccmnc": ["51011"], "auth": "md5" }"#)      // bad auth
        invalid(#"{ "name": "a", "mccmnc": ["51011"] }"#,
                #"{ "name": "x", "role": "other", "profile": 1 }"#)          // no attach PDN
        XCTAssertNoThrow(try QMIDConfig.decode(Data(#"{ "pdns": [{ "name": "internet", "profile": 1 }], "carriers": [] }"#.utf8)))
    }

    func testFailureSummary() {
        // Same reason for every family: said once.
        XCTAssertEqual(PDNSession.summary([4: "3GPP #33: Requested service option not subscribed",
                                           6: "3GPP #33: Requested service option not subscribed"]),
                       "3GPP #33: Requested service option not subscribed")
        XCTAssertEqual(PDNSession.summary([6: "b", 4: "a"]), "ipv4: a; ipv6: b")
        XCTAssertEqual(PDNSession.summary([4: "a"]), "ipv4: a")
    }
}
