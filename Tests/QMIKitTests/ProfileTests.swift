@testable import QMIKit
import XCTest

final class ProfileTests: XCTestCase {
    private func response(_ id: UInt16, _ tlvs: [TLV]) throws -> QMIMessage {
        let m = QMIMessage(service: .wds, clientID: 1, kind: .response, transactionID: 1, messageID: id,
                           tlvs: [TLV(0x02, [0, 0, 0, 0])] + tlvs)
        return try QMIMessage.decode(m.encoded())
    }

    func testIMSProfileTLVs() {
        var p = WDS.Profile(index: 2)
        p.apn = "ims"
        p.pdpType = .ipv4v6
        p.pcscfUsingPCO = true
        p.imcn = true
        p.apnType = .ims
        let t = Dictionary(uniqueKeysWithValues: p.settingTLVs.map { ($0.type, $0.value) })
        XCTAssertEqual(t[0x14], Array("ims".utf8))
        XCTAssertEqual(t[0x11], [3])
        XCTAssertEqual(t[0x1F], [1])
        XCTAssertEqual(t[0x22], [1])
        XCTAssertEqual(t[0xDD], [2, 0, 0, 0, 0, 0, 0, 0])      // APN type mask, 64-bit LE, bit 1 = ims
        XCTAssertNil(t[0x1B])                                  // unset fields are not sent
    }

    func testProfileRoundTrip() throws {
        var p = WDS.Profile(index: 3)
        p.apn = "corp.test"
        p.pdpType = .ipv4
        p.username = "u1"
        p.password = "p1"
        p.authentication = .pap
        p.apnDisabled = false
        p.roamingDisallowed = true
        p.contextNumber = 3
        p.apnType = [.default, .supl]
        let back = WDS.parseProfile(try response(WDS.getProfileSettings, p.settingTLVs), index: 3)
        XCTAssertEqual(back, p)
    }

    // Real Get Profile Settings bytes from the RM551E (profile 1 with an empty APN), trimmed
    // to the fields qmi-darwin reads.
    func testParseModemProfile() throws {
        let tlvs = [TLV(0x10, Array("profile1".utf8)), TLV(0x11, [3]), TLV(0x14, []), TLV(0x1B, []), TLV(0x1C, []),
                    TLV(0x1D, [0]), TLV(0x1F, [0]), TLV(0x21, [0]), TLV(0x22, [0]), TLV(0x25, [1]),
                    TLV(0x2F, [0]), TLV(0x3E, [0]), TLV(0xDD, [1, 0, 0, 0, 0, 0, 0, 0])]
        let p = WDS.parseProfile(try response(WDS.getProfileSettings, tlvs), index: 1)
        XCTAssertEqual(p.name, "profile1")
        XCTAssertEqual(p.apn, "")
        XCTAssertEqual(p.pdpType, .ipv4v6)
        XCTAssertEqual(p.contextNumber, 1)
        XCTAssertEqual(p.apnType, .default)
        XCTAssertEqual(p.pcscfUsingPCO, false)
        XCTAssertEqual(p.summary, "1: apn \"\" ipv4v6 name \"profile1\" type default")
    }

    func testDifferences() {
        var have = WDS.Profile(index: 1)
        have.apn = "INTERNET"
        have.pdpType = .ipv4v6
        have.apnType = [.default, .supl]
        have.password = "secret"

        var want = WDS.Profile(index: 1)
        want.apn = "internet"                 // APNs compare case-insensitively
        want.pdpType = .ipv4v6
        want.apnType = .default               // a superset on the modem is fine
        XCTAssertEqual(have.differences(from: want), [])

        want.apn = "example"
        want.password = "other"
        want.apnType = .ims
        let d = have.differences(from: want)
        XCTAssertTrue(d.contains("apn: \"INTERNET\" → \"example\""))
        XCTAssertTrue(d.contains("password"))                        // value not shown
        XCTAssertFalse(d.joined().contains("secret"))
        XCTAssertTrue(d.contains { $0.hasPrefix("apn-type:") })
    }

    // The modem may leave out empty string TLVs and auth none: not a difference.
    func testEmptyEqualsUnset() {
        let have = WDS.Profile(index: 1)
        var want = WDS.Profile(index: 1)
        want.apn = ""
        want.username = ""
        want.password = ""
        want.authentication = WDS.Authentication.none
        XCTAssertEqual(have.differences(from: want), [])
        want.apn = "internet"
        XCTAssertEqual(have.differences(from: want), ["apn: unset → \"internet\""])
    }

    func testAttachParameters() throws {
        let r = try response(WDS.getLTEAttachParameters, [TLV(0x10, Array("internet".utf8)), TLV(0x11, [2]), TLV(0x12, [1])])
        XCTAssertEqual(WDS.parseAttachParameters(r), WDS.AttachParameters(apn: "internet", ipType: 2, otaAttach: true))
        XCTAssertEqual(WDS.parseAttachParameters(try response(WDS.getLTEAttachParameters, [])),
                       WDS.AttachParameters(apn: nil, ipType: nil, otaAttach: nil))
    }

    func testProfileListSkips3GPP2() throws {
        // 3GPP profile 1 "profile1", 3GPP2 profile 5 "x", 3GPP profile 2 "" .
        let v: [UInt8] = [3, 0, 1, 8] + Array("profile1".utf8) + [1, 5, 1] + Array("x".utf8) + [0, 2, 0]
        let list = try WDS.parseProfileList(try response(WDS.getProfileList, [TLV(0x01, v)]))
        XCTAssertEqual(list.map(\.index), [1, 2])
        XCTAssertEqual(list.map(\.name), ["profile1", ""])
    }

    func testAttachListAndEvents() throws {
        // Real Get LTE Attach PDN List reply from the RM551E: current [1], no pending.
        let r = try response(WDS.getLTEAttachPDNList, [TLV(0x10, [1, 1, 0])])
        let l = WDS.parseAttachPDNList(r)
        XCTAssertEqual(l.current, [1])
        XCTAssertEqual(l.pending, [])
        // Same bytes qmid sent in the trace: count 2, (3GPP, 1), (3GPP, 3).
        XCTAssertEqual(WDS.profileEventRegistration([1, 3]), [TLV(0x10, [2, 0, 1, 0, 3])])
        XCTAssertEqual(WDS.attachPDNListRequest([3]), [TLV(0x01, [1, 3, 0])])
    }

    func testAuthenticationAndPDPType() {
        XCTAssertEqual(WDS.Authentication(name: "PAP"), .pap)
        XCTAssertEqual(WDS.Authentication(name: "pap-chap"), .papOrChap)
        XCTAssertNil(WDS.Authentication(name: "md5"))
        XCTAssertEqual(WDS.PDPType(families: [4]), .ipv4)
        XCTAssertEqual(WDS.PDPType(families: [6]), .ipv6)
        XCTAssertEqual(WDS.PDPType(families: [4, 6]), .ipv4v6)
    }
}

final class CallEndTests: XCTestCase {
    private func end(_ type: UInt16, _ reason: UInt16) -> WDS.CallEnd {
        WDS.CallEnd(reason: 1, verboseType: type, verboseReason: reason)
    }

    func testPermanentCauses() {
        XCTAssertTrue(end(6, 51).isPermanent)     // 3GPP: PDN type IPv6 only allowed (XL IMS over IPv4)
        XCTAssertTrue(end(6, 33).isPermanent)     // not subscribed
        XCTAssertTrue(end(6, 27).isPermanent)     // unknown APN
        XCTAssertTrue(end(6, 30).isPermanent)     // rejected by the gateway (RM520N IMS)
        XCTAssertTrue(end(6, 31).isPermanent)     // rejected, unspecified
        XCTAssertTrue(end(2, 208).isPermanent)    // internal: PDN IPv4 call disallowed
        XCTAssertTrue(end(2, 210).isPermanent)    // internal: PDN IPv6 call disallowed
    }

    func testRetryableCauses() {
        XCTAssertFalse(end(6, 36).isPermanent)    // regular deactivation
        XCTAssertFalse(end(6, 26).isPermanent)    // insufficient resources
        XCTAssertFalse(end(2, 209).isPermanent)   // internal: IPv4 throttled
        XCTAssertFalse(end(2, 219).isPermanent)   // internal: low power (airplane mode)
        XCTAssertFalse(end(3, 2000).isPermanent)  // CM cause
        XCTAssertFalse(WDS.CallEnd().isPermanent)
    }

    func testDescription() {
        // The code with its official name: TS 24.301 for 3GPP, QMI's names for the modem's own.
        XCTAssertEqual(end(6, 33).text, "3GPP #33: Requested service option not subscribed")
        XCTAssertEqual(end(6, 51).text, "3GPP #51: PDN type IPv6 only allowed")
        XCTAssertEqual(end(2, 218).text, "internal #218: MMGSDI card event")
        XCTAssertEqual(end(2, 211).text, "internal #211: PDN IPv6 call throttled")
        XCTAssertEqual(end(3, 2001).text, "CM #2001: no service")
        // The log adds the call end reason.
        XCTAssertEqual(end(6, 30).description, "3GPP #30: Request rejected by Serving GW or PDN GW (call end reason 1)")
        // A code not in the tables: the number only.
        XCTAssertEqual(end(6, 200).text, "3GPP #200")
        XCTAssertEqual(end(4, 7).text, "type 4 #7")
        // No verbose cause: the call end reason.
        XCTAssertEqual(WDS.CallEnd(reason: 1018).description, "call end reason 1018: GSM/WCDMA option unsubscribed")
        XCTAssertEqual(WDS.CallEnd(reason: 4242).text, "call end reason 4242")
        XCTAssertEqual(WDS.CallEnd().description, "call end reason ?")
    }

    func testCallEndParts() {
        // For clients: type, number and name apart.
        XCTAssertEqual(end(6, 31).typeName, "3GPP")
        XCTAssertEqual(end(6, 31).code, 31)
        XCTAssertEqual(end(6, 31).codeName, "Request rejected, unspecified")
        XCTAssertEqual(end(2, 210).typeName, "internal")
        XCTAssertNil(end(6, 200).codeName)
        XCTAssertEqual(WDS.CallEnd(reason: 1018).typeName, "call end reason")
        XCTAssertEqual(WDS.CallEnd(reason: 1018).code, 1018)
        XCTAssertEqual(WDS.CallEnd(reason: 1018).codeName, "GSM/WCDMA option unsubscribed")
        XCTAssertNil(WDS.CallEnd().code)
    }

    func testAPNLevelCauses() {
        XCTAssertTrue(end(6, 33).isAPNLevel)      // not subscribed (IMS on a data-only roaming SIM)
        XCTAssertTrue(end(6, 27).isAPNLevel)      // unknown APN
        XCTAssertTrue(end(6, 29).isAPNLevel)      // authentication
        XCTAssertFalse(end(6, 51).isAPNLevel)     // IPv6 only: about the family
        XCTAssertFalse(end(6, 30).isAPNLevel)     // gateway rejected one family (RM520N IMS)
        XCTAssertFalse(end(2, 211).isAPNLevel)
    }
}
