import Foundation

// Client for qmid's XPC API. One instance per app is enough.
//
//   let qmid = QMIDClient()
//   qmid.onEvent = { event in ... }          // main queue by default
//   qmid.onSIM = { sim in ... }              // SIM and default bearer APN
//   qmid.onPLMN = { plmn in ... }            // registered network and operator names
//   qmid.onBearers = { pdn, bearers in ... } // dedicated bearers (QCI, rates, TFT) of a PDN
//   qmid.subscribe()                         // events now and after qmid restarts
//   qmid.status { result in ... }
//   qmid.onLog = { entry in ... }
//   qmid.subscribeLogs(level: .debug)        // recent history, then live; kept across restarts
//
// qmid is started by launchd on demand, so the first call works even if it isn't running.
// If qmid restarts (crash, update), the connection is re-established and the subscription
// renewed; `onAvailabilityChange` reports the gap.
public final class QMIDClient: NSObject, QMIDEvents {
    public var onEvent: ((QMIDEvent) -> Void)?
    public var onAvailabilityChange: ((Bool) -> Void)?
    // Log lines after subscribeLogs. If this client fell behind and qmid dropped lines, a
    // notice entry saying how many comes first.
    public var onLog: ((QMIDLogEntry) -> Void)?
    // The SIM and default bearer: after subscribe() and whenever they change; nil when no SIM
    // is known (modem away). onEvent sees these as .unknown(type: "sim").
    public var onSIM: ((QMIDSIM?) -> Void)?
    // The registered network and its operator names: after subscribe() and whenever they
    // change; nil while not registered. onEvent sees these as .unknown(type: "plmn").
    public var onPLMN: ((QMIDPLMN?) -> Void)?
    // A PDN's dedicated bearers (full list): after subscribe() for each connected PDN, and
    // whenever they change; an empty list when the last one goes or the PDN goes down.
    // onEvent sees these as .unknown(type: "bearers").
    public var onBearers: ((_ pdn: String, _ bearers: [QMIDBearer]) -> Void)?

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var subscribed = false
    private var logLevel: QMIDLogLevel?
    private var lastLogTime: Double = 0
    private var renewalPending = false
    private var available: Bool?

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
        super.init()
    }

    deinit { connection?.invalidate() }

    public func invalidate() {
        lock.lock()
        subscribed = false
        logLevel = nil
        let c = connection
        connection = nil
        lock.unlock()
        c?.invalidate()
    }

    // MARK: Connection

    private func currentConnection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let c = connection { return c }
        let c = NSXPCConnection(machServiceName: qmidMachService, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: QMIDControl.self)
        c.exportedInterface = NSXPCInterface(with: QMIDEvents.self)
        c.exportedObject = self
        c.interruptionHandler = { [weak self] in
            // qmid went away (crash or restart); launchd starts it again on the next message.
            self?.setAvailable(false)
            self?.resubscribe(after: 1)
        }
        c.invalidationHandler = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.connection === c { self.connection = nil }
            self.lock.unlock()
            self.setAvailable(false)
            self.resubscribe(after: 2)
        }
        c.resume()
        connection = c
        return c
    }

    private func proxy(_ fail: @escaping (QMIDError) -> Void) -> QMIDControl? {
        currentConnection().remoteObjectProxyWithErrorHandler { [weak self] error in
            self?.queue.async { fail(QMIDError(xpc: error)) }
        } as? QMIDControl
    }

    private func setAvailable(_ value: Bool) {
        lock.lock()
        let changed = available != value
        available = value
        lock.unlock()
        if changed { queue.async { self.onAvailabilityChange?(value) } }
    }

    // MARK: Events

    // Starts (and keeps) the event subscription. The current state arrives as events first.
    public func subscribe() {
        lock.lock(); subscribed = true; lock.unlock()
        resubscribe(after: 0)
    }

    // Starts (or changes the level of) the log subscription. With `history`, qmid first sends
    // the recent lines it still holds; later renewals (after qmid restarts) continue from the
    // last line received.
    public func subscribeLogs(level: QMIDLogLevel = .info, history: Bool = true) {
        lock.lock()
        logLevel = level
        if !history { lastLogTime = Date().timeIntervalSince1970 }
        lock.unlock()
        resubscribe(after: 0)
    }

    public func unsubscribeLogs() {
        lock.lock(); logLevel = nil; lock.unlock()
        proxy { _ in }?.unsubscribeLogs {}
    }

    // Renews the event and log subscriptions this client wants (initially, and after qmid
    // restarts or the connection drops).
    // Interruption, invalidation and failed calls can all ask for a renewal at once; only one
    // is kept pending, so qmid doesn't get the subscription (and send its snapshot) twice.
    private func resubscribe(after delay: TimeInterval) {
        lock.lock()
        let wanted = subscribed || logLevel != nil
        guard wanted, !renewalPending else { lock.unlock(); return }
        renewalPending = true
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.renewalPending = false
            let events = self.subscribed
            let level = self.logLevel
            self.lock.unlock()
            let p = self.proxy { _ in self.resubscribe(after: 3) }
            if events {
                p?.subscribe { ok in
                    if ok { self.setAvailable(true) } else { self.resubscribe(after: 3) }
                }
            }
            if let level {
                self.lock.lock(); let since = self.lastLogTime; self.lock.unlock()
                p?.subscribeLogs(level.rawValue, since: since) { ok in
                    if ok { self.setAvailable(true) } else if !events { self.resubscribe(after: 3) }
                }
            }
        }
    }

    public func qmidEvent(_ event: NSDictionary) {
        if event[QMIDKey.type] as? String == QMIDEventType.log {
            var entries = (event[QMIDKey.entries] as? [NSDictionary] ?? []).compactMap(QMIDLogEntry.init)
            if let n = event[QMIDKey.dropped] as? Int, n > 0 {
                let t = entries.first?.time ?? Date()
                entries.insert(QMIDLogEntry(time: t, level: .notice, category: "client",
                                            message: "\(n) log lines dropped (client fell behind)"), at: 0)
            }
            guard let last = entries.last else { return }
            lock.lock(); lastLogTime = max(lastLogTime, last.time.timeIntervalSince1970); lock.unlock()
            queue.async { entries.forEach { self.onLog?($0) } }
            return
        }
        if event[QMIDKey.type] as? String == QMIDEventType.sim {
            let sim = QMIDSIM(event[QMIDKey.sim] as? NSDictionary)
            queue.async { self.onSIM?(sim) }
        }
        if event[QMIDKey.type] as? String == QMIDEventType.plmn {
            let plmn = QMIDPLMN(event[QMIDKey.plmn] as? NSDictionary)
            queue.async { self.onPLMN?(plmn) }
        }
        if event[QMIDKey.type] as? String == QMIDEventType.bearers, let pdn = event[QMIDKey.pdn] as? String {
            let bearers = (event[QMIDKey.bearers] as? [NSDictionary] ?? []).compactMap(QMIDBearer.init)
            queue.async { self.onBearers?(pdn, bearers) }
        }
        guard let e = QMIDEvent(event) else { return }
        queue.async { self.onEvent?(e) }
    }

    // MARK: Calls (completion on `queue`)

    public func apiVersion(_ completion: @escaping (Result<Int, QMIDError>) -> Void) {
        proxy { completion(.failure($0)) }?.apiVersion { v in self.queue.async { completion(.success(v)) } }
    }

    public func status(_ completion: @escaping (Result<QMIDStatus, QMIDError>) -> Void) {
        proxy { completion(.failure($0)) }?.status { d in
            self.setAvailable(true)
            self.queue.async { completion(.success(QMIDStatus(d))) }
        }
    }

    // Completes when the attempt has ended. On failure the error carries the PDN as the
    // attempt left it (error.pdn: reason, causes), read with a status call.
    public func connect(pdn: String, _ completion: @escaping (Result<Void, QMIDError>) -> Void) {
        proxy { completion(.failure($0)) }?.connect(pdn) { err in
            guard let err else { return self.finish(nil, completion) }
            self.proxy { _ in self.finish(err, completion) }?.status { d in
                var e = QMIDError(err)
                e.pdn = QMIDStatus(d).pdn(pdn)
                self.queue.async { completion(.failure(e)) }
            }
        }
    }

    public func disconnect(pdn: String, _ completion: @escaping (Result<Void, QMIDError>) -> Void) {
        proxy { completion(.failure($0)) }?.disconnect(pdn) { self.finish($0, completion) }
    }

    public func setPolicy(pdn: String, policy: String, _ completion: @escaping (Result<Void, QMIDError>) -> Void) {
        proxy { completion(.failure($0)) }?.setPolicy(pdn, policy: policy) { self.finish($0, completion) }
    }

    public func reload(_ completion: @escaping (Result<Void, QMIDError>) -> Void) {
        proxy { completion(.failure($0)) }?.reload { self.finish($0, completion) }
    }

    public func restart(_ completion: @escaping (Result<Void, QMIDError>) -> Void) {
        proxy { completion(.failure($0)) }?.restart { self.finish($0, completion) }
    }

    public func getConfig(_ completion: @escaping (Result<Data, QMIDError>) -> Void) {
        proxy { completion(.failure($0)) }?.getConfig { data, err in
            self.queue.async {
                if let data { completion(.success(data)) } else { completion(.failure(QMIDError(err ?? "no config"))) }
            }
        }
    }

    public func setConfig(_ json: Data, _ completion: @escaping (Result<Void, QMIDError>) -> Void) {
        proxy { completion(.failure($0)) }?.setConfig(json) { self.finish($0, completion) }
    }

    private func finish(_ err: String?, _ completion: @escaping (Result<Void, QMIDError>) -> Void) {
        queue.async { completion(err.map { .failure(QMIDError($0)) } ?? .success(())) }
    }
}

// async/await variants.
@available(macOS 10.15, *)
public extension QMIDClient {
    func status() async throws -> QMIDStatus { try await bridge { self.status($0) } }
    func connect(pdn: String) async throws { try await bridge { self.connect(pdn: pdn, $0) } }
    func disconnect(pdn: String) async throws { try await bridge { self.disconnect(pdn: pdn, $0) } }
    func setPolicy(pdn: String, policy: String) async throws { try await bridge { self.setPolicy(pdn: pdn, policy: policy, $0) } }
    func reload() async throws { try await bridge { self.reload($0) } }
    func restart() async throws { try await bridge { self.restart($0) } }
    func getConfig() async throws -> Data { try await bridge { self.getConfig($0) } }
    func setConfig(_ json: Data) async throws { try await bridge { self.setConfig(json, $0) } }

    private func bridge<T>(_ call: (@escaping (Result<T, QMIDError>) -> Void) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { cont in call { cont.resume(with: $0) } }
    }
}
