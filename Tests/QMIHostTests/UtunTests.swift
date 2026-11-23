@testable import QMIHost
import QMIKit
import XCTest

final class UtunTests: XCTestCase {
    private func prefix(_ last: UInt8, length: UInt8 = 64) -> IPv6Prefix {
        IPv6Prefix(address: IPv6([0x24, 0x0e, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, last]), length: length)
    }

    func testIPv6AddressReplacedNotAdded() {
        let a = prefix(1), b = prefix(2)
        XCTAssertEqual(Utun.ipv6Commands("utun9", old: nil, new: a),
                       [["utun9", "inet6", "\(a.address)", "prefixlen", "64", "alias"]])
        // Refresh with the same address: nothing to do.
        XCTAssertEqual(Utun.ipv6Commands("utun9", old: a, new: a), [])
        // A new address (or prefix length): the old one goes first.
        XCTAssertEqual(Utun.ipv6Commands("utun9", old: a, new: b),
                       [["utun9", "inet6", "\(a.address)", "delete"],
                        ["utun9", "inet6", "\(b.address)", "prefixlen", "64", "alias"]])
        XCTAssertEqual(Utun.ipv6Commands("utun9", old: a, new: prefix(1, length: 56)).count, 2)
        // WDS no longer reports v6: the old address goes.
        XCTAssertEqual(Utun.ipv6Commands("utun9", old: a, new: nil), [["utun9", "inet6", "\(a.address)", "delete"]])
        XCTAssertEqual(Utun.ipv6Commands("utun9", old: nil, new: nil), [])
    }
}

final class ShellTests: XCTestCase {
    // More than a pipe's buffer (64 KB): read while the command runs, or it never exits.
    func testLargeOutput() throws {
        let out = try Shell.run("/bin/sh", ["-c", "head -c 300000 /dev/zero | tr '\\0' x"])
        XCTAssertEqual(out.count, 300_000)
    }

    func testFailureCarriesOutput() {
        XCTAssertThrowsError(try Shell.run("/bin/sh", ["-c", "echo nope >&2; exit 3"])) { e in
            XCTAssertEqual("\(e)", "/bin/sh -c echo nope >&2; exit 3: nope")
        }
    }
}

final class BlockingValueTests: XCTestCase {
    func testValueFromAnotherThread() {
        let v = BlockingValue<Int>()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { v.put(7); v.put(8) }
        XCTAssertEqual(v.wait(timeout: 5), 7)
    }

    func testLatePutIsDropped() {
        let v = BlockingValue<Int?>()
        XCTAssertTrue(v.wait(timeout: 0.01) == nil)
        v.put(1)                                    // after the timeout: ignored
        let w = BlockingValue<Int?>()
        w.put(nil)
        let got: Int?? = w.wait(timeout: 0)
        XCTAssertTrue(got != nil && got! == nil)    // an optional value is told from no value
    }
}
