@testable import QMIHost
import XCTest

final class XTRAScheduleTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_433_600)     // 2026-10-31 08:00 UTC
    private let day: TimeInterval = 24 * 3600

    func testLoadDue() {
        // Data 2 h old, max age 24 h: due when it turns 24 h.
        XCTAssertEqual(XTRASchedule.loadDue(validFrom: t0, unreadable: false, now: t0 + 7200, maxAge: day, notBefore: nil), t0 + day)
        // Stale: due at once (the due time is in the past).
        XCTAssertLessThan(XTRASchedule.loadDue(validFrom: t0, unreadable: false, now: t0 + 2 * day, maxAge: day, notBefore: nil), t0 + 2 * day)
        // No data, or unreadable: now.
        XCTAssertEqual(XTRASchedule.loadDue(validFrom: nil, unreadable: false, now: t0, maxAge: day, notBefore: nil), t0)
        XCTAssertEqual(XTRASchedule.loadDue(validFrom: t0, unreadable: true, now: t0 + 60, maxAge: day, notBefore: nil), t0 + 60)
        // Never before notBefore (backoff, nothing newer).
        XCTAssertEqual(XTRASchedule.loadDue(validFrom: nil, unreadable: false, now: t0, maxAge: day, notBefore: t0 + 900), t0 + 900)
    }

    func testNextCheck() {
        XCTAssertEqual(XTRASchedule.nextCheck(due: t0 + day, now: t0), t0 + 6 * 3600)   // at least every 6 h
        XCTAssertEqual(XTRASchedule.nextCheck(due: t0 + 3600, now: t0), t0 + 3600)
        XCTAssertEqual(XTRASchedule.nextCheck(due: t0 - 10, now: t0), t0 + 60)          // not sooner than a minute
    }

    func testRetryDelay() {
        XCTAssertEqual([1, 2, 3, 9].map(XTRASchedule.retryDelay), [900, 3600, 21600, 21600])
    }

    func testNewer() throws {
        let lm = try XCTUnwrap(XTRASchedule.httpDate("Sat, 31 Oct 2026 08:31:44 GMT"))
        XCTAssertEqual(lm, t0 + 31 * 60 + 44)
        XCTAssertTrue(XTRASchedule.isNewer(lastModified: lm, than: t0))
        XCTAssertFalse(XTRASchedule.isNewer(lastModified: lm, than: t0 + 3600))       // older than the modem's data
        XCTAssertTrue(XTRASchedule.isNewer(lastModified: nil, than: t0))              // unknown: load
        XCTAssertTrue(XTRASchedule.isNewer(lastModified: lm, than: nil))              // no data: load
        XCTAssertNil(XTRASchedule.httpDate("yesterday"))
    }

    func testState() {
        var s = XTRAState()
        s.lastModified = "Sat, 31 Oct 2026 08:31:44 GMT"
        s.lastDownload = t0
        s.failures = 2
        s.lastError = "HTTP 503"
        s.notBefore = t0 + 3600
        XCTAssertEqual(XTRAState(s.json), s)
        XCTAssertEqual(XTRAState(nil), XTRAState())
    }

    func testConfig() throws {
        func decode(_ json: String) throws -> QMIDConfig { try QMIDConfig.decode(Data(json.utf8)) }
        let d = try decode(#"{ "pdns": [] }"#)
        XCTAssertTrue(d.xtraSettings.downloads)
        XCTAssertEqual(d.xtraSettings.maxAge, 24 * 3600)
        let c = try decode(#"{ "xtra": { "download": false, "maxAgeHours": 12 }, "pdns": [] }"#)
        XCTAssertFalse(c.xtraSettings.downloads)
        XCTAssertEqual(c.xtraSettings.maxAge, 12 * 3600)
        XCTAssertThrowsError(try decode(#"{ "xtra": { "maxAgeHours": 200 }, "pdns": [] }"#))
    }
}
