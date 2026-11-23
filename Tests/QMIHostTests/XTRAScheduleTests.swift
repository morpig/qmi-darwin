@testable import QMIHost
import QMIDAPI
import QMIKit
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

final class XTRAUpdaterTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_433_600)     // 2026-10-31 08:00 UTC
    private let day: TimeInterval = 24 * 3600
    private struct Unexpected: Error {}

    private func snap(_ validFrom: Date?, unreadable: Bool = false, supported: Bool = true) -> GNSSAssist.Snapshot {
        GNSSAssist.Snapshot(supported: supported, servers: ["https://xtra.example.test/a.bin"],
                            validity: validFrom.map { LOC.XTRAValidity(start: $0, hours: 168) }, unreadable: unreadable)
    }

    private func check(_ s: GNSSAssist.Snapshot, state: XTRAState = XTRAState(), now: Date,
                       fetched: XTRADownload.Result? = nil, sent: ((String?) -> Void)? = nil) -> XTRAUpdater.Outcome {
        XTRAUpdater.check(state: state, maxAge: day, configured: nil, now: now, snapshot: { s },
                          fetch: { servers, since in
                              XCTAssertEqual(servers, ["https://xtra.example.test/a.bin"])
                              sent?(since)
                              guard let fetched else { throw Unexpected() }
                              return fetched
                          },
                          load: { _ in QMIDXTRA(supported: true, validFrom: now, validHours: 168, servers: []) })
    }

    func testCheck() {
        XCTAssertEqual(check(snap(nil, supported: false), now: t0), .unsupported)
        // Fresh data: not due, nothing fetched.
        XCTAssertEqual(check(snap(t0), now: t0 + 3600), .notDue(t0 + day))
        // Stale: fetched with If-Modified-Since, and loaded.
        var st = XTRAState()
        st.lastModified = "Sat, 31 Oct 2026 07:00:00 GMT"
        var since: String?? = .none
        let newer = "Sun, 01 Nov 2026 08:00:00 GMT"
        XCTAssertEqual(check(snap(t0), state: st, now: t0 + 2 * day, fetched: .file([1], lastModified: newer, from: "h"),
                             sent: { since = $0 }),
                       .loaded(QMIDXTRA(supported: true, validFrom: t0 + 2 * day, validHours: 168, servers: []),
                               lastModified: newer, from: "h"))
        XCTAssertEqual(since, .some(st.lastModified))
        // No data: no If-Modified-Since.
        _ = check(snap(nil), state: st, now: t0, fetched: .notModified(from: "h"), sent: { since = $0 })
        XCTAssertEqual(since, .some(nil))
        XCTAssertEqual(check(snap(t0), now: t0 + 2 * day, fetched: .notModified(from: "h")), .notNewer("not modified on h"))
        // A file no newer than the data held is not loaded, unless the modem's state is unreadable.
        let older = "Sat, 31 Oct 2026 07:00:00 GMT"
        XCTAssertEqual(check(snap(t0), now: t0 + 2 * day, fetched: .file([1], lastModified: older, from: "h")),
                       .notNewer("h has nothing newer (\(older))"))
        if case .loaded = check(snap(t0, unreadable: true), now: t0 + 2 * day, fetched: .file([1], lastModified: older, from: "h")) {} else {
            XCTFail("an unreadable state takes any file")
        }
        if case .failed = check(snap(nil), now: t0) {} else { XCTFail("a fetch error is a failure") }
    }

    func testApply() {
        var st = XTRAState()
        var r = XTRAUpdater.apply(.failed("x"), to: &st, now: t0, maxAge: day)
        XCTAssertEqual(st.failures, 1)
        XCTAssertEqual(st.lastError, "x")
        XCTAssertEqual(r.next, t0 + 15 * 60)
        XCTAssertEqual(r.log?.level, .error)
        r = XTRAUpdater.apply(.failed("y"), to: &st, now: t0, maxAge: day)
        XCTAssertEqual(r.next, t0 + 3600)
        r = XTRAUpdater.apply(.notNewer("same"), to: &st, now: t0, maxAge: day)
        XCTAssertEqual(r.next, t0 + XTRASchedule.notNewerDelay)
        XCTAssertEqual(st.failures, 2)                              // a "not newer" is no success
        r = XTRAUpdater.apply(.loaded(QMIDXTRA(supported: true, validFrom: t0, validHours: 168, servers: []),
                                      lastModified: "lm", from: "h"), to: &st, now: t0, maxAge: day)
        XCTAssertEqual(st.failures, 0)
        XCTAssertNil(st.notBefore)
        XCTAssertNil(st.lastError)
        XCTAssertEqual(st.lastModified, "lm")
        XCTAssertEqual(st.lastDownload, t0)
        XCTAssertEqual(r.next, t0 + XTRASchedule.checkInterval)    // due in 24 h, looked at within 6 h
        XCTAssertEqual(r.log?.level, .notice)
        r = XTRAUpdater.apply(.unsupported, to: &st, now: t0, maxAge: day)
        XCTAssertNil(r.next)
        r = XTRAUpdater.apply(.notDue(t0 + 600), to: &st, now: t0, maxAge: day)
        XCTAssertEqual(r.next, t0 + 600)
        XCTAssertNil(r.log)
    }
}
