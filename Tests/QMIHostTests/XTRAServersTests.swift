@testable import QMIHost
import XCTest

final class XTRAServersTests: XCTestCase {
    func testServerOrder() {
        let modem = ["https://modem.example/x"], mine = ["https://mine.example/x"]
        XCTAssertEqual(XTRADownload.servers(configured: mine, modem: modem), mine)
        XCTAssertEqual(XTRADownload.servers(configured: [], modem: modem), modem)
        XCTAssertEqual(XTRADownload.servers(configured: nil, modem: modem), modem)
        XCTAssertEqual(XTRADownload.servers(configured: nil, modem: []), XTRADownload.builtInServers)
        XCTAssertTrue(XTRADownload.builtInServers.allSatisfy { $0.hasPrefix("https://") })
    }

    func testAnotherModemStartsOver() {
        var s = XTRAState()
        s.modem = "1"
        s.lastModified = "yesterday"
        s.failures = 2
        s.lastError = "timeout"
        s.notBefore = Date()

        var same = s
        same.use(modem: "1")
        XCTAssertEqual(same, s)
        var unknown = s
        unknown.use(modem: nil)
        XCTAssertEqual(unknown, s)

        var other = s
        other.use(modem: "2")
        XCTAssertEqual(other.modem, "2")
        XCTAssertNil(other.lastModified)
        XCTAssertEqual(other.failures, 0)
        XCTAssertNil(other.lastError)
        XCTAssertNil(other.notBefore)

        let back = XTRAState(s.json)
        XCTAssertEqual(back.modem, "1")
    }

    func testConfigRejectsPlainHTTPServers() throws {
        var c = QMIDConfig(pdns: [])
        c.xtra = QMIDConfig.XTRA(servers: ["http://path1.example/x"])
        XCTAssertThrowsError(try c.validate())
        c.xtra = QMIDConfig.XTRA(servers: ["https://path1.example/x"])
        XCTAssertNoThrow(try c.validate())
    }
}
