import Foundation
import QMIDAPI

// Keeps recent log lines in memory and pushes new ones to XPC log subscribers (PLAN.md §8.1a).
//
// Two rings, so a burst of trace lines doesn't push the regular log out of the history.
// Each subscriber has its own level and a capped queue: one batch is in flight at a time (the
// next goes out once XPC has sent the previous one), and if a client falls behind the oldest
// queued lines are dropped and counted, so a slow client can't grow qmid's memory.
final class LogHub {
    static let ringSize = 2000
    static let queueCap = 5000
    static let batchMax = 500

    private final class Subscriber {
        let connection: NSXPCConnection
        let proxy: QMIDEvents
        var level: QMIDLogLevel
        var pending: [NSDictionary] = []
        var dropped = 0
        var inFlight = false

        init(_ c: NSXPCConnection, level: QMIDLogLevel) {
            connection = c
            proxy = c.remoteObjectProxyWithErrorHandler { _ in } as! QMIDEvents
            self.level = level
        }
    }

    private let queue = DispatchQueue(label: "qmid.logs")
    private var ring: [QMIDLogEntry] = []            // info and above
    private var traceRing: [QMIDLogEntry] = []       // debug
    private var subscribers: [ObjectIdentifier: Subscriber] = [:]

    // Read per QMI message on the manager queue, so kept outside `queue`.
    private let flagLock = NSLock()
    private var debugSubscribers = 0
    var wantsDebug: Bool { flagLock.lock(); defer { flagLock.unlock() }; return debugSubscribers > 0 }

    func append(_ level: QMIDLogLevel, _ category: String, _ message: String) {
        let e = QMIDLogEntry(time: Date(), level: level, category: category, message: message)
        queue.async {
            if level == .debug { Self.push(e, to: &self.traceRing) } else { Self.push(e, to: &self.ring) }
            let d = e.dictionary
            for s in self.subscribers.values where level >= s.level {
                self.enqueue([d], for: s)
            }
        }
    }

    // New subscription: history newer than `since` first. Existing one: level change only.
    func subscribe(_ c: NSXPCConnection, level: QMIDLogLevel, since: Double) {
        queue.async {
            let id = ObjectIdentifier(c)
            if let s = self.subscribers[id] {
                s.level = level
            } else {
                let s = Subscriber(c, level: level)
                self.subscribers[id] = s
                let history = (self.ring + (level == .debug ? self.traceRing : []))
                    .filter { $0.level >= level && $0.time.timeIntervalSince1970 > since }
                    .sorted { $0.time < $1.time }
                self.enqueue(history.map(\.dictionary), for: s)
            }
            self.updateDebugFlag()
        }
    }

    func remove(_ c: NSXPCConnection) {
        queue.async {
            guard self.subscribers.removeValue(forKey: ObjectIdentifier(c)) != nil else { return }
            self.updateDebugFlag()
        }
    }

    // MARK: - On `queue`

    private static func push(_ e: QMIDLogEntry, to ring: inout [QMIDLogEntry]) {
        ring.append(e)
        if ring.count > ringSize + ringSize / 4 { ring.removeFirst(ring.count - ringSize) }
    }

    private func updateDebugFlag() {
        let n = subscribers.values.filter { $0.level == .debug }.count
        flagLock.lock(); debugSubscribers = n; flagLock.unlock()
    }

    private func enqueue(_ entries: [NSDictionary], for s: Subscriber) {
        guard !entries.isEmpty else { return }
        s.pending.append(contentsOf: entries)
        if s.pending.count > Self.queueCap {
            let n = s.pending.count - Self.queueCap
            s.pending.removeFirst(n)
            s.dropped += n
        }
        flush(s)
    }

    private func flush(_ s: Subscriber) {
        guard !s.inFlight, !s.pending.isEmpty else { return }
        let batch = Array(s.pending.prefix(Self.batchMax))
        s.pending.removeFirst(batch.count)
        var event: [String: Any] = [QMIDKey.type: QMIDEventType.log, QMIDKey.entries: batch]
        if s.dropped > 0 { event[QMIDKey.dropped] = s.dropped }
        s.dropped = 0
        s.inFlight = true
        s.proxy.qmidEvent(event as NSDictionary)
        s.connection.scheduleSendBarrierBlock { [weak self, weak s] in
            guard let self else { return }
            self.queue.async {
                guard let s, self.subscribers[ObjectIdentifier(s.connection)] === s else { return }
                s.inFlight = false
                self.flush(s)
            }
        }
    }
}

let logHub = LogHub()
