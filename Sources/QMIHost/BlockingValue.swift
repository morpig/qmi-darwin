import Foundation

// One value that a callback on another thread delivers to a thread blocked waiting for it.
// The first put wins; a put after the wait has ended (timed out) is dropped, so the waiter never
// reads a value while it is being written.
final class BlockingValue<T> {
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var value: T?
    private var settled = false             // a value was put, or the wait is over

    init() {}

    func put(_ v: T) {
        lock.lock()
        defer { lock.unlock() }
        guard !settled else { return }
        settled = true
        value = v
        ready.signal()
    }

    // The value, or nil if none came within `timeout` (seconds, at least 0). Call once.
    func wait(timeout: TimeInterval) -> T? {
        _ = ready.wait(timeout: .now() + max(0, timeout))
        lock.lock()
        defer { lock.unlock() }
        settled = true
        return value
    }
}
