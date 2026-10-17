import Foundation
import QMIDAPI
import IOKit
import IOKit.pwr_mgt
import QMIDatapath
import QMIKit

// The daemon's state machine (PLAN.md §7): device, datapath, and one PDNState per configured
// PDN. Everything runs on `queue`; QMI requests are synchronous and block it briefly. What can
// take long runs elsewhere and reports back on `queue`: opening the device (the firmware may
// need up to 45 s to answer after a reset) and dials (dialQueue). status() answers from its last
// result while `queue` is busy (status(within:reply:)).
//
// Per PDN: idle → dialing → connected → (dropped) → backoff → dialing …
// Device: absent → opening → ready → (unplugged/reset) → absent …
public final class Manager {
    public let queue = DispatchQueue(label: "qmid.manager")
    public var logSink: (QMIDLogLevel, String) -> Void = { print("[\($0.name)] \($1)") }
    // Whether anyone collects debug output (the QMI message trace); checked per message.
    public var debugEnabled: () -> Bool = { false }
    // Called when the device keeps failing to open while it is present; qmid exits so launchd
    // starts a clean process (a leaked IOUSBHost user client only goes away with the process).
    public var restartProcess: (() -> Void)?
    // qmid's build, reported in status (set by qmid from its app bundle).
    public var version: String?
    // Pushed to XPC subscribers (QMIDAPI event dictionaries); called on `queue`.
    public var onEvent: ((NSDictionary) -> Void)?
    private var lastPDNEvent: [String: NSDictionary] = [:]
    private var lastBearersEvent: [String: NSDictionary] = [:]
    private var lastModemEvent: NSDictionary?
    private var openFailures = 0

    private let configPath: String
    private var config: QMIDConfig
    private let publisher: ServicePublisher

    private var device: QMIDevice?
    private var wda: QMIClient?
    private var deviceState = QMIDModemState.absent
    private var deviceError: String?
    private var reopenScheduled = false
    private var fastReopenUntil: Date?       // after arrival/loss: retry every 3 s while the modem boots
    private var lastArrival: Date?

    final class PDNState {
        var config: QMIDConfig.PDN
        let muxID: UInt8
        var policy: QMIDPolicy
        var wanted: Bool                    // autoconnect or explicit connect
        var state = QMIDPDN.State.idle
        var session: PDNSession?
        var utun: Utun?
        var lastError: String?               // in words, for status and clients
        var lastErrorDetail: String?         // with the codes, for the log
        var attempts = 0
        var retry: DispatchWorkItem?
        var connectedAt: Date?
        var dialStarted: UInt64 = 0         // uptime ns; indications received earlier are stale
        var profileIndex: UInt8?            // resolved by syncProfiles; PDNs start by profile only
        var blocked: [UInt8: String] = [:]  // family → permanent cause; cleared on reload / re-registration
        var qos: PDNQoS?                    // while connected: QCI, AMBR, dedicated bearers
        var qosState = PDNQoS.State()       // QCI, AMBR, bearers as last known
        var snapshot = QoSSnapshot()
        var dialing: PDNSession?            // a dial running on dialQueue
        var dialCancelled = false           // torn down meanwhile: its call is stopped when it returns
        var dialAgain = false               // dial once the cancelled one has returned
        var waiters: [(String?) -> Void] = []  // connect calls waiting for the attempt's outcome
        var uptimeLimit: DispatchWorkItem?  // maxUptime
        // After a drop: the utun and service are kept while it redials (linkHold), with the
        // settings they still carry.
        var heldSettings: WDS.RuntimeSettings?
        var linkHold: DispatchWorkItem?
        var reason: QMIDReason?             // lastError as a word for clients
        var ends: [UInt8: WDS.CallEnd] = [:]  // lastError's call end causes, per family

        // Bookkeeping of the QoS snapshot (snapshotQoS); reset with the call.
        struct QoSSnapshot {
            var retry: DispatchWorkItem?
            var running = false
            var touched = Set<UInt32>()     // bearers reported / deleted while it runs
            var deleted = Set<UInt32>()
            var ambrSince = false           // an AMBR indication arrived while it runs
            var done = false                // the first snapshot completed
            var failures = 0                // failed snapshots in a row
        }

        var dialFamilies: [UInt8] { config.families.filter { blocked[$0] == nil } }
        var blockedSummary: String { PDNSession.summary(blocked) }

        func cancelRetry() {
            retry?.cancel()
            retry = nil
        }

        init(config: QMIDConfig.PDN, muxID: UInt8) {
            self.config = config
            self.muxID = muxID
            policy = config.policy.flatMap(QMIDPolicy.init(rawValue:)) ?? .preferWifi
            wanted = config.autoconnects
        }

        var pdnConfig: PDNConfig {
            PDNConfig(name: config.name, profile: profileIndex ?? config.profile.map { UInt8($0) },
                      apn: nil, muxID: muxID, families: dialFamilies)
        }

        // The profile this PDN needs (config is the source of truth). nil fields are left alone.
        var desiredProfile: WDS.Profile {
            var p = WDS.Profile(index: profileIndex ?? 0)
            p.apn = config.apn
            // Profiles always request IPv4v6; "family" only decides which WDS clients qmid starts
            // (an IMS APN may answer IPv6 only; the network picks what it grants).
            p.pdpType = .ipv4v6
            if let a = config.auth { p.authentication = WDS.Authentication(name: a) }
            if let u = config.username { p.username = u }
            if let pw = config.password { p.password = pw }
            if config.username != nil, config.auth == nil { p.authentication = .papOrChap }
            switch config.effectiveRole {
            case "ims":
                p.pcscfUsingPCO = true
                p.imcn = true
                p.apnType = .ims
            case "internet":
                p.apnType = .default
            default:
                break
            }
            if let t = config.apnTypeMask { p.apnType = t }
            p.apnDisabled = false
            return p
        }
    }

    private var pdns: [PDNState] = []
    private var control: QMIClient?          // long-lived WDS client: profile ops + Profile Changed events
    private var syncing = false
    private var lastSyncWrite: UInt64 = 0    // our own writes also raise Profile Changed
    // What the last syncProfiles did, per PDN (profiles(), prepareSIM).
    private struct ProfileSyncEntry {
        var pdn: String
        var action = ""
        var failed = false                  // writing the profile failed
        var profile: UInt8?
        var attach = false                  // it is the LTE attach profile
        var settings: String?

        var dictionary: [String: Any] {
            var d: [String: Any] = ["pdn": pdn, "action": action]
            if let i = profile { d["profile"] = Int(i) }
            if attach { d["attach"] = true }
            if let s = settings { d["settings"] = s }
            return d
        }
    }
    private var profileReport: [ProfileSyncEntry] = []
    private var profileSyncError: String?
    private var profileCheck: DispatchSourceTimer?
    private var linkAnchor: (v4: Bool, v6: Bool) = (false, false)
    private var nas: QMIClient?              // Serving System indications (registration gate)
    private var uimWatch: QMIClient?         // UIM card status indications
    private var dmsWatch: QMIClient?         // DMS operating mode indications
    private var airplane = false             // the radio is off: setAirplaneMode, or someone's AT+CFUN=4
    private var restarting = false           // restartModem: its offline step isn't airplane mode
    private var imei: String?
    private var card: UIM.Card?              // the card in the modem: state, PIN
    private var imsi: String?                // of `sim`; read once its PIN is verified
    private var msisdn: String?
    private var roaming: Bool?
    private var psAttached: Bool?            // nil until known
    private var sim: SIMIdentity?            // nil until read (and while the modem is away)
    // prepareSIM: the card a client is about to switch to. Wins over `sim` when resolving the
    // attach PDN, so the modem's next attach (the new card's first) uses its APN, and no profile
    // sync re-attaches while it is set. In memory only; ends when that card is read, on
    // cancelSIM, when the client's connection goes, or after pendingSIMTimeout.
    private var pendingSIM: SIMIdentity?
    private var pendingOwner: AnyHashable?
    private var pendingPoll: DispatchSourceTimer?
    private let pendingSIMTimeout: TimeInterval = 10
    private var dmsICCIDUnsupported = false  // DMS UIM Get ICCID answered NotSupported: use UIM
    private var attach: WDS.AttachParameters?  // the default bearer as attached (LTE Attach Parameters)
    private var attachFromNetwork = false      // the attach profile's APN is empty: the network chose
    // Home MCC/MNC → the APN the default bearer got there, for "carriers" suggestions.
    private var learned: [String: [String: String]] = [:]
    private var lastSIMEvent: NSDictionary?
    private var serving = ""
    // Registered PLMN and its operator names: the network's (NITZ) or, until it sends them,
    // the modem's own (Get PLMN Name).
    private var plmn: (mcc: UInt16, mnc: UInt16)?
    private var plmnNITZ: NAS.NetworkName?   // the network's (Operator Name Data)
    private var plmnSPN: String?             // the SIM's Service Provider Name
    private var plmnPNN: NAS.NetworkName?    // the SIM's name for the PLMN (EF_OPL/EF_PNN)
    private var plmnModem: NAS.NetworkName?  // the modem's (Get PLMN Name), read once per PLMN
    private var plmnLogged: NAS.NetworkName?
    private var lteEmergency = NAS.LTEEmergency()   // of the registered network
    private var lastPLMNEvent: NSDictionary?
    private var arrivalPort: IONotificationPortRef?
    private var arrivalIterator: io_iterator_t = 0
    private var powerPort: IONotificationPortRef?
    private var powerNotifier: io_object_t = 0
    private var rootPowerPort: io_connect_t = 0
    // PDN name → profile index qmid resolved last time, so a profile someone else edited is
    // taken back (rewritten) instead of being replaced by a new one.
    private var savedProfiles: [String: Int] = [:]
    // The band preference as qmid found it before its first change ("lte", "nsa", "sa"), kept
    // in the state file: resetBandPreference writes it back. nil when qmid changed nothing.
    private var bandsBefore: [String: [Int]]?
    private var statePath: String {
        (configPath as NSString).deletingLastPathComponent + "/state.json"
    }

    func log(_ s: String, level: QMIDLogLevel = .info) { logSink(level, s) }

    public init(configPath: String = QMIDConfig.defaultPath) throws {
        self.configPath = configPath
        config = try QMIDConfig.load(path: configPath)
        publisher = try ServicePublisher(name: "qmid")
        pdns = Self.makeStates(config.resolvedPDNs(for: nil))
        if let d = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            savedProfiles = j["profiles"] as? [String: Int] ?? [:]
            learned = j["learned"] as? [String: [String: String]] ?? [:]
            bandsBefore = j["bandsBefore"] as? [String: [Int]]
        }
    }

    private func saveState() {
        var j: [String: Any] = ["profiles": savedProfiles, "learned": learned]
        j["bandsBefore"] = bandsBefore
        if let d = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: statePath))
        }
    }

    private static func makeStates(_ pdns: [QMIDConfig.PDN]) -> [PDNState] {
        pdns.enumerated().map { PDNState(config: $1, muxID: UInt8(0x81 + $0)) }
    }

    // MARK: - Device

    public func start() {
        queue.async {
            _ = self.status()                       // the answer while `queue` is busy, from the start
            LinkAnchor.down()                       // left over by a crashed qmid
            self.watchArrivals()
            self.watchPower()
            self.openDevice()
        }
    }

    // The device is opened on openQueue: until QMI answers, nothing else needs it, and `queue`
    // stays free for clients and the other PDN work.
    private let openQueue = DispatchQueue(label: "qmid.open")
    private var opening = false
    private var openingDevice: QMIDevice?    // the interface the running open waits on
    private var stopped = false                 // shutdown(): a device opened late is closed

    private func openDevice() {
        reopenScheduled = false
        guard device == nil, !opening, !stopped else { return }
        opening = true
        // Right after an arrival the firmware may still be booting: wait for QMI on the open
        // interface (up to 45 s) rather than cycling close/reopen.
        let booting = fastReopenUntil.map { Date() < $0 } ?? false
        let (interface, vendorIDs, batch) = (config.interface, vendorIDs, config.utunBatch ?? true)
        openQueue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.bringUp(interface: interface, vendorIDs: vendorIDs, booting: booting, batch: batch) }
            self.queue.async { self.opened(result) }
        }
    }

    private struct BroughtUp {
        let device: QMIDevice
        let wda: QMIClient
        let granted: WDA.Granted
    }

    // On openQueue: opens the interface, waits for QMI, sets the data format and starts the
    // datapath. Touches manager state only through `queue`; a device that fails here is closed
    // here.
    private func bringUp(interface: Int?, vendorIDs: [UInt16], booting: Bool, batch: Bool) throws -> BroughtUp {
        let dev = try QMIDevice.open(interface: interface, vendorIDs: vendorIDs)
        queue.async { [weak self] in
            self?.openingDevice = dev
            self?.interfaceFound()
        }
        do {
            // Gone while still opening (waiting for QMI): end that wait now.
            dev.modem.terminationHandler = { [weak self] in
                dev.cancel()
                self?.queue.async { self?.deviceLost(dev) }
            }
            dev.trace = { [weak self] in self?.logSink(.debug, $0) }
            dev.traceEnabled = { [weak self] in self?.debugEnabled() ?? false }
            // Stamp arrival: a disconnect for a call we just stopped can reach `queue` after a new
            // session has been given the same (reused) client ID.
            dev.onIndication = { [weak self] m in
                let t = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                self?.queue.async { self?.indication(m, receivedAt: t) }
            }
            let t0 = Date()
            try dev.sync(within: booting ? 45 : 10)
            if Date().timeIntervalSince(t0) > 3 {
                log(String(format: "QMI answered after %.0f s%@", Date().timeIntervalSince(t0),
                           dev.syncIndicationAt != nil ? " (modem sent its Sync indication)" : ""))
            }
            let wda = try dev.allocateClient(.wda)
            let g = WDA.parseGranted(try wda.request(WDA.setDataFormat,
                                                     WDA.Request(endpointInterface: UInt32(dev.modem.interfaceNumber)).tlvs))
            if let problem = g.datapathProblem {
                wda.release()
                throw QMIHostError.transport("unusable data format: \(problem)")
            }
            dev.modem.batchUtunIO = batch
            dev.modem.batchFallbackHandler = { [weak self] reason in
                self?.log("utun batching off: \(reason); using one system call per packet", level: .notice)
            }
            try dev.modem.startDatapath(withDownlinkSize: UInt(g.downlinkMaxSize ?? 16384),
                                        uplinkSize: UInt(g.uplinkMaxSize ?? 0),
                                        uplinkDatagrams: UInt(g.uplinkMaxDatagrams ?? 0))
            return BroughtUp(device: dev, wda: wda, granted: g)
        } catch {
            // The interface is opened exclusively: a device that failed setup (e.g. Sync timing
            // out while the firmware boots) must be closed, or every retry collides with it.
            dev.close()
            throw error
        }
    }

    // The interface is there: the modem is present, its firmware possibly still booting. Only
    // now "opening", so a modem that is away stays "absent" through the retries.
    private func interfaceFound() {
        guard opening, device == nil else { return }
        deviceState = .opening
        deviceError = nil                       // "not found" from the retries before
        publishModem()
    }

    // Back on `queue` with the opened device, or why it couldn't be opened.
    private func opened(_ result: Result<BroughtUp, Error>) {
        opening = false
        openingDevice = nil
        let up: BroughtUp
        do { up = try result.get() } catch { return openFailed(error) }
        guard !stopped, device == nil else {
            up.wda.release()
            up.device.close()
            return
        }
        let dev = up.device, g = up.granted
        device = dev
        dmsICCIDUnsupported = false             // may be a different modem
        outsideEdits = []
        outsideEditsHalted = false
        wda = up.wda
        deviceState = .ready
        deviceError = nil
        fastReopenUntil = nil
        openFailures = 0
        log(String(format: "modem %04x:%04x ready on interface %d (dl %@x%@, ul %@x%@, utun batching %@)",
                   dev.modem.vendorID, dev.modem.productID, dev.modem.interfaceNumber,
                   g.downlinkMaxDatagrams.map { "\($0)" } ?? "?", g.downlinkMaxSize.map { "\($0)" } ?? "?",
                   g.uplinkMaxDatagrams.map { "\($0)" } ?? "?", g.uplinkMaxSize.map { "\($0)" } ?? "?",
                   dev.modem.batchUtunIO ? "on" : "off by config"), level: .notice)
        publishModem()
        do {
            control = try dev.allocateClient(.wds)
        } catch {
            // No PDN has been dialled yet, so there is nothing else to undo.
            wda = nil
            device = nil
            dev.close()
            return openFailed(error)
        }
        ensureModemAutoconnectOff()
        if let dms = try? dev.allocateClient(.dms) {
            imei = (try? dms.request(DMS.getIDs, timeout: 5)).flatMap(DMS.parseIMEI)
            // A modem left in low power (airplane mode before qmid restarted, or AT+CFUN=4)
            // stays so; only a re-attach's own low power is undone (radioOff, below).
            if !radioOff, let mode = (try? dms.request(DMS.getOperatingMode, timeout: 5)).flatMap(DMS.parseOperatingMode) {
                airplane = DMS.isLowPower(mode)
                if airplane { log("modem radio is off (operating mode \(mode)): airplane mode", level: .notice) }
            }
            dms.release()
        }
        if radioOff {
            // A re-attach was cut short by the reopen: bring the radio back.
            retryRadioOnline(dev) { [weak self] in
                self?.log("radio back online after an interrupted re-attach", level: .notice)
            }
        }
        startRegistrationWatch(dev)
        checkSIM()
        syncProfiles()
        readAttach()
        startProfileCheck()
        for p in pdns where p.wanted { dial(p) }
    }

    private func openFailed(_ error: Error) {
        deviceState = .absent
        deviceError = "\(error)"
        publishModem()
        if case .cancelled = error as? QMIHostError { log("\(error); opening the new one") }
        // No interface is normal while the modem is away; failing to open a present
        // interface over and over is not.
        if (error as? QMIHostError)?.isModemAway != true {
            openFailures += 1
            log("open failed (\(openFailures)): \(error)", level: .error)
            if openFailures >= 5, let restart = restartProcess {
                log("modem present but won't open; restarting qmid", level: .error)
                restart()
            }
        }
        // Right after the modem (re)appears its firmware may not answer yet: retry quickly
        // for a minute, then fall back to a slow poll (arrival notifications reopen at once).
        if let until = fastReopenUntil, Date() < until { scheduleReopen(after: 3) } else { scheduleReopen(after: 30) }
    }

    private var reopenGeneration = 0

    private func scheduleReopen(after seconds: Double) {
        guard !reopenScheduled else { return }
        reopenScheduled = true
        reopenGeneration += 1
        let gen = reopenGeneration
        queue.asyncAfter(deadline: .now() + seconds) {
            guard gen == self.reopenGeneration else { return }   // superseded by an earlier reopen
            self.openDevice()
        }
    }

    // Unplug or modem reset: the utuns and services go, calls are gone with the modem.
    private func deviceLost(_ which: QMIDevice? = nil) {
        guard let dev = device, which == nil || which === dev else { return }
        log("modem went away", level: .notice)
        for p in pdns {
            p.cancelRetry()
            if p.config.oneShot { p.wanted = false }
            teardown(p, stopCall: false, state: .idle, error: "modem went away", reason: .modemLost)
        }
        wda = nil
        control = nil
        nas = nil
        uimWatch = nil
        dmsWatch = nil
        airplane = false                            // read again when it comes back
        restarting = false
        imei = nil
        card = nil
        imsi = nil
        msisdn = nil
        roaming = nil
        psAttached = nil
        plmn = nil
        resetPLMNNames()
        sim = nil                                   // may be a different SIM when it comes back
        endPendingSIM()
        attach = nil
        applySIM()
        profileCheck?.cancel()
        profileCheck = nil
        dev.close()
        device = nil
        deviceState = .absent
        publishModem()
        fastReopenUntil = Date().addingTimeInterval(90)   // a reset re-enumerates in ~35 s
        scheduleReopen(after: 3)
    }

    // MARK: - PDNs

    // Dials run on dialQueue (Start Network Interface can take up to 60 s per family), so one
    // PDN's dial never waits for another's; the outcome is applied on `queue` (dialed).
    private let dialQueue = DispatchQueue(label: "qmid.dial", attributes: .concurrent)
    // Muxes with a dial running, or a cancelled one still stopping its call: a new dial on the
    // mux waits for it (dialAgain).
    private var muxBusy = Set<UInt8>()
    // Packet Service indications that matched no session while a dial ran: they may be for the
    // call it brings up, so they are replayed when it returns.
    private var heldIndications: [(QMIMessage, UInt64)] = []

    private func dial(_ p: PDNState) {
        guard p.session == nil else { return settle(p) }
        if p.dialing != nil || muxBusy.contains(p.muxID) {
            // Already dialing; or a cancelled dial still stopping its call: dial after it.
            if p.dialing == nil || p.dialCancelled { p.dialAgain = true }
            return
        }
        guard let dev = device else { return settle(p) }
        guard !p.dialFamilies.isEmpty else {
            p.state = .blocked
            p.lastError = p.blockedSummary
            publishStatus(p)
            return settle(p)
        }
        // Dialled again when airplane mode ends (and the modem attaches), or when the Serving
        // System indication reports PS attach.
        guard !airplane else { return wait(p, error: "airplane mode", reason: .airplaneMode) }
        guard psAttached != false else { return wait(p, error: "not attached (\(serving))", reason: .notAttached) }
        guard p.profileIndex != nil else {
            let error = "no modem profile for \(p.config.apn ?? p.config.name)"
            if p.config.oneShot { return stopOneShot(p, error: error, reason: .noProfile) }
            p.state = .backoff
            p.lastError = p.lastError ?? error
            p.reason = p.reason ?? .noProfile
            publishStatus(p)
            scheduleRedial(p)
            return settle(p)
        }
        p.cancelRetry()
        p.state = .dialing
        p.lastError = nil
        p.lastErrorDetail = nil
        p.reason = nil
        p.ends = [:]
        p.dialStarted = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        publishStatus(p)
        let session = PDNSession(device: dev, config: p.pdnConfig, dataInterface: dev.modem.interfaceNumber)
        p.dialing = session
        muxBusy.insert(p.muxID)
        dialQueue.async { [weak self] in
            var failure: Error?
            do { try session.connect() } catch { failure = error }
            self?.queue.async { self?.dialed(p, session, dev, failure) }
        }
    }

    // Nothing to dial into yet: the PDN waits (a one-shot PDN stops instead).
    private func wait(_ p: PDNState, error: String, reason: QMIDReason) {
        p.cancelRetry()
        if p.config.oneShot { return stopOneShot(p, error: error, reason: reason) }
        p.state = .waiting
        p.lastError = error
        p.reason = reason
        p.ends = [:]
        publishStatus(p)
        settle(p)
    }

    // A dial returned (on `queue`).
    private func dialed(_ p: PDNState, _ session: PDNSession, _ dev: QMIDevice, _ failure: Error?) {
        defer { replayHeldIndications() }
        guard !p.dialCancelled, device === dev else {
            // Torn down while dialing (disconnect, reload, modem lost): stop what came up, off
            // the queue, and keep the mux busy until then.
            dialQueue.async { [weak self] in
                session.disconnect()
                self?.queue.async {
                    p.dialing = nil
                    p.dialCancelled = false
                    self?.muxFreed(p.muxID)
                }
            }
            return
        }
        p.dialing = nil
        muxBusy.remove(p.muxID)
        do {
            if let failure { throw failure }
            let kept = p.utun != nil
            let utun = try p.utun ?? Utun()
            p.session = session
            p.utun = utun
            try utun.configure(session.merged)
            dev.modem.attachMux(p.muxID, fd: utun.fd)
            p.state = .connected
            p.lastError = session.failures.isEmpty ? nil : session.failureSummary
            p.ends = session.ends
            p.attempts = 0
            p.connectedAt = Date()
            p.linkHold?.cancel()
            p.linkHold = nil
            p.heldSettings = nil
            try publishService(p)
            log("\(p.config.name): \(kept ? "reconnected" : "connected") on \(utun.name) (\(p.policy.rawValue)) " +
                [session.merged.ipv4Address?.description, session.merged.ipv6Address?.description]
                .compactMap { $0 }.joined(separator: " "), level: .notice)
            if !p.config.oneShot { applyPermanentCauses(p, session) }
            armUptimeLimit(p)
            startQoS(p, dev)
        } catch {
            session.disconnect()
            let summary = session.failures.isEmpty ? "\(error)" : session.failureSummary
            let reason: QMIDReason = session.ends.isEmpty ? .failed : .rejected
            if p.config.oneShot {
                return stopOneShot(p, error: summary, reason: reason, ends: session.ends,
                                   detail: session.failures.isEmpty ? nil : session.failureDetail)
            }
            teardown(p, stopCall: true, state: .backoff, error: summary, reason: reason, ends: session.ends)
            p.lastErrorDetail = session.failures.isEmpty ? nil : session.failureDetail
            let loggedBlock = applyPermanentCauses(p, session)
            if p.dialFamilies.isEmpty {
                p.state = .blocked
                p.lastError = p.blockedSummary
                if !loggedBlock {
                    log("\(p.config.name): refused for every family; not retrying until the SIM, the registration or the config changes",
                        level: .error)
                }
                publishStatus(p)
            } else {
                if session.ends.values.contains(where: \.isThrottled) { logThrottle(p) }
                scheduleRedial(p)
            }
        }
        settle(p)
    }

    // A cancelled dial's call is stopped: a dial asked for meanwhile (connect, or a reloaded
    // PDN on the same mux) runs now.
    private func muxFreed(_ mux: UInt8) {
        muxBusy.remove(mux)
        for q in pdns where q.muxID == mux && q.dialAgain {
            q.dialAgain = false
            if q.wanted { dial(q) } else { settle(q) }
        }
        replayHeldIndications()
    }

    private func replayHeldIndications() {
        let held = heldIndications
        heldIndications = []
        for (m, t) in held { indication(m, receivedAt: t) }
    }

    // Answers the connect calls waiting on this PDN with how its attempt ended.
    private func settle(_ p: PDNState) {
        guard !p.waiters.isEmpty else { return }
        let result = p.state == .connected ? nil : p.lastError ?? (p.state == .idle ? "disconnected" : p.state.rawValue)
        let waiters = p.waiters
        p.waiters = []
        waiters.forEach { $0(result) }
    }

    // A call that went down without a disconnect: redial (now, or after backoff); a one-shot
    // PDN (redial: false) stays down until the next connect.
    //
    // A call that had been up a while (networks end sessions on a timer, e.g. every 2 h) is
    // redialed at once with its utun, service and stand-in interface kept, so the system sees a
    // short stall instead of the interface going away. Not back within linkHoldSeconds: they go.
    private func dropped(_ p: PDNState, stopCall: Bool, error: String, detail: String? = nil,
                         ends: [UInt8: WDS.CallEnd] = [:], now: Bool = false) {
        if p.config.oneShot {
            return stopOneShot(p, error: error, reason: .dropped, ends: ends, stopCall: stopCall, detail: detail)
        }
        let keep = Self.holdsLink(wanted: p.wanted, hasLink: p.utun != nil, state: p.state,
                                  upFor: p.connectedAt.map { -$0.timeIntervalSinceNow })
        let interface = p.utun?.name ?? ""
        teardown(p, stopCall: stopCall, state: .backoff, error: error, reason: .dropped, ends: ends, keepLink: keep)
        p.lastErrorDetail = detail
        if keep {
            log("\(p.config.name): \(detail ?? error); redialing now, keeping \(interface) for up to \(Int(Self.linkHoldSeconds)) s",
                level: .notice)
            armLinkHold(p)
        }
        guard now || keep else { return scheduleRedial(p) }
        p.attempts = 0
        if p.wanted { dial(p) } else { p.state = .idle; publishStatus(p) }
    }

    // A call up this long has earned an immediate redial; one dropping sooner goes through
    // backoff, so a network ending every call at once isn't redialed in a loop.
    static let linkHoldMinUptime: TimeInterval = 60
    static let linkHoldSeconds: TimeInterval = 10

    static func holdsLink(wanted: Bool, hasLink: Bool, state: QMIDPDN.State, upFor: TimeInterval?) -> Bool {
        wanted && hasLink && state == .connected && (upFor ?? 0) >= linkHoldMinUptime
    }

    private func armLinkHold(_ p: PDNState) {
        p.linkHold?.cancel()
        let item = DispatchWorkItem { [weak self, weak p] in
            guard let self, let p, p.session == nil, let utun = p.utun else { return }
            self.log("\(p.config.name): not back within \(Int(Self.linkHoldSeconds)) s; removing \(utun.name)", level: .notice)
            self.releaseLink(p)
            self.publishStatus(p)
        }
        p.linkHold = item
        queue.asyncAfter(deadline: .now() + Self.linkHoldSeconds, execute: item)
    }

    // The utun and service of a PDN without a call (kept by dropped(), or torn down now).
    private func releaseLink(_ p: PDNState) {
        p.linkHold?.cancel()
        p.linkHold = nil
        p.heldSettings = nil
        publisher.remove(prefix: ServicePublisher.serviceKey(ServicePublisher.serviceID(for: p.config.name)))
        p.utun?.close()
        p.utun = nil
    }

    // A one-shot PDN that went down or couldn't be dialled: idle and not wanted.
    private func stopOneShot(_ p: PDNState, error: String, reason: QMIDReason, ends: [UInt8: WDS.CallEnd] = [:],
                             stopCall: Bool = true, detail: String? = nil) {
        p.wanted = false
        p.cancelRetry()
        teardown(p, stopCall: stopCall, state: .idle, error: error, reason: reason, ends: ends)
        log("\(p.config.name): \(detail ?? error); down until the next connect (redial false)",
            level: reason == .maxUptime ? .notice : .error)
        settle(p)
    }

    // maxUptime: hang up after that long; connect on the connected PDN starts it again.
    private func armUptimeLimit(_ p: PDNState) {
        p.uptimeLimit?.cancel()
        p.uptimeLimit = nil
        guard let limit = p.config.maxUptime else { return }
        let item = DispatchWorkItem { [weak self, weak p] in
            guard let self, let p, p.state == .connected else { return }
            self.stopOneShot(p, error: "max uptime reached (\(limit) s)", reason: .maxUptime)
        }
        p.uptimeLimit = item
        queue.asyncAfter(deadline: .now() + .seconds(limit), execute: item)
    }

    // PROBE: the modem's throttle state for a PDN whose calls came back throttled, raw, to learn
    // the layout of 0x006C / 0x00D0 while a throttle is active.
    private func logThrottle(_ p: PDNState) {
        guard let wds = control else { return }
        func dump(_ name: String, _ message: UInt16, _ tlvs: [TLV]) {
            do {
                let r = try wds.request(message, tlvs, timeout: 5)
                let body = r.tlvs.filter { $0.type != 0x02 }.map { String(format: "0x%02x[%d] ", $0.type, $0.value.count) + $0.value.hex }
                log("\(p.config.name): probe \(name): " + (body.isEmpty ? "(no TLVs)" : body.joined(separator: " | ")), level: .notice)
            } catch {
                log("\(p.config.name): probe \(name): \(error)", level: .notice)
            }
        }
        dump("PDN throttle info (3GPP)", WDS.getPDNThrottleInfo, [.u8(0x01, 0)])
        dump("PDN throttle info (3GPP2)", WDS.getPDNThrottleInfo, [.u8(0x01, 1)])
        dump("throttled PDN reject timer", WDS.getThrottledPDNRejectTimer, [])
    }

    // A family refused with a permanent cause is not retried until the SIM, the registration or
    // the config changes (or a connect). True when it blocked (and logged) the whole PDN.
    @discardableResult
    private func applyPermanentCauses(_ p: PDNState, _ session: PDNSession) -> Bool {
        // A rejection of the APN itself (not subscribed, unknown, ...) holds for every family:
        // don't go on dialing the others, which the modem then only throttles.
        if let end = session.ends.values.first(where: \.isAPNLevel),
           p.config.families.contains(where: { p.blocked[$0] == nil }) {
            for f in p.config.families { p.blocked[f] = end.text }
            log("\(p.config.name): \(end); not retrying until the SIM, the registration or the config changes",
                level: .error)
            return true
        }
        // Every family failed and the network refused the request itself (#30, #31): the
        // family the modem ended with an internal cause shared that request.
        if p.config.families.allSatisfy({ session.ends[$0] != nil }),
           let end = session.ends.values.first(where: \.isRequestLevel),
           p.config.families.contains(where: { p.blocked[$0] == nil }) {
            for f in p.config.families { p.blocked[f] = end.text }
            log("\(p.config.name): \(end) for every family; not retrying until the SIM, the registration or the config changes",
                level: .error)
            return true
        }
        for (family, end) in session.ends where end.isPermanent && p.blocked[family] == nil {
            p.blocked[family] = end.text
            log("\(p.config.name): ipv\(family) blocked: \(end)", level: .error)
        }
        return false
    }

    private func teardown(_ p: PDNState, stopCall: Bool, state: QMIDPDN.State, error: String?,
                          reason: QMIDReason? = nil, ends: [UInt8: WDS.CallEnd] = [:], keepLink: Bool = false) {
        let cancelsDial = p.dialing != nil && !p.dialCancelled
        if p.dialing != nil {
            p.dialCancelled = true                  // dialed() stops its call
            p.dialAgain = false
        }
        p.uptimeLimit?.cancel()
        p.uptimeLimit = nil
        if let dev = device, p.utun != nil { dev.modem.detachMux(p.muxID) }
        if keepLink {
            p.heldSettings = p.session?.merged ?? p.heldSettings
        } else {
            releaseLink(p)
        }
        p.snapshot.retry?.cancel()
        p.snapshot = .init()
        p.qosState = PDNQoS.State()
        p.qos?.close(release: stopCall)
        p.qos = nil
        if stopCall { p.session?.disconnect() }
        p.session = nil
        p.connectedAt = nil
        p.state = state
        p.lastError = error
        p.lastErrorDetail = nil
        p.reason = reason
        p.ends = ends
        publishStatus(p)
        emitBearers(p)
        if cancelsDial { settle(p) }
    }

    // 2 s, 4 s, 8 s … capped at 5 min (PLAN.md §7). Permanent causes block instead
    // (applyPermanentCauses).
    private func scheduleRedial(_ p: PDNState) {
        guard p.wanted else { p.state = .idle; publishStatus(p); return }
        p.attempts += 1
        let delay = min(300, pow(2, Double(min(p.attempts, 9))))
        log("\(p.config.name): \(p.lastErrorDetail ?? p.lastError ?? "down"); retry in \(Int(delay)) s", level: .notice)
        let item = DispatchWorkItem { [weak self, weak p] in
            guard let self, let p, p.wanted, self.device != nil else { return }
            self.dial(p)
        }
        p.retry = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func indication(_ m: QMIMessage, receivedAt: UInt64) {
        if m.service == .ctl, m.messageID == CTL.sync {
            // The modem announces a (re)started QMI stack; under an open device that means the
            // client IDs qmid holds may be gone, and with them the registration indications.
            if device != nil, !clientsAlive() {
                log("modem restarted its QMI stack (Sync indication); reopening it", level: .error)
                reopenNow()
            }
            return
        }
        if m.service == .nas, m.messageID == NAS.getServingSystem, let s = try? NAS.parseServingSystem(m) {
            // Queued behind a sync that started a re-attach: still the old attach, and taking it
            // would dial into a radio going to low power.
            guard receivedAt >= reattachStarted else {
                log("ignoring serving system received before the re-attach (\(s.registrationName), ps \(s.psAttached ? "attached" : "detached"))")
                return
            }
            servingChanged(s)
            return
        }
        if m.service == .nas, m.messageID == NAS.operatorNameDataIndication {
            if let n = NAS.parseNITZName(m), plmn != nil { setNITZName(n) } else { readPLMNName() }
            return
        }
        if m.service == .nas, m.messageID == NAS.sysInfoIndication {
            if plmn != nil { setLTEEmergency(NAS.parseLTEEmergency(m), replace: false) }
            return
        }
        if m.service == .dms, m.messageID == DMS.eventReportIndication, let mode = DMS.parseOperatingMode(m) {
            operatingModeChanged(mode)
            return
        }
        if m.service == .uim, m.messageID == UIM.statusChangeIndication {
            if let c = (try? UIM.parseCardStatus(m)).flatMap(Self.mainCard) { cardChanged(c) }
            return
        }
        if m.service == .nas, m.messageID == NAS.networkTimeIndication {
            readPLMNName()                          // EMM Information: names may have come with it
            return
        }
        if m.service == .wds, m.messageID == WDS.profileChanged, let ev = WDS.parseProfileChanged(m) {
            profileChanged(index: ev.index, event: ev.event, receivedAt: receivedAt)
            return
        }
        if m.service == .qos {
            if m.messageID == QoS.eventReport,
               let p = pdns.first(where: { $0.qos != nil && $0.qos?.indicationClientID == m.clientID }) {
                applyQoSReport(p, m)
            }
            return
        }
        if m.service == .wds, m.messageID == WDS.ambrIndication {
            if let p = pdns.first(where: { $0.session?.clientIDs.contains(m.clientID) == true }), p.qos != nil,
               let a = WDS.parseAMBR(m), a != p.qosState.ambr {
                p.qosState.ambr = a
                if p.snapshot.running { p.snapshot.ambrSince = true }   // newer than the snapshot's read
                log("\(p.config.name): AMBR now \(Self.describe(a))")
                publishStatus(p)
            }
            return
        }
        guard m.service == .wds, m.messageID == WDS.getPacketServiceStatus,
              let s = WDS.parsePacketServiceStatus(m) else { return }
        guard let p = pdns.first(where: { $0.session?.clientIDs.contains(m.clientID) == true }) else {
            if !muxBusy.isEmpty, heldIndications.count < 64 { heldIndications.append((m, receivedAt)) }
            return
        }
        guard receivedAt >= p.dialStarted else {
            log("\(p.config.name): ignoring stale packet service \(s.connectionName) for reused client \(m.clientID)")
            return
        }
        log("\(p.config.name): packet service \(s.connectionName)\(s.connection == 1 ? ", \(s.callEnd)" : "")\(s.reconfigurationRequired ? " (reconfiguration required)" : "")")
        if s.connection == 1, p.state == .connected {
            let family = [UInt8(4), 6].first { p.session?.client(family: $0)?.id == m.clientID }
            dropped(p, stopCall: true, error: "dropped: \(s.callEnd.text)", detail: "dropped: \(s.callEnd)",
                    ends: family.map { [$0: s.callEnd] } ?? [:])
        } else if s.connection == 2, s.reconfigurationRequired, p.state == .connected {
            refreshSettings(p)
        }
    }

    // New addresses / DNS / P-CSCF on a live call: update the utun and service in place.
    private func refreshSettings(_ p: PDNState) {
        guard let session = p.session, let utun = p.utun else { return }
        do {
            try session.refresh()
            try utun.configure(session.merged)
            try publishService(p)
            log("\(p.config.name): runtime settings refreshed")
            snapshotQoS(p)
        } catch {
            dropped(p, stopCall: true, error: "refresh failed: \(error)")
        }
    }

    // MARK: - Registration gate (NAS)

    private func startRegistrationWatch(_ dev: QMIDevice) {
        do {
            let n = try dev.allocateClient(.nas)
            nas = n
            try n.request(NAS.registerIndications, [NAS.servingSystemEvents])
            for t in [NAS.networkTimeEvents, NAS.operatorNameEvents, NAS.sysInfoEvents] {
                _ = try? n.request(NAS.registerIndications, [t])
            }
            if let s = try? NAS.parseServingSystem(try n.request(NAS.getServingSystem)) { servingChanged(s, initial: true) }
        } catch {
            log("NAS serving-system events unavailable (\(error)); dialing without a registration gate")
            psAttached = nil
        }
        watchEvents(dev, "DMS operating mode", fallback: "airplane mode seen only when set through qmid",
                    { try Self.registered(dev, .dms, DMS.setEventReport, [DMS.operatingModeEvents]) },
                    { [weak self] in self?.dmsWatch = $0 })
        watchEvents(dev, "UIM card status", fallback: "card state read with the SIM only",
                    { try Self.registered(dev, .uim, UIM.registerEvents, [UIM.cardStatusEvents]) },
                    { [weak self] in self?.uimWatch = $0 })
    }

    // An event registration; a modem still settling after a reset may not answer it in time,
    // so it is tried 4 times, 10 s apart, while the same modem stays open.
    private func watchEvents(_ dev: QMIDevice, _ what: String, fallback: String, attempt: Int = 1,
                             _ open: @escaping () throws -> QMIClient, _ keep: @escaping (QMIClient) -> Void) {
        guard device === dev else { return }
        do {
            keep(try open())
            if attempt > 1 { log("\(what) events registered (attempt \(attempt))") }
        } catch {
            guard attempt < 4 else { return log("\(what) events unavailable (\(error)); \(fallback)") }
            log("\(what) events: \(error); retrying in 10 s")
            queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.watchEvents(dev, what, fallback: fallback, attempt: attempt + 1, open, keep)
            }
        }
    }

    // A client of `service` with `message` sent (an event registration); released if that fails.
    static func registered(_ dev: QMIDevice, _ service: QMIService, _ message: UInt16, _ tlvs: [TLV]) throws -> QMIClient {
        let c = try dev.allocateClient(service)
        do {
            try c.request(message, tlvs, timeout: 5)
            return c
        } catch {
            c.release()
            throw error
        }
    }

    private func servingChanged(_ s: NAS.ServingSystem, initial: Bool = false) {
        let rats = s.radioInterfaces.map(NAS.ServingSystem.radioName).joined(separator: "+")
        serving = "\(s.registrationName), ps \(s.psAttached ? "attached" : "detached")\(rats.isEmpty ? "" : ", \(rats)")"
        // Indications may leave out the current PLMN (TLV 0x12) when it hasn't changed.
        let current = s.registration != 1 ? nil : s.mcc.flatMap { mcc in s.mnc.map { (mcc: mcc, mnc: $0) } } ?? plmn
        let plmnChanged = current?.mcc != plmn?.mcc || current?.mnc != plmn?.mnc
        if plmnChanged {
            plmn = current
            resetPLMNNames()
            readPLMNName()
        }
        // Indications may leave out the roaming indicator when it hasn't changed.
        let roam = s.registration != 1 ? nil : s.roaming ?? roaming
        let roamingChanged = roam != roaming
        roaming = roam
        let was = psAttached
        psAttached = s.registration == 1 && s.psAttached
        // EMC BS comes with the attach: read it on attach and on a new network.
        if psAttached == true, plmnChanged || was != true || initial,
           let n = nas, let r = try? n.request(NAS.getSysInfo, timeout: 5) {
            setLTEEmergency(NAS.parseLTEEmergency(r), replace: true)
        }
        guard was != psAttached || initial else {
            if roamingChanged { publishModem() }
            return
        }
        log("network: \(serving)", level: .notice)
        publishModem()
        guard psAttached == true, !initial else { return }
        // (Re-)attached: a new SIM or carrier config may have changed profiles, and a family
        // blocked on the old registration may be allowed now.
        for p in pdns { p.blocked.removeAll() }
        checkSIM()
        syncProfiles()
        readAttach()
        redialWanted()
    }

    // Dials every PDN that should be up and has no call, without backoff.
    private func redialWanted() {
        for p in pdns where p.wanted && p.session == nil {
            p.attempts = 0
            dial(p)
        }
    }

    // MARK: - Operator name (registered PLMN)

    // Each name (long, short) from the first source that has it: the network's (NITZ), the
    // SIM's Service Provider Name (home network only; one name for both), the SIM's name for
    // the PLMN (EF_OPL/EF_PNN), the modem's (Get PLMN Name). The first three come from Get
    // Operator Name Data. The network's names stay until the PLMN changes, also when a later
    // read no longer has them.
    private func readPLMNName() {
        guard let p = plmn, let n = nas else { return namesChanged() }
        if let r = try? n.request(NAS.getOperatorNameData, timeout: 5) {
            if let nitz = NAS.parseNITZName(r) { plmnNITZ = nitz }
            plmnSPN = NAS.parseSPN(r)
            plmnPNN = NAS.parseSIMPLMNName(r, mccmnc: mccmnc(p), home: isHome(p))
        }
        readModemName()
        namesChanged()
    }

    // What is known of the registered network, read again for a new one.
    private func resetPLMNNames() {
        lteEmergency = NAS.LTEEmergency()
        plmnNITZ = nil
        plmnSPN = nil
        plmnPNN = nil
        plmnModem = nil
    }

    private func setNITZName(_ n: NAS.NetworkName) {
        plmnNITZ = n
        namesChanged()
    }

    private func isHome(_ p: (mcc: UInt16, mnc: UInt16)) -> Bool {
        guard let h = sim?.mccmnc, h.count >= 5 else { return false }
        return Int(h.prefix(3)) == Int(p.mcc) && Int(h.dropFirst(3)) == Int(p.mnc)
    }

    // The SIM's spelling on its home network (3-digit MNCs below 100), else 2 digits below 100.
    private func mccmnc(_ p: (mcc: UInt16, mnc: UInt16)) -> String {
        if isHome(p), let h = sim?.mccmnc { return h }
        return Self.mccmncString(p)
    }

    // 3-digit MNCs below 100 can't be told from 2-digit ones here: written with 2 digits.
    static func mccmncString(_ p: (mcc: UInt16, mnc: UInt16)) -> String {
        String(format: "%03d", p.mcc) + String(format: p.mnc > 99 ? "%03d" : "%02d", p.mnc)
    }

    private var shownName: NAS.NetworkName {
        let spn = plmn.map(isHome) == true ? plmnSPN : nil
        return NAS.NetworkName(longName: plmnNITZ?.longName ?? spn ?? plmnPNN?.longName ?? plmnModem?.longName,
                               shortName: plmnNITZ?.shortName ?? spn ?? plmnPNN?.shortName ?? plmnModem?.shortName)
    }

    private func namesChanged() {
        logPLMNName()
        publishModem()
    }

    private func logPLMNName() {
        let n = shownName
        guard plmn != nil, n != plmnLogged else { return }
        plmnLogged = n
        log("operator: \(n.longName ?? "-") / \(n.shortName ?? "-")\(plmnNITZ == nil ? "" : " (network)")", level: .notice)
    }

    // Only needed for a name no other source has.
    private func readModemName() {
        let n = shownName
        guard plmnModem == nil, n.longName == nil || n.shortName == nil, let p = plmn, let c = nas else { return }
        plmnModem = (try? c.request(NAS.getPLMNName, NAS.plmnNameRequest(mcc: p.mcc, mnc: p.mnc), timeout: 5))
            .flatMap { try? NAS.parsePLMNName($0) } ?? NAS.NetworkName()
    }

    // The emergency fields of Sys Info. An indication may leave out what didn't change
    // (replace: false keeps those); Get Sys Info answers for all of them.
    private func setLTEEmergency(_ e: NAS.LTEEmergency, replace: Bool) {
        var next = replace ? e : lteEmergency
        if !replace {
            if let b = e.bearers { next.bearers = b }
            if let b = e.accessBarred { next.accessBarred = b }
        }
        guard next != lteEmergency else { return }
        lteEmergency = next
        func word(_ b: Bool?) -> String { b.map { $0 ? "yes" : "no" } ?? "unknown" }
        log("network: emergency bearers \(word(next.bearers)), emergency access barred \(word(next.accessBarred))")
        publishModem()
    }

    private func plmnInfo() -> QMIDPLMN? {
        guard let p = plmn else { return nil }
        let n = shownName
        var d = QMIDPLMN(mccmnc: Self.mccmncString(p), longName: n.longName, shortName: n.shortName,
                         nameFromNetwork: plmnNITZ != nil)
        d.emergencyBearers = lteEmergency.bearers
        d.emergencyAccessBarred = lteEmergency.accessBarred
        d.roaming = roaming
        return d
    }

    private func plmnEvent() -> NSDictionary {
        var d: [String: Any] = [QMIDKey.type: QMIDEventType.plmn]
        d[QMIDKey.plmn] = plmnInfo()?.dictionary
        return d as NSDictionary
    }

    // MARK: - SIM (per-SIM attach APN, config "carriers")

    // Reads the SIM's home MCC/MNC and ICCID. A different SIM re-resolves the attach PDN for
    // the next profile sync. Keeps the last identity when the SIM can't be read.
    // Returns whether the identity changed (the attach PDN may resolve differently).
    @discardableResult
    private func checkSIM() -> Bool {
        guard let dev = device else { return false }
        readCard()
        var id = SIMIdentity()
        if !dmsICCIDUnsupported, let dms = try? dev.allocateClient(.dms) {
            do {
                id.iccid = DMS.parseICCID(try dms.request(DMS.uimGetICCID, timeout: 5))
            } catch QMIHostError.protocolError(let e, _) where e == .notSupported {
                dmsICCIDUnsupported = true          // this firmware: UIM only
            } catch {}
            dms.release()
        }
        if id.iccid == nil, let uim = try? dev.allocateClient(.uim) {
            id.iccid = (try? uim.request(UIM.readTransparent, UIM.readICCIDRequest, timeout: 5)).flatMap(UIM.parseICCID)
            uim.release()
        }
        if let n = nas ?? (try? dev.allocateClient(.nas)) {
            id.mccmnc = (try? n.request(NAS.getHomeNetwork, timeout: 5)).flatMap { try? NAS.parseHomeNetwork($0) }?.mccmnc
            if n !== nas { n.release() }
        }
        guard id.iccid != nil || id.mccmnc != nil else { return false }
        if let p = pendingSIM, let arrived = id.arrival(of: p) {
            id = arrived
            endPendingSIM()
            log("prepared SIM \(p.iccidSuffix ?? "") is in", level: .notice)
        }
        id = id.merged(over: sim)
        guard id != sim else {
            // Same card: its IMSI may have become readable (PIN entered).
            if imsi == nil {
                readSIMDetails()
                if imsi != nil { publishModem() }
            }
            return false
        }
        // Only a different card earns its own re-attach; the same card gaining its MCC/MNC
        // stays under the re-attach rate limit.
        if id.iccid != sim?.iccid {
            imsi = nil
            msisdn = nil
            lastReattach = nil
            for p in pdns { p.blocked.removeAll() }   // rejections were the old SIM's
        }
        sim = id
        readSIMDetails()
        attach = nil
        attachFromNetwork = false
        let match = config.carrier(for: id)
        let how = config.carriers == nil ? ""
            : match.map { ", carrier \($0.carrier.name) by \($0.matchedBy)" }
            ?? (config.identifies(id) ? ", no carrier match" : ", home network not readable yet; attach profile left as is")
        log("SIM \(id.description)\(how)", level: .notice)
        applySIM()
        readPLMNName()                              // SIM names apply on the home network; publishes
        return true
    }

    // The card a status reports for: the first present one, else the first.
    static func mainCard(_ cards: [UIM.Card]) -> UIM.Card? { cards.first { $0.state == 1 } ?? cards.first }

    private func readCard() {
        guard let dev = device, let uim = uimWatch ?? (try? dev.allocateClient(.uim)) else { return }
        if let c = (try? uim.request(UIM.getCardStatus, timeout: 5)).flatMap({ try? UIM.parseCardStatus($0) }).flatMap(Self.mainCard) {
            card = c
        }
        if uim !== uimWatch { uim.release() }
    }

    // A card status indication: a card in or out, a PIN entered or blocked.
    private func cardChanged(_ c: UIM.Card) {
        guard c != card else { return }
        card = c
        log("SIM card \(c.stateName)\(c.pin.map { ", pin \(Self.pinState($0.state).rawValue)" } ?? "")", level: .notice)
        if c.state != 1 { imsi = nil; msisdn = nil }
        if checkSIM() { reconcile("follow the SIM") } else { publishModem() }
    }

    // IMSI and MSISDN of the card in the modem: once per card, after its PIN is verified.
    private func readSIMDetails() {
        guard let dev = device, sim != nil, card?.isReady != false, imsi == nil else { return }
        if let uim = uimWatch ?? (try? dev.allocateClient(.uim)) {
            imsi = (try? uim.request(UIM.readTransparent, UIM.readIMSIRequest, timeout: 5)).flatMap(UIM.parseIMSI)
            msisdn = (try? uim.request(UIM.readRecord, UIM.readMSISDNRequest, timeout: 5)).flatMap(UIM.parseMSISDN)
            if uim !== uimWatch { uim.release() }
        }
        if msisdn == nil, let dms = try? dev.allocateClient(.dms) {
            msisdn = (try? dms.request(DMS.getMSISDN, timeout: 5)).flatMap(DMS.parseMSISDN)
            dms.release()
        }
    }

    static func pinState(_ s: UInt8) -> QMIDSIM.PINState {
        switch s {
        case 0, 3: return .disabled
        case 1: return .required
        case 2: return .verified
        case 4: return .pukRequired
        case 5: return .blocked
        default: return .unknown
        }
    }

    // Puts the SIM's attach PDN settings into the PDN states (see QMIDConfig.resolvedPDNs): the
    // prepared card's while one is pending, else the one in the modem.
    private func applySIM() {
        let resolved = config.resolvedPDNs(for: pendingSIM ?? sim, prepared: pendingSIM != nil)
        for p in pdns {
            if let q = resolved.first(where: { $0.name == p.config.name }), q != p.config { p.config = q }
        }
    }

    // The default bearer as attached: its APN is the network's choice when the attach profile's
    // APN is empty. Remembered per home MCC/MNC as a suggestion for "carriers".
    private func readAttach() {
        guard psAttached == true, let wds = control,
              let r = try? wds.request(WDS.getLTEAttachParameters, timeout: 5) else { return }
        let a = WDS.parseAttachParameters(r)
        let i = attachProfileIndex(wds)
        let profileAPN = (try? wds.request(WDS.getProfileSettings, [WDS.profileIdentifier(i)]))
            .map { WDS.parseProfile($0, index: i).apn ?? "" }
        let fromNetwork = profileAPN?.isEmpty == true
        guard a != attach || fromNetwork != attachFromNetwork else { return }
        attach = a
        attachFromNetwork = fromNetwork
        if let apn = a.apn, !apn.isEmpty {
            log("default bearer on apn \"\(apn)\"\(fromNetwork ? " (chosen by the network)" : "")")
            // Only the network's choice is worth suggesting; a configured APN is already known.
            if fromNetwork, let m = sim?.mccmnc, learned[m]?["apn"] != apn {
                learned[m] = ["apn": apn, "seen": ISO8601DateFormatter().string(from: Date())]
                saveState()
            }
        }
        publishModem()
    }

    // identities: the full ICCID, IMSI and MSISDN, for XPC only (not SCDynamicStore).
    private func simInfo(identities: Bool = true) -> QMIDSIM? {
        var d = QMIDSIM(mccmnc: sim?.mccmnc, iccidSuffix: sim?.iccidSuffix)
        if let c = card {
            d.card = c.state == 0 ? .absent : c.state == 1 ? .present : .error
            if let p = c.pin, c.state == 1 {
                d.pin = Self.pinState(p.state)
                d.pinRetries = Int(p.retries)
                d.pukRetries = Int(p.pukRetries)
            }
        }
        guard let sim else { return d.card == nil ? nil : d }
        if identities {
            d.iccid = sim.iccid
            d.imsi = imsi
            d.msisdn = msisdn
        }
        if let m = config.carrier(for: sim) {
            d.carrier = m.carrier.name
            d.matchedBy = m.matchedBy
        }
        if let apn = attach?.apn, !apn.isEmpty {
            d.attachAPN = apn
            d.attachAPNFromNetwork = attachFromNetwork
        }
        d.pendingSIM = pendingSIM?.iccidSuffix
        return d
    }

    private func simEvent() -> NSDictionary {
        var d: [String: Any] = [QMIDKey.type: QMIDEventType.sim]
        d[QMIDKey.sim] = simInfo()?.dictionary
        return d as NSDictionary
    }

    // MARK: - Prepared SIM switch (prepareSIM / cancelSIM)

    // Before a client switches cards (eSIM profile switch): writes the attach profile for the
    // card with this ICCID (MCC/MNC: its home network, for carriers matched by it), without a
    // re-attach. The current card's default bearer is untouched; the new card's first attach
    // uses the right APN. Replies with the carrier and attach APN it resolved to.
    public func prepareSIM(iccid raw: String, mccmnc: String?, owner: AnyHashable?) -> (NSDictionary?, String?) {
        guard config.carriers != nil else { return (nil, "no \"carriers\" in the config: the attach APN is the same for every SIM") }
        guard let iccid = ICCID.normalize(raw) else { return (nil, "bad iccid \"\(raw)\"") }
        if let m = mccmnc, !(5...6).contains(m.count) || !m.allSatisfy(\.isNumber) { return (nil, "bad mccmnc \"\(m)\"") }
        guard device != nil, control != nil else { return (nil, "modem not ready") }
        let id = SIMIdentity(mccmnc: mccmnc, iccid: iccid)
        if iccid == sim?.iccid {
            // Already in the modem: a switch back after a prepare for another card.
            if pendingSIM != nil { revertPendingSIM("replaced by the current SIM") }
        } else {
            pendingSIM = id
            pendingOwner = owner
            startPendingPoll()
            applySIM()
            syncProfiles()
            if let e = profileReport.first(where: { $0.attach && $0.failed }) {
                revertPendingSIM("could not be prepared")
                return (nil, "attach profile: \(e.action)")
            }
        }
        let match = config.carrier(for: id)
        let attachPDN = pdns.first { $0.config.isAttach }
        let apn = attachPDN?.config.apn ?? ""
        let reply = QMIDPreparedSIM(apn: apn, carrier: match?.carrier.name, matchedBy: match?.matchedBy)
        if pendingSIM != nil {
            log("prepare SIM \(id.description): \(match.map { "carrier \($0.carrier.name) by \($0.matchedBy)" } ?? "no carrier match"), " +
                "attach profile \(attachPDN?.profileIndex.map(String.init) ?? "?") → apn \"\(apn)\", no re-attach", level: .notice)
        }
        publishModem()
        return (reply.dictionary, nil)
    }

    // The switch didn't happen (failed or cancelled). Only the pending card's ICCID cancels, so a
    // late cancel can't undo a newer prepare.
    public func cancelSIM(iccid raw: String) -> String? {
        guard let p = pendingSIM else { return nil }
        guard ICCID.normalize(raw) == p.iccid else {
            log("cancelSIM for SIM …\(raw.suffix(4)) ignored: the pending SIM is \(p.iccidSuffix ?? "?")")
            return nil
        }
        revertPendingSIM("cancelled")
        return nil
    }

    // A client's XPC connection went away (quit, crash): its prepare ends with it.
    public func clientGone(_ owner: AnyHashable) {
        guard pendingSIM != nil, pendingOwner == owner else { return }
        revertPendingSIM("dropped: the client went away")
    }

    // While a card is pending, read the SIM every 2 s, so the switch is seen within ~2 s whether
    // the new card attaches or not; give up after pendingSIMTimeout.
    private func startPendingPoll() {
        pendingPoll?.cancel()
        let deadline = Date().addingTimeInterval(pendingSIMTimeout)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self, self.pendingSIM != nil else { return }
            if self.checkSIM() { self.reconcile("follow the SIM") }
            if self.pendingSIM != nil, Date() >= deadline {
                self.revertPendingSIM("not in after \(Int(self.pendingSIMTimeout)) s")
            }
        }
        t.resume()
        pendingPoll = t
    }

    private func endPendingSIM() {
        pendingSIM = nil
        pendingOwner = nil
        pendingPoll?.cancel()
        pendingPoll = nil
    }

    // Back to the card in the modem, unless the prepared one is in after all. The current card's
    // bearer still uses its own APN, so putting the profile back re-attaches nothing.
    private func revertPendingSIM(_ reason: String) {
        guard let p = pendingSIM else { return }
        let changed = checkSIM()
        guard pendingSIM != nil else {
            if changed { reconcile("follow the SIM") }
            return
        }
        endPendingSIM()
        for q in pdns { q.blocked.removeAll() }   // a dial meanwhile used the prepared card's APN
        log("prepared SIM \(p.iccidSuffix ?? "") \(reason); attach profile back to SIM \(sim?.description ?? "?")", level: .notice)
        applySIM()
        syncProfiles()
        publishModem()
    }

    // MARK: - Device arrival (IOKit)

    // USB vendors whose devices qmid opens and whose arrivals it reacts to.
    private var vendorIDs: [UInt16] { QMIDevice.vendorIDs(extra: config.usbVendorIDs) }

    private func watchArrivals() {
        guard arrivalPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, queue)
        arrivalPort = port
        // idVendor in the matching dictionary matched nothing on macOS 27 (tested), so match
        // every USB interface and filter by the registry property here.
        let match = IOServiceMatching("IOUSBHostInterface")
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            let me = Unmanaged<Manager>.fromOpaque(refcon!).takeUnretainedValue()
            var n = 0
            while case let s = IOIteratorNext(iterator), s != 0 {
                if let v = IORegistryEntryCreateCFProperty(s, "idVendor" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? NSNumber, me.vendorIDs.contains(v.uint16Value) {
                    n += 1
                }
                IOObjectRelease(s)
            }
            if n > 0 { me.deviceArrived() }
        }
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, match, callback, ctx, &arrivalIterator)
        while case let s = IOIteratorNext(arrivalIterator), s != 0 { IOObjectRelease(s) }   // arm
    }

    // Each of the modem's interfaces arrives separately: log and schedule one reopen per burst.
    private func deviceArrived() {
        guard device == nil else { return }
        if let last = lastArrival, Date().timeIntervalSince(last) < 5 { return }
        lastArrival = Date()
        // Appeared again while an open waits on the earlier set (the modem enumerates twice
        // after a reset): drop that open, which would only time out, and open the new one.
        if opening, let d = openingDevice {
            log("modem interfaces appeared again while opening; restarting the open")
            d.cancel()
        }
        log("modem interfaces appeared; opening")
        fastReopenUntil = Date().addingTimeInterval(60)
        reopenScheduled = false
        scheduleReopen(after: 1)
    }

    // MARK: - Sleep / wake

    private static let msgCanSystemSleep: UInt32 = 0xE000_0270
    private static let msgSystemWillSleep: UInt32 = 0xE000_0280
    private static let msgSystemHasPoweredOn: UInt32 = 0xE000_0300

    private func watchPower() {
        guard powerPort == nil else { return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        var port: IONotificationPortRef?
        let root = IORegisterForSystemPower(ctx, &port, { refcon, _, messageType, argument in
            let me = Unmanaged<Manager>.fromOpaque(refcon!).takeUnretainedValue()
            me.powerEvent(messageType, argument)
        }, &powerNotifier)
        guard root != 0, let port else { log("sleep/wake notifications unavailable"); return }
        rootPowerPort = root
        powerPort = port
        IONotificationPortSetDispatchQueue(port, queue)
    }

    private func powerEvent(_ type: UInt32, _ argument: UnsafeMutableRawPointer?) {
        switch type {
        case Self.msgCanSystemSleep, Self.msgSystemWillSleep:
            if type == Self.msgSystemWillSleep { log("system going to sleep; calls stay up") }
            IOAllowPowerChange(rootPowerPort, Int(bitPattern: argument))
        case Self.msgSystemHasPoweredOn:
            log("system woke; checking the modem")
            queue.asyncAfter(deadline: .now() + 2) { self.wakeCheck() }
        default:
            break
        }
    }

    // After wake, and every 15 s: the modem's data path and control channel must be alive and
    // every connected call must still be up; otherwise reopen the device or redial the PDN.
    // Catches a modem that restarted or hung its data side internally while USB stayed up (no
    // termination, no indications). Returns false if the device was dropped.
    @discardableResult
    private func checkHealth(reason: String?) -> Bool {
        guard let dev = device else { return false }
        let when = reason.map { " after \($0)" } ?? ""
        let stuck = dev.modem.oldestPendingOutMs()
        if stuck > 10_000 {
            log("modem data path stalled (uplink transfer pending \(stuck / 1000) s)\(when); reopening it", level: .error)
            reopenNow()
            return false
        }
        guard (try? dev.send(.ctl, client: 0, message: CTL.getVersionInfo, timeout: 5)) != nil else {
            log("modem not answering\(when); reopening it", level: .error)
            reopenNow()
            return false
        }
        guard clientsAlive() else {
            log("modem not answering on qmid's QMI clients\(when); reopening it", level: .error)
            reopenNow()
            return false
        }
        for p in pdns where p.state == .connected {
            if p.session?.isConnected() == true {
                if reason != nil { refreshSettings(p) }
            } else {
                // clientsAlive() just passed, so the client IDs are valid: release them (a
                // restarted QMI stack is caught above, or by CTL Sync, and reopens instead).
                log("\(p.config.name): call gone\(when); redialing", level: .notice)
                dropped(p, stopCall: true, error: "call gone\(when)", now: true)
            }
        }
        return true
    }

    // The modem can restart its QMI stack while USB stays up: CTL still answers, but the client
    // IDs qmid holds are gone and requests on them get no response (or InvalidClientId).
    private func clientsAlive() -> Bool {
        guard let wds = control else { return true }
        do {
            try wds.request(WDS.getProfileList, WDS.profileListRequest(), timeout: 5)
            return true
        } catch QMIHostError.timeout(_, _) {
            return false
        } catch QMIHostError.protocolError(let e, _) {
            return e != .invalidClientID
        } catch {
            return true
        }
    }

    private func reopenNow() {
        deviceLost()
        reopenScheduled = false
        scheduleReopen(after: 1)
    }

    private func wakeCheck() {
        checkHealth(reason: "wake")
        log("wake check done")
    }

    // MARK: - APN sync (config → modem profiles)

    private func ensureModemAutoconnectOff() {
        guard let wds = control, let r = try? wds.request(WDS.getAutoconnectSettings),
              let st = WDS.parseAutoconnect(r), st != .disabled else { return }
        // Modem-side autoconnect redials on its own, outside qmid's control and backoff.
        do {
            try wds.request(WDS.setAutoconnectSettings, [.u8(0x01, WDS.AutoconnectSetting.disabled.rawValue)])
            log("modem autoconnect was \(st); disabled")
        } catch {
            log("modem autoconnect is \(st); could not disable: \(error)", level: .error)
        }
    }

    private func readProfiles(_ wds: QMIClient) throws -> [WDS.Profile] {
        let list = try WDS.parseProfileList(try wds.request(WDS.getProfileList, WDS.profileListRequest()))
        return try list.map { WDS.parseProfile(try wds.request(WDS.getProfileSettings, [WDS.profileIdentifier($0.index)]), index: $0.index) }
    }

    private func attachProfileIndex(_ wds: QMIClient) -> UInt8 {
        if let r = try? wds.request(WDS.getLTEAttachPDNList), let first = WDS.parseAttachPDNList(r).current.first {
            return UInt8(truncatingIfNeeded: first)
        }
        return 1
    }

    // Resolves every PDN to a modem profile, creating or rewriting profiles to match the config.
    // Returns the indexes whose settings changed (their PDNs must redial).
    @discardableResult
    private func syncProfiles() -> Set<UInt8> {
        guard let wds = control else { return [] }
        syncing = true
        defer { syncing = false }
        var changed: Set<UInt8> = []
        var report: [ProfileSyncEntry] = []
        profileSyncError = nil
        do {
            var profiles = try readProfiles(wds)
            var attachIndex = attachProfileIndex(wds)
            var claimed = Set<UInt8>()
            // A pinned index belongs to its PDN: no other PDN resolves to it, not even the attach
            // PDN when the modem's attach profile is one of them (the attach list is moved instead).
            let pinned = Set(pdns.compactMap { $0.config.profile.map { UInt8(truncatingIfNeeded: $0) } })
            var forceReattach = false               // attach profile or its PDP type changed
            var attachAPNChange: String?            // the attach profile's new APN

            for p in pdns {
                var want = p.desiredProfile
                var entry = ProfileSyncEntry(pdn: p.config.name)
                var wrote = false
                func willWrite() {
                    lastSyncWrite = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                    wrote = true
                }
                // Which profile: explicit index, the attach profile, an APN match, or a new one.
                var index: UInt8?
                if let i = p.config.profile { index = UInt8(i) }
                else if p.config.isAttach, !pinned.contains(attachIndex), !claimed.contains(attachIndex) { index = attachIndex }
                else if let saved = savedProfiles[p.config.name], saved > 0, saved <= 255,
                        profiles.contains(where: { $0.index == UInt8(saved) }),
                        !claimed.contains(UInt8(saved)), !pinned.contains(UInt8(saved)) {
                    index = UInt8(saved)
                }
                else if let apn = p.config.apn,
                        let m = profiles.first(where: { $0.apn?.lowercased() == apn.lowercased() && !claimed.contains($0.index) && !pinned.contains($0.index) }) {
                    index = m.index
                }
                // A failed write costs this PDN only: the others still sync, and a re-attach an
                // earlier PDN needs still happens.
                do {
                    if let i = index, let existing = profiles.first(where: { $0.index == i }) {
                        want.index = i
                        let diffs = existing.differences(from: want)
                        if !diffs.isEmpty {
                            willWrite()
                            try wds.request(WDS.modifyProfile, [WDS.profileIdentifier(i)] + want.settingTLVs)
                            log("\(p.config.name): profile \(i) updated (\(diffs.joined(separator: ", ")))")
                            changed.insert(i)
                            if i == attachIndex {
                                if diffs.contains(where: { $0.hasPrefix("pdp") }) { forceReattach = true }
                                else if diffs.contains(where: { $0.hasPrefix("apn:") }) { attachAPNChange = want.apn ?? "" }
                            }
                            entry.action = "updated: " + diffs.joined(separator: ", ")
                        } else {
                            entry.action = "in sync"
                        }
                    } else if let apn = p.config.apn {
                        // A pinned index ("profile": N) is requested through the PDP context number.
                        if let pinned = index { want.contextNumber = pinned }
                        willWrite()
                        let r = try wds.request(WDS.createProfile, [.u8(0x01, WDS.profileType3GPP)] + want.settingTLVs)
                        guard let i = WDS.parseCreatedProfileIndex(r) else { throw QMIHostError.transport("create profile: no index") }
                        if let pinned = index, pinned != i {
                            log("\(p.config.name): asked for profile \(pinned), modem created \(i)")
                        }
                        want.index = i
                        index = i
                        log("\(p.config.name): created profile \(i) for apn \(apn)")
                        changed.insert(i)
                        entry.action = "created"
                    } else {
                        p.lastError = "profile \(index.map(String.init) ?? "?") does not exist and no apn is configured"
                        entry.action = p.lastError ?? ""
                    }
                } catch {
                    log("\(p.config.name): writing profile \(index.map(String.init) ?? "(new)") failed: \(error)", level: .error)
                    entry.action = "write failed: \(error)"
                    entry.failed = true
                    // A failed modify leaves the profile with its old settings; a failed create, none.
                    if let i = index, !profiles.contains(where: { $0.index == i }) { index = nil }
                }
                p.profileIndex = index
                if p.config.isAttach, let i = index, i != attachIndex {
                    do {
                        willWrite()
                        try wds.request(WDS.setLTEAttachPDNList, WDS.attachPDNListRequest([UInt16(i)]))
                        log("\(p.config.name): LTE attach profile \(attachIndex) → \(i)")
                        attachIndex = i
                        forceReattach = true
                    } catch {
                        log("\(p.config.name): could not make profile \(i) the LTE attach profile: \(error)", level: .error)
                    }
                }
                if let i = index { claimed.insert(i); entry.profile = i; savedProfiles[p.config.name] = Int(i) }
                entry.attach = index == attachIndex
                report.append(entry)
                if wrote { profiles = (try? readProfiles(wds)) ?? profiles }
            }

            // Profile Changed events for the profiles we use.
            do {
                try wds.request(WDS.configureProfileEventList, WDS.profileEventRegistration(Array(claimed).sorted()))
            } catch {
                log("profile change events unavailable: \(error)")
            }

            saveState()
            if pendingSIM != nil, forceReattach || attachAPNChange != nil {
                // The attach profile now holds the prepared card's settings for its first attach;
                // a re-attach now would attach the current card with them.
                log("attach profile set for the prepared SIM; no re-attach")
            } else if forceReattach {
                reattachLTE()
            } else if let apn = attachAPNChange {
                // Nothing to re-attach for when the default bearer already uses the new APN (the
                // network chose it, or the profile is being put back the way it was attached).
                let current = psAttached == false ? nil : (try? wds.request(WDS.getLTEAttachParameters, timeout: 5)).flatMap { WDS.parseAttachParameters($0).apn }
                if !apn.isEmpty, let current, current.lowercased() == apn.lowercased() {
                    log("default bearer already on apn \"\(current)\"; no re-attach needed")
                } else if apn.isEmpty, current != nil, attachFromNetwork {
                    log("default bearer already on the network's choice of apn; no re-attach needed")
                } else {
                    reattachLTE()
                }
            }
            for i in report.indices {
                report[i].settings = profiles.first { $0.index == report[i].profile }?.summary
            }
        } catch {
            log("profile sync failed: \(error)", level: .error)
            profileSyncError = "\(error)"
        }
        profileReport = report
        return changed
    }

    // The attach APN changed: detach and re-attach so the default bearer uses it (DMS Set
    // Operating Mode: low power, then online). All PDNs drop and are redialed.
    private var lastReattach: Date?
    private var reattachDeferred = false
    private var radioOff = false             // low power for a re-attach, online not sent yet
    private var radioReopened = false        // retryRadioOnline reopened the device this time
    private var reattachStarted: UInt64 = 0  // uptime ns; Serving System indications received earlier are stale

    // DMS Set Operating Mode online, ending a re-attach's low power (also when it was cut short
    // by a reopen or shutdown, so the modem isn't left offline).
    private func radioOnline(_ dev: QMIDevice) throws {
        let dms = try dev.allocateClient(.dms)
        defer { dms.release() }
        // NoEffect: already online (an earlier request took effect but its response was lost).
        try dms.request(DMS.setOperatingMode, DMS.operatingModeRequest(.online), timeout: 20, accept: [.noEffect])
        radioOff = false
        radioReopened = false
    }

    // radioOnline, retried 2 s apart; after the third failure the device is reopened once (which
    // tries again, openDevice), then retried every 30 s, rather than leaving the modem in low
    // power with every dial held by the registration gate. The health check can't tell: a modem
    // in low power answers QMI.
    private func retryRadioOnline(_ dev: QMIDevice, attempt: Int = 1, then online: @escaping () -> Void) {
        guard device === dev, radioOff else { return }      // reopened meanwhile: openDevice does it
        do {
            try radioOnline(dev)
        } catch {
            if attempt == 3, !radioReopened {
                log("radio not back online (\(error)); reopening the modem", level: .error)
                radioReopened = true
                reopenNow()
                return
            }
            let wait: Double = attempt < 3 ? 2 : 30
            log("radio online failed (\(error)); retrying in \(Int(wait)) s", level: .error)
            queue.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.retryRadioOnline(dev, attempt: attempt + 1, then: online)
            }
            return
        }
        online()
    }

    private func reattachLTE() {
        // Safety net: a sync that keeps changing the attach APN must not cycle the radio. The
        // held-back re-attach runs when the minute is up, so the last attach APN still applies.
        if let last = lastReattach, Date().timeIntervalSince(last) < 60 {
            let wait = 60 - Date().timeIntervalSince(last)
            guard !reattachDeferred else { return }
            reattachDeferred = true
            log("attach APN changed again \(Int(Date().timeIntervalSince(last))) s after the last re-attach; re-attaching in \(Int(wait.rounded(.up))) s", level: .notice)
            queue.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self, self.reattachDeferred else { return }
                self.reattachDeferred = false
                self.reattachLTE()
            }
            return
        }
        reattachDeferred = false
        // In airplane mode the radio is off already; turning it on attaches with the new APN.
        guard !airplane else { return log("attach APN changed; it applies when airplane mode ends", level: .notice) }
        lastReattach = Date()
        guard let dev = device else { return }
        log("attach APN changed; re-attaching (all PDNs drop briefly)", level: .notice)
        reattachStarted = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        do {
            let dms = try dev.allocateClient(.dms)
            defer { dms.release() }
            radioOff = true
            try dms.request(DMS.setOperatingMode, DMS.operatingModeRequest(.lowPower), timeout: 20)
        } catch {
            log("re-attach failed: \(error)", level: .error)
            retryRadioOnline(dev) {}                // in case low power took effect after all
            return
        }
        // Don't dial on the stale attach state: dials wait until the new default bearer is
        // seen (Serving System indication, or the poll below), which redials the PDNs.
        psAttached = false
        serving = "re-attaching"
        publishModem()
        // Online again in 2 s, without holding the queue meanwhile.
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.retryRadioOnline(dev) { [weak self] in
                guard let self, self.nas == nil else { return }
                // No registration indications: poll for the default bearer, but stop on the first
                // unanswered request (the health check deals with a modem that stopped answering).
                do {
                    self.pollAttach(dev, try dev.allocateClient(.nas), remaining: 30)
                } catch {
                    self.log("re-attach: no attach seen (\(error))", level: .error)
                    self.attachSeen()
                }
            }
        }
    }

    private func pollAttach(_ dev: QMIDevice, _ n: QMIClient, remaining: Int) {
        guard device === dev else { return }
        do {
            let attached = try NAS.parseServingSystem(try n.request(NAS.getServingSystem, timeout: 3)).psAttached
            if !attached, remaining > 1 {
                queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.pollAttach(dev, n, remaining: remaining - 1) }
                return
            }
            if !attached { log("re-attach: no attach seen in 30 s", level: .error) }
        } catch {
            log("re-attach: no attach seen (\(error))", level: .error)
        }
        n.release()
        attachSeen()
    }

    // Without NAS indications: back to "attach state unknown" (no gate) and dial.
    private func attachSeen() {
        psAttached = nil
        serving = ""
        publishModem()
        redialWanted()
    }

    private func profileChanged(index: UInt8, event: UInt8, receivedAt: UInt64) {
        // Our own writes raise the same event; ignore those (and anything during a sync).
        if syncing || receivedAt < lastSyncWrite + 3_000_000_000 { return }
        guard pdns.contains(where: { $0.profileIndex == index }) else { return }
        changedOutside("profile \(index) changed (event \(event))")
    }

    // Someone else (an AT command, the firmware's carrier config) edited a profile qmid uses:
    // put it back, but don't fight an editor that keeps changing it, each round possibly
    // re-attaching. Rewriting resumes on reload or when the modem is reopened.
    private var outsideEdits: [Date] = []
    private var outsideEditsHalted = false

    private func changedOutside(_ reason: String) {
        guard !outsideEditsHalted else { return }
        let now = Date()
        outsideEdits = outsideEdits.filter { now.timeIntervalSince($0) < 600 } + [now]
        guard outsideEdits.count <= 3 else {
            outsideEditsHalted = true
            log("profiles keep changing outside qmid (\(outsideEdits.count) times in 10 min, now \(reason)); " +
                "no longer rewriting them until reload or the modem reopens", level: .error)
            return
        }
        reconcile(reason)
    }

    // Periodic checks while the device is open: health every 15 s, profiles every 30 s. This
    // firmware sends no Profile Changed indication for AT+CGDCONT edits, so the profiles qmid
    // uses are compared with the config.
    private func startProfileCheck() {
        profileCheck?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 15, repeating: 15)
        var tick = 0
        t.setEventHandler { [weak self] in
            guard let self else { return }
            tick += 1
            guard self.checkHealth(reason: nil) else { return }
            // The SIM is otherwise read on attach, but a new SIM (eSIM switch) whose attach APN
            // is wrong never attaches: while detached, read it every tick, so its carrier's APN
            // gets a chance. Also retry when the home MCC/MNC was unreadable at the last read.
            if self.config.carriers != nil,
               self.psAttached == false || (tick % 2 == 0 && !self.config.identifies(self.sim)),
               self.checkSIM() {
                self.reconcile("follow the SIM")
            }
            // Before the drift check, so it compares against the current SIM's settings.
            if tick % 2 == 0 { self.checkProfiles() }
        }
        t.resume()
        profileCheck = t
    }

    private func checkProfiles() {
        guard let wds = control, !syncing, !outsideEditsHalted, let profiles = try? readProfiles(wds) else { return }
        var drift: [String] = []
        for p in pdns {
            guard let i = p.profileIndex else { continue }
            guard let cur = profiles.first(where: { $0.index == i }) else { drift.append("profile \(i) (\(p.config.name)) deleted"); continue }
            var want = p.desiredProfile
            want.index = i
            let d = cur.differences(from: want)
            if !d.isEmpty { drift.append("profile \(i) (\(p.config.name)): \(d.joined(separator: ", "))") }
        }
        if !drift.isEmpty { changedOutside("changed outside qmid: " + drift.joined(separator: "; ")) }
    }

    // Rewrites profiles to match the config and redials the PDNs whose profile changed.
    private func reconcile(_ reason: String) {
        log("profiles \(reason); re-syncing")
        resyncProfiles()
    }

    // Syncs the profiles and redials the PDNs whose profile changed under them.
    private func resyncProfiles() {
        let before = Dictionary(uniqueKeysWithValues: pdns.map { ($0.config.name, $0.profileIndex) })
        let changed = syncProfiles()
        for p in pdns {
            guard let i = p.profileIndex, changed.contains(i) || before[p.config.name] != i else { continue }
            if p.state == .connected || p.state == .backoff {
                p.cancelRetry()
                dropped(p, stopCall: true, error: "profile changed", now: true)
            }
        }
    }

    public func profiles() -> NSArray {
        guard let wds = control else { return [] }
        var out: [[String: Any]] = []
        if let sim {
            var e: [String: Any] = ["sim": sim.description]
            if config.carriers != nil {
                e["carrier"] = config.carrier(for: sim).map { "\($0.carrier.name) by \($0.matchedBy)" } ?? "no match"
            }
            if let apn = attach?.apn, !apn.isEmpty { e["attachAPN"] = apn + (attachFromNetwork ? " (chosen by the network)" : "") }
            if let p = pendingSIM { e["pending"] = p.description }
            out.append(e)
        } else {
            out.append(["sim": "not read yet"])
        }
        out += profileReport.map(\.dictionary)
        if let e = profileSyncError { out.append(["error": e]) }
        if !learned.isEmpty {
            out.append(["learned": learned.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value["apn"] ?? "")" }])
        }
        if let list = try? readProfiles(wds) {
            out.append(["modem": list.map(\.summary)])
        }
        if let r = try? wds.request(WDS.getAutoconnectSettings), let a = WDS.parseAutoconnect(r) {
            out.append(["autoconnect": a.description])
        }
        out.append(["attach": Int(attachProfileIndex(wds))])
        return out as NSArray
    }

    // The serving and neighbour cells, read now on the registration-watch NAS client. Each
    // message is optional (older firmware lacks some); a short timeout, as this runs on the
    // manager queue.
    public func radio(raw: Bool) -> (NSDictionary?, String?) {
        guard let n = nas else { return (nil, "modem not ready") }
        var lines: [String] = []
        func read(_ message: UInt16) -> QMIMessage? {
            do {
                let r = try n.request(message, timeout: 2)
                if raw {
                    lines += r.tlvs.filter { $0.type != 0x02 }.map { String(format: "0x%04x 0x%02x: ", message, $0.type) + $0.value.hex }
                }
                return r
            } catch {
                if raw { lines.append(String(format: "0x%04x: ", message) + "\(error)") }
                return nil
            }
        }
        // COEX for the NR bandwidth; a client per call, as radio() is polled rarely.
        var coexReply: QMIMessage?
        if let dev = device, let coex = try? dev.allocateClient(NAS.coexService) {
            do {
                let r = try coex.request(NAS.coexGetWWANState, timeout: 2)
                if raw { lines += r.tlvs.filter { $0.type != 0x02 }.map { String(format: "coex 0x0022 0x%02x: ", $0.type) + $0.value.hex } }
                coexReply = r
            } catch {
                if raw { lines.append("coex 0x0022: \(error)") }
            }
            coex.release()
        }
        let info = NAS.radioCells(sysInfo: read(NAS.getSysInfo), cellLocation: read(NAS.getCellLocationInfo),
                                  signal: read(NAS.getSignalInfo), rfBand: read(NAS.getRFBandInfo),
                                  ca: read(NAS.getLTECPHYCAInfo), coex: coexReply)
        let radio = QMIDRadio(cells: info.cells.map(Self.cellInfo), endcAvailable: info.endcAvailable,
                              raw: raw ? lines : nil)
        return (radio.dictionary, nil)
    }

    // MARK: - Airplane mode, restart, bands

    public func setAirplaneMode(_ on: Bool) -> String? {
        guard let dev = device else { return "modem not ready (\(deviceState.rawValue))" }
        guard !radioOff else { return "a re-attach is in progress; try again in a few seconds" }
        do {
            let dms = try dev.allocateClient(.dms)
            defer { dms.release() }
            try dms.request(DMS.setOperatingMode, DMS.operatingModeRequest(on ? .lowPower : .online), timeout: 20,
                            accept: [.noEffect])
        } catch {
            return "\(error)"
        }
        setAirplane(on, by: "request")
        return nil
    }

    // The modem's operating mode changed (Event Report): someone else's AT+CFUN, or ours.
    private func operatingModeChanged(_ mode: UInt8) {
        guard !radioOff, !restarting else { return }   // a re-attach's or a restart's own mode change
        setAirplane(DMS.isLowPower(mode), by: "operating mode \(mode)")
    }

    private func setAirplane(_ on: Bool, by why: String) {
        guard on != airplane else { return }
        airplane = on
        log("airplane mode \(on ? "on" : "off") (\(why))", level: .notice)
        publishModem()
        redialWanted()                              // on: the PDNs show it; off: they wait for the attach
    }

    public func restartModem() -> String? {
        guard let dev = device else { return "modem not ready (\(deviceState.rawValue))" }
        restarting = true
        // Ends when the modem goes away (deviceLost), or after 2 minutes if it never does.
        queue.asyncAfter(deadline: .now() + 120) { [weak self] in self?.restarting = false }
        do {
            let dms = try dev.allocateClient(.dms)
            defer { dms.release() }
            try dms.request(DMS.setOperatingMode, DMS.operatingModeRequest(.offline), timeout: 20, accept: [.noEffect])
            // The modem resets right away; its answer may not make it out.
            _ = try? dms.request(DMS.setOperatingMode, DMS.operatingModeRequest(.reset), timeout: 5)
        } catch {
            restarting = false
            return "\(error)"
        }
        log("modem restart requested", level: .notice)
        return nil
    }

    public func bandPreference() -> (NSDictionary?, String?) {
        guard let n = nas else { return (nil, "modem not ready") }
        do {
            let p = NAS.parseBandPreference(try n.request(NAS.getSystemSelectionPreference, timeout: 5))
            let caps = bandCapabilities()
            return (QMIDBandPreference(modes: p.modes, lteBands: p.lte, nrNSABands: p.nrNSA, nrSABands: p.nrSA,
                                       supportedLTEBands: caps.lte, supportedNRBands: caps.nr).dictionary, nil)
        } catch {
            return (nil, "\(error)")
        }
    }

    private func bandCapabilities() -> (lte: [Int], nr: [Int]) {
        guard let dev = device, let dms = try? dev.allocateClient(.dms) else { return ([], []) }
        defer { dms.release() }
        return (try? dms.request(DMS.getBandCapabilities, timeout: 5)).map(DMS.parseBandCapabilities) ?? ([], [])
    }

    // nil lists stay as they are. Refused: an empty list, or a band the modem doesn't support.
    public func setBandPreference(lte: [Int]?, nrNSA: [Int]?, nrSA: [Int]?, persistent: Bool) -> String? {
        guard let n = nas else { return "modem not ready" }
        guard lte != nil || nrNSA != nil || nrSA != nil else { return "no bands given" }
        let caps = bandCapabilities()
        for (name, list, supported) in [("lte", lte, caps.lte), ("nr nsa", nrNSA, caps.nr), ("nr sa", nrSA, caps.nr)] {
            guard let list else { continue }
            if list.isEmpty { return "\(name): at least one band is needed" }
            let bad = list.filter { !supported.isEmpty && !supported.contains($0) }
            if !bad.isEmpty { return "\(name): not supported by this modem: \(bad.map(String.init).joined(separator: ", "))" }
        }
        // The setting before qmid's first change, for resetBandPreference.
        if bandsBefore == nil {
            guard let r = try? n.request(NAS.getSystemSelectionPreference, timeout: 5) else {
                return "couldn't read the current band preference (needed to reset it later)"
            }
            let p = NAS.parseBandPreference(r)
            bandsBefore = ["lte": p.lte, "nsa": p.nrNSA, "sa": p.nrSA]
            saveState()
        }
        return writeBands(n, lte: lte, nrNSA: nrNSA, nrSA: nrSA, persistent: persistent)
    }

    private func writeBands(_ n: QMIClient, lte: [Int]?, nrNSA: [Int]?, nrSA: [Int]?, persistent: Bool) -> String? {
        do {
            try n.request(NAS.setSystemSelectionPreference,
                          NAS.bandPreferenceRequest(lte: lte, nrNSA: nrNSA, nrSA: nrSA, persistent: persistent), timeout: 10)
        } catch {
            return "\(error)"
        }
        func show(_ l: [Int]?) -> String { l.map { $0.map(String.init).joined(separator: ",") } ?? "unchanged" }
        log("band preference set (\(persistent ? "persistent" : "until restart")): lte \(show(lte)), nr nsa \(show(nrNSA)), nr sa \(show(nrSA))",
            level: .notice)
        return nil
    }

    // Back to the setting qmid found before its first change (written as it was, unchecked:
    // the modem's own default may list bands it doesn't report as supported); without one,
    // every supported band.
    public func resetBandPreference(persistent: Bool) -> String? {
        if let b = bandsBefore {
            guard let n = nas else { return "modem not ready" }
            func list(_ k: String) -> [Int]? { b[k].flatMap { $0.isEmpty ? nil : $0 } }
            if let err = writeBands(n, lte: list("lte"), nrNSA: list("nsa"), nrSA: list("sa"), persistent: persistent) { return err }
            bandsBefore = nil
            saveState()
            log("band preference back to the setting before qmid changed it", level: .notice)
            return nil
        }
        // Not through setBandPreference: that would save the current setting as the one to
        // reset to, and the next reset would undo this one.
        guard let n = nas else { return "modem not ready" }
        let caps = bandCapabilities()
        guard !caps.lte.isEmpty || !caps.nr.isEmpty else { return "the modem didn't report its supported bands" }
        let nr = caps.nr.isEmpty ? nil : caps.nr
        return writeBands(n, lte: caps.lte.isEmpty ? nil : caps.lte, nrNSA: nr, nrSA: nr, persistent: persistent)
    }

    static func cellInfo(_ c: NAS.Cell) -> QMIDCell {
        var q = QMIDCell(rat: c.rat == .lte ? .lte : .nr,
                         role: c.role == .primary ? .primary : c.role == .secondary ? .secondary : .neighbor)
        q.channel = c.channel.map(Int.init)
        q.band = c.band ?? q.channel.flatMap { QMIDCell.band(q.rat, channel: $0) }   // the modem's, else from the channel
        q.pci = c.pci.map(Int.init)
        q.cellID = c.cellID
        q.tac = c.tac.map(Int.init)
        q.bandwidth = c.bandwidthMHz
        q.rsrp = c.rsrp
        q.rsrq = c.rsrq
        q.rssi = c.rssi
        q.snr = c.snr
        q.active = c.active
        q.scellIndex = c.scellIndex.map(Int.init)
        return q
    }

    // MARK: - Publishing

    private func publishService(_ p: PDNState) throws {
        guard let s = p.session, let u = p.utun else { return }
        let id = ServicePublisher.serviceID(for: p.config.name)
        try publisher.publish(ServicePublisher.entities(pdnName: p.config.name, interface: u.name,
                                                        settings: s.merged, policy: p.policy),
                              replacingPrefix: ServicePublisher.serviceKey(id))
        publishStatus(p)
    }

    private func publishStatus(_ p: PDNState) {
        var d: [String: Any]
        if let s = p.session, let u = p.utun {
            d = ServicePublisher.pdnStatus(name: p.config.name, interface: u.name,
                                           config: p.pdnConfig, settings: s.merged, policy: p.policy)
        } else {
            d = ["ServiceID": ServicePublisher.serviceID(for: p.config.name), "MuxID": Int(p.muxID),
                 "Policy": p.policy.rawValue]
        }
        d["State"] = p.state.rawValue
        if let e = p.lastError { d["LastError"] = e }
        if p.qos != nil, let c = p.qosState.qci { d["QCI"] = Int(c) }
        if p.qos != nil, let a = p.qosState.ambr { d["AMBR"] = ["Uplink": NSNumber(value: a.uplink), "Downlink": NSNumber(value: a.downlink)] }
        try? publisher.publish([QMIDStoreKey.pdn(p.config.name): d])
        emitPDN(p)
        updateLinkAnchor()
        _ = status()                            // the answer while `queue` is busy
    }

    // Keeps the stand-in interface up, with the families the connected internet PDN has.
    private func updateLinkAnchor() {
        var v4 = false, v6 = false
        if config.linkAnchor ?? true {
            // A PDN redialing with its link kept keeps the stand-in too.
            for p in pdns where p.config.effectiveRole == "internet" {
                guard let s = p.state == .connected ? p.session?.merged : p.heldSettings else { continue }
                if s.ipv4Address != nil { v4 = true }
                if s.ipv6Address != nil { v6 = true }
            }
        }
        guard v4 != linkAnchor.v4 || v6 != linkAnchor.v6 else { return }
        do {
            try LinkAnchor.set(v4: v4, v6: v6)
            linkAnchor = (v4, v6)
            let fams = [v4 ? "ipv4" : nil, v6 ? "ipv6" : nil].compactMap { $0 }.joined(separator: "+")
            log(v4 || v6 ? "stand-in interface \(LinkAnchor.name) up (\(fams)) for apps that ignore utun interfaces"
                         : "stand-in interface \(LinkAnchor.name) removed")
        } catch {
            log("stand-in interface \(LinkAnchor.name): \(error)", level: .error)
        }
    }

    // The PDN as clients see it (status() and events).
    private func pdnInfo(_ p: PDNState) -> QMIDPDN {
        var d = QMIDPDN(name: p.config.name, state: p.state)
        d.policy = p.policy.rawValue
        d.role = p.config.effectiveRole
        d.mux = Int(p.muxID)
        d.wanted = p.wanted
        d.serviceID = ServicePublisher.serviceID(for: p.config.name)
        d.profile = p.profileIndex.map(Int.init)
        d.apn = p.config.apn
        d.interface = p.utun?.name
        if let s = p.session?.merged {
            d.ipv4 = s.ipv4Address?.description
            d.ipv6 = s.ipv6Address?.description
            d.dns = s.ipv4DNS.map(\.description) + s.ipv6DNS.map(\.description)
            d.pcscf = s.pcscfIPv4.map(\.description) + s.pcscfIPv6.map(\.description)
            d.mtu = s.mtu.map(Int.init)
            if let apn = s.apn { d.apn = apn }
        }
        if p.qos != nil {
            d.qci = p.qosState.qci.map(Int.init)
            d.ambr = p.qosState.ambr.map { QMIDAMBR(uplink: $0.uplink, downlink: $0.downlink) }
        }
        d.error = p.lastError
        d.reason = p.reason
        d.causes = p.ends.sorted { $0.key < $1.key }.map { family, end in
            QMIDCause(type: end.typeName, family: Int(family), code: end.code.map(Int.init), name: end.codeName)
        }
        d.blocked = p.blocked.sorted { $0.key < $1.key }.map { "ipv\($0.key): \($0.value)" }
        d.uptime = p.connectedAt.map { Int(Date().timeIntervalSince($0)) }
        d.linkHeld = p.heldSettings != nil
        return d
    }

    // A "pdn" event; uptime changes every second and is left out.
    private func pdnEvent(_ p: PDNState) -> NSDictionary {
        var info = pdnInfo(p)
        info.uptime = nil
        return [QMIDKey.type: QMIDEventType.pdn, QMIDKey.pdn: info.dictionary] as NSDictionary
    }

    private func emitPDN(_ p: PDNState) {
        emitIfChanged(pdnEvent(p), &lastPDNEvent[p.config.name])
    }

    // Only real changes are pushed.
    private func emitIfChanged(_ ev: NSDictionary, _ last: inout NSDictionary?) {
        guard ev != last else { return }
        last = ev
        onEvent?(ev)
    }

    // MARK: - QoS (default bearer QCI, AMBR, dedicated bearers)

    private func startQoS(_ p: PDNState, _ dev: QMIDevice) {
        guard let session = p.session else { return }
        p.qos = PDNQoS(device: dev, session: session, callbackQueue: queue, log: { [weak self] in self?.log($0) })
        snapshotQoS(p)
    }

    // An Event Report for one of this PDN's bearers: applied as is, no query needed.
    private func applyQoSReport(_ p: PDNState, _ m: QMIMessage) {
        let change = PDNQoS.apply(m, to: p.qosState.bearers)
        // Also when the list doesn't change: a deletion of a bearer a running snapshot is
        // still reading must keep the snapshot from bringing it back.
        // The latest event per ID wins: a bearer recreated after a deletion isn't dropped.
        if p.snapshot.running {
            p.snapshot.touched.subtract(change.deleted)
            p.snapshot.touched.formUnion(change.touched)
            p.snapshot.deleted.subtract(change.touched)
            p.snapshot.deleted.formUnion(change.deleted)
        }
        guard change.bearers != p.qosState.bearers else { return }
        PDNQoS.changes(from: p.qosState.bearers, to: change.bearers).forEach { log("\(p.config.name): \($0)") }
        p.qosState.bearers = change.bearers
        emitBearers(p)
    }

    // Reads QCI, AMBR and bearers in full: on connect, and after wake or a reconfiguration
    // (reports may have been missed). A snapshot the modem didn't answer is retried after 2 s,
    // up to 5 times in a row; the last state stays meanwhile.
    private func snapshotQoS(_ p: PDNState) {
        guard let q = p.qos, !p.snapshot.running else { return }
        p.snapshot.retry?.cancel()
        p.snapshot = .init(done: p.snapshot.done, failures: p.snapshot.failures)
        p.snapshot.running = true
        q.snapshot { [weak self, weak p] state in
            guard let self, let p, p.qos === q else { return }
            p.snapshot.running = false
            guard let state else {
                p.snapshot.failures += 1
                guard p.snapshot.failures <= 5 else { p.snapshot.failures = 0; self.log("\(p.config.name): qos: snapshot failed, giving up"); return }
                let item = DispatchWorkItem { [weak self, weak p] in if let self, let p { self.snapshotQoS(p) } }
                p.snapshot.retry = item
                self.queue.asyncAfter(deadline: .now() + 2, execute: item)
                return
            }
            let first = !p.snapshot.done
            p.snapshot.done = true
            p.snapshot.failures = 0
            let old = p.qosState
            var new = state
            if p.snapshot.ambrSince { new.ambr = old.ambr }        // the network changed it meanwhile
            new.bearers = PDNQoS.combine(snapshot: state.bearers, current: old.bearers,
                                         touchedSince: p.snapshot.touched, deletedSince: p.snapshot.deleted)
            p.qosState = new
            if first {
                self.log("\(p.config.name): qci \(new.qci.map(String.init) ?? "?"), AMBR \(Self.describe(new.ambr)), " +
                         "\(new.bearers.count) dedicated bearer\(new.bearers.count == 1 ? "" : "s")")
            }
            PDNQoS.changes(from: old.bearers, to: new.bearers).forEach { self.log("\(p.config.name): \($0)") }
            if new.qci != old.qci || new.ambr != old.ambr { self.publishStatus(p) }
            self.emitBearers(p)
        }
    }

    private func bearersEvent(_ p: PDNState) -> NSDictionary {
        [QMIDKey.type: QMIDEventType.bearers, QMIDKey.pdn: p.config.name,
         QMIDKey.bearers: (p.qos != nil ? p.qosState.bearers : []).map { Self.bearerInfo($0).dictionary }] as NSDictionary
    }

    // Only real changes are pushed (no event yet counts as an empty list), so a PDN that goes
    // down with bearers pushes one empty list.
    private func emitBearers(_ p: PDNState) {
        let ev = bearersEvent(p)
        let previous = lastBearersEvent[p.config.name]
            ?? [QMIDKey.type: QMIDEventType.bearers, QMIDKey.pdn: p.config.name, QMIDKey.bearers: [Any]()] as NSDictionary
        guard ev != previous else { return }
        lastBearersEvent[p.config.name] = ev
        onEvent?(ev)
    }

    static func describe(_ a: WDS.AMBR?) -> String {
        guard let a else { return "?" }
        func mbps(_ v: UInt64) -> String { String(format: v % 1_000_000 == 0 ? "%.0f" : "%.1f", Double(v) / 1_000_000) }
        return "\(mbps(a.uplink))/\(mbps(a.downlink)) Mbps"
    }

    // A bearer as clients see it (status() and events).
    static func bearerInfo(_ b: QoS.Bearer) -> QMIDBearer {
        func rates(_ r: QoS.Bitrates) -> QMIDBitrates { QMIDBitrates(max: r.max, guaranteed: r.guaranteed) }
        func filter(_ f: QoS.PacketFilter) -> QMIDPacketFilter {
            var q = QMIDPacketFilter(id: Int(f.id), precedence: Int(f.precedence), ipVersion: Int(f.ipVersion))
            q.source = f.source?.description
            q.destination = f.destination?.description
            q.ipProtocol = f.ipProtocol.map(Int.init)
            q.sourcePorts = f.sourcePorts.map { Int($0.lowerBound)...Int($0.upperBound) }
            q.destinationPorts = f.destinationPorts.map { Int($0.lowerBound)...Int($0.upperBound) }
            return q
        }
        return QMIDBearer(id: Int(b.qosID), qci: b.qci.map(Int.init), networkInitiated: b.networkInitiated,
                          uplink: rates(b.uplink.rates), downlink: rates(b.downlink.rates),
                          uplinkFilters: b.uplinkFilters.map(filter), downlinkFilters: b.downlinkFilters.map(filter))
    }

    private func modemEvent() -> NSDictionary {
        var d: [String: Any] = [QMIDKey.type: QMIDEventType.modem, QMIDKey.modem: deviceState.rawValue]
        if !serving.isEmpty { d[QMIDKey.network] = serving }
        if let e = deviceError { d[QMIDKey.modemError] = e }
        if airplane { d[QMIDKey.airplaneMode] = true }
        return d as NSDictionary
    }

    // Current state as events, for a new subscriber.
    public func snapshotEvents() -> [NSDictionary] {
        [modemEvent(), simEvent(), plmnEvent()] + pdns.map(pdnEvent) + pdns.filter { $0.qos != nil }.map(bearersEvent)
    }

    private func publishModem() {
        var d: [String: Any] = ["State": deviceState.rawValue]
        if !serving.isEmpty { d["Network"] = serving }
        if let dev = device {
            d["VendorID"] = Int(dev.modem.vendorID)
            d["ProductID"] = Int(dev.modem.productID)
            d["Interface"] = Int(dev.modem.interfaceNumber)
        }
        if let e = deviceError { d["LastError"] = e }
        if airplane { d["AirplaneMode"] = true }
        d["SIM"] = simInfo(identities: false)?.dictionary
        d["PLMN"] = plmnInfo()?.dictionary
        try? publisher.publish([QMIDStoreKey.modem: d])
        emitIfChanged(modemEvent(), &lastModemEvent)
        emitIfChanged(simEvent(), &lastSIMEvent)
        emitIfChanged(plmnEvent(), &lastPLMNEvent)
        _ = status()
    }

    // MARK: - Control (called on `queue`)

    // status() as last built (on `queue`), for clients while `queue` is busy.
    private let lastStatusLock = NSLock()
    private var lastStatus: NSDictionary = [QMIDKey.apiVersion: qmidAPIVersion, QMIDKey.modem: QMIDModemState.absent.rawValue]

    // Not on `queue`: answers from `queue`, or with the status as last built when `queue` is
    // still busy after `wait` (a QMI request waiting on a slow or stuck modem).
    public func status(within wait: TimeInterval, reply: @escaping (NSDictionary) -> Void) {
        let lock = NSLock()
        var pending: ((NSDictionary) -> Void)? = reply
        func answer(_ d: NSDictionary) {
            lock.lock()
            let r = pending
            pending = nil
            lock.unlock()
            r?(d)
        }
        queue.async { answer(self.status()) }
        DispatchQueue.global().asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.lastStatusLock.lock()
            let d = self.lastStatus
            self.lastStatusLock.unlock()
            answer(d)
        }
    }

    public func status() -> NSDictionary {
        let stats = device?.modem.statistics() ?? [:]
        let list = pdns.map { p -> NSDictionary in
            var info = pdnInfo(p)
            if p.qos != nil { info.bearers = p.qosState.bearers.map(Self.bearerInfo) }
            guard let c = stats[NSNumber(value: p.muxID)] else { return info.dictionary }
            let d = NSMutableDictionary(dictionary: info.dictionary)
            d[QMIDKey.counters] = c
            return d
        }
        var out: [String: Any] = [QMIDKey.apiVersion: qmidAPIVersion, QMIDKey.modem: deviceState.rawValue, QMIDKey.pdns: list]
        if let v = version { out[QMIDKey.version] = v }
        if let i = imei { out[QMIDKey.imei] = i }
        out[QMIDKey.airplaneMode] = airplane
        if !serving.isEmpty { out[QMIDKey.network] = serving }
        if let e = deviceError { out[QMIDKey.modemError] = e }
        if let g = stats[0] { out[QMIDKey.datapath] = g }
        out[QMIDKey.sim] = simInfo()?.dictionary
        out[QMIDKey.plmn] = plmnInfo()?.dictionary
        let d = out as NSDictionary
        lastStatusLock.lock()
        lastStatus = d
        lastStatusLock.unlock()
        return d
    }

    public func getConfig() -> Data {
        (try? Data(contentsOf: URL(fileURLWithPath: configPath))) ?? config.encoded()
    }

    // Validates and applies a new config, then writes it (the source of truth for PDNs and the
    // modem's data profiles).
    public func setConfig(_ json: Data) -> String? {
        let c: QMIDConfig
        do { c = try QMIDConfig.decode(json) } catch { return "\(error)" }
        do {
            try FileManager.default.createDirectory(atPath: (configPath as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try c.encoded().write(to: URL(fileURLWithPath: configPath), options: .atomic)
        } catch {
            return "writing \(configPath): \(error.localizedDescription)"
        }
        log("config replaced through the API", level: .notice)
        return reload()
    }

    // Replies when the attempt has ended: nil once connected, else why not (lastError).
    // Connected already: replies at once and starts maxUptime again.
    public func connect(_ name: String, reply: @escaping (String?) -> Void) {
        guard let p = pdns.first(where: { $0.config.name == name }) else { return reply("no PDN \(name)") }
        p.attempts = 0
        p.blocked.removeAll()
        guard device != nil else {
            if p.config.oneShot { return reply("modem not ready (\(deviceState.rawValue))") }
            p.wanted = true
            return reply("modem not ready (\(deviceState.rawValue)); will connect when it is")
        }
        p.wanted = true
        if p.state == .connected {
            armUptimeLimit(p)
            return reply(nil)
        }
        p.waiters.append(reply)
        dial(p)
    }

    public func disconnect(_ name: String) -> String? {
        guard let p = pdns.first(where: { $0.config.name == name }) else { return "no PDN \(name)" }
        p.wanted = false
        p.cancelRetry()
        teardown(p, stopCall: true, state: .idle, error: nil)
        log("\(name): disconnected by request", level: .notice)
        return nil
    }

    // Re-publishes the service entity only; no reconnect (PLAN.md §5.2).
    public func setPolicy(_ name: String, _ policy: String) -> String? {
        guard let p = pdns.first(where: { $0.config.name == name }) else { return "no PDN \(name)" }
        guard let pol = QMIDPolicy(rawValue: policy) else {
            return "bad policy \(policy) (\(QMIDPolicy.allCases.map(\.rawValue).joined(separator: ", ")))"
        }
        p.policy = pol
        do {
            if p.state == .connected { try publishService(p) } else { publishStatus(p) }
        } catch {
            return "\(error)"
        }
        log("\(name): policy \(pol.rawValue)")
        return nil
    }

    // Re-reads the config and applies it. A PDN whose settings are unchanged keeps its call and
    // state (connect/disconnect and setPolicy included; blocked families are cleared); a new
    // policy alone is applied without a redial. Changed, new and removed PDNs are torn down,
    // created and redialed. Profiles are synced, which drops a call whose profile changed.
    public func reload() -> String? {
        let c: QMIDConfig
        do { c = try QMIDConfig.load(path: configPath) } catch { return "\(error)" }
        // As dialed: checkSIM below may already resolve the old states against the new config.
        let before = Dictionary(uniqueKeysWithValues: pdns.map { ($0.config.name, ($0, $0.config)) })
        config = c
        if device != nil { checkSIM() }             // resolve against the SIM in the modem now
        let resolved = c.resolvedPDNs(for: pendingSIM ?? sim, prepared: pendingSIM != nil)

        var kept: [String: PDNState] = [:]
        for q in resolved {
            guard let (p, old) = before[q.name], Self.sameExceptPolicy(old, q) else { continue }
            p.config = q
            if old.policy != q.policy {
                p.policy = q.policy.flatMap(QMIDPolicy.init(rawValue:)) ?? .preferWifi
                if p.state == .connected { try? publishService(p) }
            }
            p.blocked.removeAll()
            kept[q.name] = p
        }
        for (name, (p, _)) in before where kept[name] == nil {
            p.cancelRetry()
            teardown(p, stopCall: true, state: .idle, error: nil)
            if !resolved.contains(where: { $0.name == name }) {
                publisher.remove(prefix: QMIDStoreKey.pdn(name))
                lastPDNEvent[name] = nil
                lastBearersEvent[name] = nil
            }
        }
        // A kept PDN keeps its mux; a new one takes the lowest free (one still stopping a
        // cancelled call is waited for by dial()).
        var muxes = Set(kept.values.map(\.muxID))
        pdns = resolved.map { q in
            if let p = kept[q.name] { return p }
            let mux = (UInt8(0x81)...UInt8(0xFE)).first { !muxes.contains($0) } ?? 0x81
            muxes.insert(mux)
            return PDNState(config: q, muxID: mux)
        }
        lastReattach = nil                          // a deliberate change may re-attach at once
        outsideEdits = []
        outsideEditsHalted = false
        let redialed = pdns.filter { kept[$0.config.name] == nil }.map(\.config.name)
        log("config reloaded: \(c.pdns.map(\.name).joined(separator: ", "))" +
            (redialed.isEmpty ? ", every PDN unchanged" : "; new or changed: \(redialed.joined(separator: ", "))"))
        if device != nil { resyncProfiles() }
        onEvent?([QMIDKey.type: QMIDEventType.config] as NSDictionary)
        for p in pdns {
            publishStatus(p)
            if p.wanted, device != nil, p.session == nil {
                p.attempts = 0
                dial(p)
            }
        }
        return nil
    }

    // A PDN whose config differs only in its policy keeps its call.
    static func sameExceptPolicy(_ a: QMIDConfig.PDN, _ b: QMIDConfig.PDN) -> Bool {
        var a = a
        a.policy = b.policy
        return a == b
    }

    // Clean shutdown: stop calls, release clients, remove every key.
    public func shutdown() {
        stopped = true
        if radioOff, let dev = device { try? radioOnline(dev) }   // don't exit with the radio off
        for p in pdns {
            p.cancelRetry()
            teardown(p, stopCall: true, state: .idle, error: nil)
        }
        [wda, control, nas, uimWatch, dmsWatch].forEach { $0?.release() }
        device?.close()
        device = nil
        publisher.removeAll()
        LinkAnchor.down()
        linkAnchor = (false, false)
    }
}
