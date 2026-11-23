import Foundation

// Client for qmid's XPC API. One instance per app is enough.
//
//   let qmid = QMIDClient()
//   qmid.onEvent = { event in ... }          // main queue by default
//   qmid.onModem = { modem in ... }          // modem state, network, airplane mode
//   qmid.onSIM = { sim in ... }              // SIM and default bearer APN
//   qmid.onPLMN = { plmn in ... }            // registered network and operator names
//   qmid.onBearers = { pdn, bearers in ... } // dedicated bearers (QCI, rates, TFT) of a PDN
//   qmid.onRadio = { radio in ... }          // serving cells, carrier aggregation, RRC state
//   qmid.subscribe()                         // events now and after qmid restarts
//   qmid.status { result in ... }
//   qmid.onLog = { entry in ... }
//   qmid.subscribeLogs(level: .debug)        // recent history, then live; kept across restarts
//   qmid.onLocation = { loc in ... }         // GNSS positions, after startLocation
//   qmid.startLocation(satellites: true)     // GNSS on while this client wants it; kept across restarts
//
// Command-line tools can block on a call with sync (on a client whose queue isn't the
// calling thread's):
//
//   let qmid = QMIDClient(queue: DispatchQueue(label: "qmid"))
//   let status = qmid.sync(timeout: 5) { qmid.status($0) }
//
// qmid is started by launchd on demand, so the first call works even if it isn't running.
// If qmid restarts (crash, update), the connection is re-established and the subscription
// renewed; `onAvailabilityChange` reports the gap.
public final class QMIDClient: NSObject, QMIDEvents {
    // Events of types modem, pdn and config, and of types this client has no callback for (as
    // .unknown); also sim, plmn, bearers, gnss, sharing and radio, which their own callbacks
    // get too. Not log, location, satellites or nmea: those go only to their callbacks.
    public var onEvent: ((QMIDEvent) -> Void)?
    // The modem's state, network and airplane mode: after subscribe() and whenever they
    // change. onEvent sees these as .modem.
    public var onModem: ((QMIDModem) -> Void)?
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
    // After startLocation: positions (about one per interval), satellites (at most every 5 s,
    // sooner when one is gained, lost or used) and NMEA sentences, if asked for.
    public var onLocation: ((QMIDLocation) -> Void)?
    public var onSatellites: ((QMIDSatellites) -> Void)?
    public var onNMEA: ((String) -> Void)?
    // The GNSS engine / session (after subscribe(), to every subscriber); no position.
    public var onGNSS: ((QMIDGNSS) -> Void)?
    // Internet Sharing over a PDN (config "sharing"): after subscribe() and whenever it changes.
    public var onSharing: ((QMIDSharing) -> Void)?
    // The radio (as radio()): after subscribe() and whenever the serving cells, their roles,
    // channels or activation, EN-DC or the RRC state change; nil while the modem isn't ready.
    // Signal and neighbours are as read at that moment and don't trigger a call: poll radio()
    // for those. onEvent sees these as .unknown(type: "radio").
    public var onRadio: ((QMIDRadio?) -> Void)?

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var subscribed = false
    private var logLevel: QMIDLogLevel?
    private var locationOptions: NSDictionary?  // startLocation, renewed after qmid restarts
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
        locationOptions = nil
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

    // The queue is captured, not self: a failure must reach its completion (and an async
    // caller's continuation) even when the client is gone.
    private func proxy(_ fail: @escaping (QMIDError) -> Void) -> QMIDControl? {
        let queue = self.queue
        return currentConnection().remoteObjectProxyWithErrorHandler { error in
            queue.async { fail(QMIDError(xpc: error)) }
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
        let wanted = subscribed || logLevel != nil || locationOptions != nil
        guard wanted, !renewalPending else { lock.unlock(); return }
        renewalPending = true
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.renewalPending = false
            let events = self.subscribed
            let level = self.logLevel
            let location = self.locationOptions
            self.lock.unlock()
            let p = self.proxy { _ in self.resubscribe(after: 3) }
            // qmid replies to startLocation with nil while the connection lives; a failed
            // call goes through the proxy's error handler above.
            if let location {
                p?.startLocation(location) { err in
                    if err == nil { self.setAvailable(true) }
                }
            }
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

    // One case per type: its callback, and whether onEvent sees it too (see onEvent).
    public func qmidEvent(_ event: NSDictionary) {
        let type = event[QMIDKey.type] as? String
        var toEvent = true
        switch type {
        case QMIDEventType.log?:
            toEvent = false
            var entries = (event[QMIDKey.entries] as? [NSDictionary] ?? []).compactMap(QMIDLogEntry.init)
            if let n = event[QMIDKey.dropped] as? Int, n > 0 {
                let t = entries.first?.time ?? Date()
                entries.insert(QMIDLogEntry(time: t, level: .notice, category: "client",
                                            message: "\(n) log lines dropped (client fell behind)"), at: 0)
            }
            if let last = entries.last {
                lock.lock(); lastLogTime = max(lastLogTime, last.time.timeIntervalSince1970); lock.unlock()
                queue.async { entries.forEach { self.onLog?($0) } }
            }
        case QMIDEventType.modem?:
            let m = QMIDModem(event)
            queue.async { self.onModem?(m) }
        case QMIDEventType.sim?:
            let sim = QMIDSIM(event[QMIDKey.sim] as? NSDictionary)
            queue.async { self.onSIM?(sim) }
        case QMIDEventType.plmn?:
            let plmn = QMIDPLMN(event[QMIDKey.plmn] as? NSDictionary)
            queue.async { self.onPLMN?(plmn) }
        case QMIDEventType.bearers?:
            if let pdn = event[QMIDKey.pdn] as? String {
                let bearers = (event[QMIDKey.bearers] as? [NSDictionary] ?? []).compactMap(QMIDBearer.init)
                queue.async { self.onBearers?(pdn, bearers) }
            }
        case QMIDEventType.gnss?:
            if let d = event[QMIDKey.gnss] as? NSDictionary {
                let g = QMIDGNSS(d)
                queue.async { self.onGNSS?(g) }
            }
        case QMIDEventType.sharing?:
            if let s = (event[QMIDKey.sharing] as? NSDictionary).flatMap(QMIDSharing.init) {
                queue.async { self.onSharing?(s) }
            }
        case QMIDEventType.radio?:
            let r = (event[QMIDKey.radio] as? NSDictionary).map(QMIDRadio.init)
            queue.async { self.onRadio?(r) }
        case QMIDEventType.location?:
            toEvent = false
            if let d = event[QMIDKey.location] as? NSDictionary {
                let l = QMIDLocation(d)
                queue.async { self.onLocation?(l) }
            }
        case QMIDEventType.satellites?:
            toEvent = false
            let s = QMIDSatellites(event)
            queue.async { self.onSatellites?(s) }
        case QMIDEventType.nmea?:
            toEvent = false
            if let n = event[QMIDKey.nmea] as? String { queue.async { self.onNMEA?(n) } }
        default:
            break                               // pdn, config, newer types: onEvent only
        }
        guard toEvent, let e = QMIDEvent(event) else { return }
        queue.async { self.onEvent?(e) }
    }

    // Starts location for this client (see QMIDControl.startLocation); kept across qmid
    // restarts until stopLocation. Calling it again changes the options.
    public func startLocation(interval: TimeInterval = 1, satellites: Bool = false, nmea: Bool = false,
                              _ completion: ((Result<Void, QMIDError>) -> Void)? = nil) {
        let o: NSDictionary = [QMIDKey.interval: max(1000, Int(interval * 1000)), QMIDKey.satellites: satellites,
                               QMIDKey.nmea: nmea]
        lock.lock(); locationOptions = o; lock.unlock()
        proxy { e in completion?(.failure(e)) }?.startLocation(o) { err in
            if err == nil { self.setAvailable(true) }
            if let completion { self.finish(err, completion) }
        }
    }

    public func stopLocation(_ completion: ((Result<Void, QMIDError>) -> Void)? = nil) {
        lock.lock(); locationOptions = nil; lock.unlock()
        proxy { e in completion?(.failure(e)) }?.stopLocation { err in
            if let completion { self.finish(err, completion) }
        }
    }

    public func gnss(_ completion: @escaping (Result<QMIDGNSS, QMIDError>) -> Void) {
        proxy { completion(.failure($0)) }?.gnss { d in self.queue.async { completion(.success(QMIDGNSS(d))) } }
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

    public func setPolicy(pdn: String, policy: QMIDPolicy, _ completion: @escaping (Result<Void, QMIDError>) -> Void) {
        setPolicy(pdn: pdn, policy: policy.rawValue, completion)
    }

    public func reload(_ completion: @escaping (Result<Void, QMIDError>) -> Void) {
        proxy { completion(.failure($0)) }?.reload { self.finish($0, completion) }
    }

    // What qmid did with the modem's data profiles; an empty report while the modem isn't open.
    public func profiles(_ completion: @escaping (Result<QMIDProfileReport, QMIDError>) -> Void) {
        proxy { completion(.failure($0)) }?.profiles { list in self.queue.async { completion(.success(QMIDProfileReport(list))) } }
    }

    public func restart(_ completion: @escaping (Result<Void, QMIDError>) -> Void) {
        proxy { completion(.failure($0)) }?.restart { self.finish($0, completion) }
    }

    public func getConfig(_ completion: @escaping (Result<Data, QMIDError>) -> Void) {
        proxy { completion(.failure($0)) }?.getConfig { self.finish($0, $1, "no config", { $0 }, completion) }
    }

    public func setConfig(_ json: Data, _ completion: @escaping (Result<Void, QMIDError>) -> Void) {
        proxy { completion(.failure($0)) }?.setConfig(json) { self.finish($0, completion) }
    }

    // Call before switching SIMs and wait for the result (see QMIDControl.prepareSIM); on
    // failure, switch anyway. The prepare lasts while this client's connection does.
    public func prepareSIM(iccid: String, mccmnc: String?, _ completion: @escaping (Result<QMIDPreparedSIM, QMIDError>) -> Void) {
        proxy { completion(.failure($0)) }?.prepareSIM(iccid, mccmnc: mccmnc) {
            self.finish($0, $1, "prepareSIM failed", QMIDPreparedSIM.init, completion)
        }
    }

    // The switch failed or was cancelled.
    public func cancelSIM(iccid: String, _ completion: @escaping (Result<Void, QMIDError>) -> Void) {
        proxy { completion(.failure($0)) }?.cancelSIM(iccid) { self.finish($0, completion) }
    }

    // The serving and neighbour cells, read now. raw: also the modem's TLVs (diagnostics).
    public func radio(raw: Bool = false, _ completion: @escaping (Result<QMIDRadio, QMIDError>) -> Void) {
        proxy { completion(.failure($0)) }?.radio(raw) { self.finish($0, $1, "radio failed", QMIDRadio.init, completion) }
    }

    public func setAirplaneMode(_ on: Bool, _ completion: @escaping (Result<Void, QMIDError>) -> Void) {
        proxy { completion(.failure($0)) }?.setAirplaneMode(on) { self.finish($0, completion) }
    }

    public func restartModem(_ completion: @escaping (Result<Void, QMIDError>) -> Void) {
        proxy { completion(.failure($0)) }?.restartModem { self.finish($0, completion) }
    }

    public func bandPreference(_ completion: @escaping (Result<QMIDBandPreference, QMIDError>) -> Void) {
        proxy { completion(.failure($0)) }?.bandPreference {
            self.finish($0, $1, "bandPreference failed", QMIDBandPreference.init, completion)
        }
    }

    // nil lists stay as they are.
    public func setBandPreference(lte: [Int]? = nil, nrNSA: [Int]? = nil, nrSA: [Int]? = nil, persistent: Bool = false,
                                  _ completion: @escaping (Result<Void, QMIDError>) -> Void) {
        var d: [String: Any] = [:]
        d[QMIDKey.lteBands] = lte
        d[QMIDKey.nrNSABands] = nrNSA
        d[QMIDKey.nrSABands] = nrSA
        proxy { completion(.failure($0)) }?.setBandPreference(d as NSDictionary, persistent: persistent) { self.finish($0, completion) }
    }

    public func resetBandPreference(persistent: Bool = false, _ completion: @escaping (Result<Void, QMIDError>) -> Void) {
        proxy { completion(.failure($0)) }?.resetBandPreference(persistent: persistent) { self.finish($0, completion) }
    }

    // ["lte"]: LTE only. Names as QMIDBandPreference.modes / supportedModes.
    public func setModePreference(_ modes: [String], persistent: Bool = false, _ completion: @escaping (Result<Void, QMIDError>) -> Void) {
        proxy { completion(.failure($0)) }?.setModePreference(modes, persistent: persistent) { self.finish($0, completion) }
    }

    public func resetModePreference(persistent: Bool = false, _ completion: @escaping (Result<Void, QMIDError>) -> Void) {
        proxy { completion(.failure($0)) }?.resetModePreference(persistent: persistent) { self.finish($0, completion) }
    }

    public func xtra(_ completion: @escaping (Result<QMIDXTRA, QMIDError>) -> Void) {
        proxy { completion(.failure($0)) }?.xtra { self.finish($0, $1, "xtra failed", QMIDXTRA.init, completion) }
    }

    // `data`: an XTRA file as downloaded from one of QMIDXTRA.servers. Completes with the
    // XTRA state after the load.
    public func loadXTRA(_ data: Data, _ completion: @escaping (Result<QMIDXTRA, QMIDError>) -> Void) {
        proxy { completion(.failure($0)) }?.loadXTRA(data) { self.finish($0, $1, "loadXTRA failed", QMIDXTRA.init, completion) }
    }

    // Before unregistering qmid: removes the Internet Sharing source service it added.
    public func prepareUninstall(_ completion: @escaping (Result<Void, QMIDError>) -> Void) {
        proxy { completion(.failure($0)) }?.prepareUninstall { self.finish($0, completion) }
    }

    // MARK: Blocking calls

    // Makes one call and waits for its completion, at most `timeout` seconds; on timeout a
    // failure with timedOut set (a late reply is dropped). For command-line tools: the client's
    // queue must not be the calling thread's, or the completion could never run.
    //
    //   let r = qmid.sync(timeout: 5) { qmid.status($0) }
    public func sync<T>(timeout: TimeInterval = 10,
                        _ call: (@escaping (Result<T, QMIDError>) -> Void) -> Void) -> Result<T, QMIDError> {
        dispatchPrecondition(condition: .notOnQueue(queue))
        let lock = NSLock()
        let done = DispatchSemaphore(value: 0)
        var out: Result<T, QMIDError>?
        var over = false
        call { r in
            lock.lock()
            if !over && out == nil { out = r }
            lock.unlock()
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        over = true
        if let out { return out }
        var e = QMIDError("qmid did not answer within \(String(format: "%g", timeout)) s")
        e.timedOut = true
        return .failure(e)
    }

    private func finish(_ err: String?, _ completion: @escaping (Result<Void, QMIDError>) -> Void) {
        queue.async { completion(err.map { .failure(QMIDError($0)) } ?? .success(())) }
    }

    // A reply with a value or an error message.
    private func finish<R, T>(_ value: R?, _ err: String?, _ fallback: String, _ make: @escaping (R) -> T,
                              _ completion: @escaping (Result<T, QMIDError>) -> Void) {
        queue.async { completion(value.map { .success(make($0)) } ?? .failure(QMIDError(err ?? fallback))) }
    }
}

// async/await variants.
@available(macOS 10.15, *)
public extension QMIDClient {
    func status() async throws -> QMIDStatus { try await bridge { self.status($0) } }
    func connect(pdn: String) async throws { try await bridge { self.connect(pdn: pdn, $0) } }
    func disconnect(pdn: String) async throws { try await bridge { self.disconnect(pdn: pdn, $0) } }
    func setPolicy(pdn: String, policy: String) async throws { try await bridge { self.setPolicy(pdn: pdn, policy: policy, $0) } }
    func setPolicy(pdn: String, policy: QMIDPolicy) async throws { try await setPolicy(pdn: pdn, policy: policy.rawValue) }
    func reload() async throws { try await bridge { self.reload($0) } }
    func profiles() async throws -> QMIDProfileReport { try await bridge { self.profiles($0) } }
    func restart() async throws { try await bridge { self.restart($0) } }
    func getConfig() async throws -> Data { try await bridge { self.getConfig($0) } }
    func setConfig(_ json: Data) async throws { try await bridge { self.setConfig(json, $0) } }
    func prepareSIM(iccid: String, mccmnc: String?) async throws -> QMIDPreparedSIM { try await bridge { self.prepareSIM(iccid: iccid, mccmnc: mccmnc, $0) } }
    func cancelSIM(iccid: String) async throws { try await bridge { self.cancelSIM(iccid: iccid, $0) } }
    func radio(raw: Bool = false) async throws -> QMIDRadio { try await bridge { self.radio(raw: raw, $0) } }
    func setAirplaneMode(_ on: Bool) async throws { try await bridge { self.setAirplaneMode(on, $0) } }
    func restartModem() async throws { try await bridge { self.restartModem($0) } }
    func bandPreference() async throws -> QMIDBandPreference { try await bridge { self.bandPreference($0) } }
    func setBandPreference(lte: [Int]? = nil, nrNSA: [Int]? = nil, nrSA: [Int]? = nil, persistent: Bool = false) async throws {
        try await bridge { self.setBandPreference(lte: lte, nrNSA: nrNSA, nrSA: nrSA, persistent: persistent, $0) }
    }
    func resetBandPreference(persistent: Bool = false) async throws { try await bridge { self.resetBandPreference(persistent: persistent, $0) } }
    func setModePreference(_ modes: [String], persistent: Bool = false) async throws {
        try await bridge { self.setModePreference(modes, persistent: persistent, $0) }
    }
    func resetModePreference(persistent: Bool = false) async throws { try await bridge { self.resetModePreference(persistent: persistent, $0) } }

    func xtra() async throws -> QMIDXTRA { try await bridge { self.xtra($0) } }
    func loadXTRA(_ data: Data) async throws -> QMIDXTRA { try await bridge { self.loadXTRA(data, $0) } }
    func startLocation(interval: TimeInterval = 1, satellites: Bool = false, nmea: Bool = false) async throws {
        try await bridge { self.startLocation(interval: interval, satellites: satellites, nmea: nmea, $0) }
    }
    func stopLocation() async throws { try await bridge { self.stopLocation($0) } }
    func gnss() async throws -> QMIDGNSS { try await bridge { self.gnss($0) } }
    func prepareUninstall() async throws { try await bridge { self.prepareUninstall($0) } }

    private func bridge<T>(_ call: (@escaping (Result<T, QMIDError>) -> Void) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { cont in call { cont.resume(with: $0) } }
    }
}
