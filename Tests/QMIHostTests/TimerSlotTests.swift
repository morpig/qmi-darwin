@testable import QMIHost
import XCTest

final class TimerSlotTests: XCTestCase {
    private let queue = DispatchQueue(label: "test.timerslot")

    // Waits until everything scheduled on `queue` within `seconds` has run.
    private func drain(after seconds: TimeInterval) {
        let done = expectation(description: "drained")
        queue.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 2)
    }

    func testRunsOnceAndClears() {
        let slot = TimerSlot()
        var runs = 0
        queue.sync { slot.schedule(on: queue, after: 0.01) { runs += 1 } }
        XCTAssertTrue(queue.sync { slot.isScheduled })
        drain(after: 0.05)
        queue.sync {
            XCTAssertEqual(runs, 1)
            XCTAssertFalse(slot.isScheduled)
        }
    }

    // Scheduling again replaces what was pending: only the last runs.
    func testScheduleReplaces() {
        let slot = TimerSlot()
        var ran: [Int] = []
        queue.sync {
            slot.schedule(on: queue, after: 0.01) { ran.append(1) }
            slot.schedule(on: queue, after: 0.02) { ran.append(2) }
        }
        drain(after: 0.06)
        queue.sync { XCTAssertEqual(ran, [2]) }
    }

    func testCancel() {
        let slot = TimerSlot()
        var runs = 0
        queue.sync {
            slot.schedule(on: queue, after: 0.01) { runs += 1 }
            slot.cancel()
            XCTAssertFalse(slot.isScheduled)
        }
        drain(after: 0.05)
        queue.sync { XCTAssertEqual(runs, 0) }
    }

    // The work may schedule the slot again (a retry chain).
    func testRescheduleFromWork() {
        let slot = TimerSlot()
        var runs = 0
        func step() {
            runs += 1
            if runs < 3 { slot.schedule(on: queue, after: 0.01, step) }
        }
        queue.sync { slot.schedule(on: queue, after: 0.01, step) }
        drain(after: 0.15)
        queue.sync {
            XCTAssertEqual(runs, 3)
            XCTAssertFalse(slot.isScheduled)
        }
    }

    // A slot that is gone takes its work with it.
    func testReleasedSlotDoesNotRun() {
        var slot: TimerSlot? = TimerSlot()
        var runs = 0
        queue.sync {
            slot?.schedule(on: queue, after: 0.01) { runs += 1 }
            slot = nil
        }
        drain(after: 0.05)
        queue.sync { XCTAssertEqual(runs, 0) }
    }
}
