import Foundation

// One piece of delayed work at a time: scheduling replaces what was pending, cancel drops it.
// Used from one queue only (the one it schedules on). The work doesn't run once the slot is
// gone, so a slot owned by an object ends with it.
final class TimerSlot {
    private var item: DispatchWorkItem?
    private var generation = 0

    // Scheduled and not yet run (or cancelled).
    var isScheduled: Bool { item != nil }

    func schedule(on queue: DispatchQueue, after seconds: TimeInterval, _ work: @escaping () -> Void) {
        cancel()
        let gen = generation
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.generation == gen else { return }
            self.item = nil
            work()
        }
        self.item = item
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func cancel() {
        item?.cancel()
        item = nil
        generation += 1
    }
}
