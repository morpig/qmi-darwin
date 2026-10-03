import Foundation
import QMIDAPI
import IOKit
import IOKit.pwr_mgt
import QMIDatapath
import QMIKit

// The daemon's state machine (PLAN.md §7): device, datapath, and one PDNState per configured
// PDN. Everything runs on `queue`; QMI requests are synchronous and block it briefly.
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
    private var deviceState = "absent"
    private var deviceError: String?
    private var reopenScheduled = false
    private var fastReopenUntil: Date?       // after arrival/loss: retry every 3 s while the modem boots
    private var lastArrival: Date?

    final class PDNState {
        var config: QMIDConfig.PDN
        let muxID: UInt8
        var policy: ServicePublisher.Policy
        var wanted: Bool                    // autoconnect or explicit connect
        var state = "idle"
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
        var qosSnapshot: DispatchWorkItem?  // a snapshot retry
        var qosSnapshotRunning = false
        var qosTouched = Set<UInt32>()      // bearers reported / deleted while a snapshot runs
        var qosDeleted = Set<UInt32>()
        var qosAMBRSince = false            // an AMBR indication arrived while a snapshot runs
        var qosSnapshotDone = false         // the first snapshot completed
        var qosRetries = 0                  // failed snapshots in a row
        var dialing: PDNSession?            // a dial running on dialQueue
        var dialCancelled = false           // torn down meanwhile: its call is stopped when it returns
        var dialAgain = false               // dial once the cancelled one has returned
        var waiters: [(String?) -> Void] = []  // connect calls waiting for the attempt's outcome
        var uptimeLimit: DispatchWorkItem?  // maxUptime
        var reason: String?                 // lastError as a word for clients (QMIDReason)
        var ends: [UInt8: WDS.CallEnd] = [:]  // lastError's call end causes, per family

        var dialFamilies: [UInt8] { config.families.filter { blocked[$0] == nil } }
        var blockedSummary: String { PDNSession.summary(blocked) }

        init(config: QMIDConfig.PDN, muxID: UInt8) {
            self.config = config
            self.muxID = muxID
            policy = config.policy.flatMap(ServicePublisher.Policy.init(rawValue:)) ?? .preferWifi
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
            // (XL's IMS APN answers IPv6 only, the network picks what it grants).
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
    private var profileReport: [[String: Any]] = []
    private var profileCheck: DispatchSourceTimer?
    private var linkAnchor: (v4: Bool, v6: Bool) = (false, false)
    private var nas: QMIClient?              // Serving System indications (registration gate)
    private var psAttached: Bool?            // nil until known
    private var sim: SIMIdentity?            // nil until read (and while the modem is away)
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
        }
    }

    private func saveState() {
        let j: [String: Any] = ["profiles": savedProfiles, "learned": learned]
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
            LinkAnchor.down()                       // left over by a crashed qmid
            self.watchArrivals()
            self.watchPower()
            self.openDevice()
        }
    }

    private func openDevice() {
        reopenScheduled = false
        guard device == nil else { return }
        deviceState = "opening"
        var opened: QMIDevice?
        do {
            let dev = try QMIDevice.open(interface: config.interface)
            opened = dev
            dev.modem.terminationHandler = { [weak self] in self?.queue.async { self?.deviceLost() } }
            dev.trace = { [weak self] in self?.logSink(.debug, $0) }
            dev.traceEnabled = { [weak self] in self?.debugEnabled() ?? false }
            // Stamp arrival: a disconnect for a call we just stopped can reach `queue` after a new
            // session has been given the same (reused) client ID.
            dev.onIndication = { [weak self] m in
                let t = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                self?.queue.async { self?.indication(m, receivedAt: t) }
            }
            // Right after an arrival the firmware may still be booting: wait for QMI on the open
            // interface (up to 45 s) rather than cycling close/reopen.
            let booting = fastReopenUntil.map { Date() < $0 } ?? false
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
                dev.close()
                throw QMIHostError.transport("unusable data format: \(problem)")
            }
            dev.modem.batchUtunIO = config.utunBatch ?? true
            dev.modem.batchFallbackHandler = { [weak self] reason in
                self?.log("utun batching off: \(reason); using one system call per packet", level: .notice)
            }
            try dev.modem.startDatapath(withDownlinkSize: UInt(g.downlinkMaxSize ?? 16384),
                                        uplinkSize: UInt(g.uplinkMaxSize ?? 0),
                                        uplinkDatagrams: UInt(g.uplinkMaxDatagrams ?? 0))
            device = dev
            dmsICCIDUnsupported = false             // may be a different modem
            outsideEdits = []
            outsideEditsHalted = false
            self.wda = wda
            deviceState = "ready"
            deviceError = nil
            fastReopenUntil = nil
            openFailures = 0
            log(String(format: "modem %04x:%04x ready on interface %d (dl %@x%@, ul %@x%@, utun batching %@)",
                       dev.modem.vendorID, dev.modem.productID, dev.modem.interfaceNumber,
                       g.downlinkMaxDatagrams.map { "\($0)" } ?? "?", g.downlinkMaxSize.map { "\($0)" } ?? "?",
                       g.uplinkMaxDatagrams.map { "\($0)" } ?? "?", g.uplinkMaxSize.map { "\($0)" } ?? "?",
                       (config.utunBatch ?? true) ? "on" : "off by config"), level: .notice)
            publishModem()
            control = try dev.allocateClient(.wds)
            ensureModemAutoconnectOff()
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
        } catch {
            // The interface is opened exclusively: a device that failed setup (e.g. Sync timing
            // out while the firmware boots) must be closed, or every retry collides with it.
            if let dev = opened {
                // No PDN has been dialled yet at any throwing step, so there is nothing else to undo.
                wda = nil
                control = nil
                nas = nil
                profileCheck?.cancel()
                profileCheck = nil
                if device === dev { device = nil }
                dev.close()
            }
            deviceState = "absent"
            deviceError = "\(error)"
            publishModem()
            // "not found" is normal while the modem is away; failing to open a present
            // interface over and over is not.
            if !"\(error)".contains("not found") {
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
    private func deviceLost() {
        guard let dev = device else { return }
        log("modem went away", level: .notice)
        for p in pdns {
            p.retry?.cancel()
            p.retry = nil
            if p.config.oneShot { p.wanted = false }
            teardown(p, stopCall: false, state: "idle", error: "modem went away", reason: .modemLost)
        }
        wda = nil
        control = nil
        nas = nil
        psAttached = nil
        plmn = nil
        lteEmergency = NAS.LTEEmergency()
        plmnNITZ = nil
        plmnSPN = nil
        plmnPNN = nil
        plmnModem = nil
        sim = nil                                   // may be a different SIM when it comes back
        attach = nil
        applySIM()
        profileCheck?.cancel()
        profileCheck = nil
        dev.close()
        device = nil
        deviceState = "absent"
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
            p.state = "blocked"
            p.lastError = p.blockedSummary
            publishStatus(p)
            return settle(p)
        }
        guard psAttached != false else {
            p.retry?.cancel()
            p.retry = nil
            if p.config.oneShot { return stopOneShot(p, error: "not attached (\(serving))", reason: .notAttached) }
            // Dialled again when the Serving System indication reports PS attach.
            p.state = "waiting"
            p.lastError = "not attached (\(serving))"
            p.reason = QMIDReason.notAttached.rawValue
            p.ends = [:]
            publishStatus(p)
            return settle(p)
        }
        guard p.profileIndex != nil else {
            let error = "no modem profile for \(p.config.apn ?? p.config.name)"
            if p.config.oneShot { return stopOneShot(p, error: error, reason: .noProfile) }
            p.state = "backoff"
            p.lastError = p.lastError ?? error
            p.reason = p.reason ?? QMIDReason.noProfile.rawValue
            publishStatus(p)
            scheduleRedial(p)
            return settle(p)
        }
        p.retry?.cancel()
        p.retry = nil
        p.state = "dialing"
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
            let utun = try Utun()
            p.session = session
            p.utun = utun
            try utun.configure(session.merged)
            dev.modem.attachMux(p.muxID, fd: utun.fd)
            p.state = "connected"
            p.lastError = session.failures.isEmpty ? nil : session.failureSummary
            p.ends = session.ends
            p.attempts = 0
            p.connectedAt = Date()
            try publishService(p)
            log("\(p.config.name): connected on \(utun.name) (\(p.policy.rawValue)) " +
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
            teardown(p, stopCall: true, state: "backoff", error: summary, reason: reason, ends: session.ends)
            p.lastErrorDetail = session.failures.isEmpty ? nil : session.failureDetail
            applyPermanentCauses(p, session)
            if p.dialFamilies.isEmpty {
                p.state = "blocked"
                p.lastError = p.blockedSummary
                if !session.ends.values.contains(where: \.isAPNLevel) {   // that one was logged already
                    log("\(p.config.name): refused for every family; not retrying until reload or re-registration", level: .error)
                }
                publishStatus(p)
            } else {
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
        let result = p.state == "connected" ? nil : p.lastError ?? (p.state == "idle" ? "disconnected" : p.state)
        let waiters = p.waiters
        p.waiters = []
        waiters.forEach { $0(result) }
    }

    // A call that went down without a disconnect: redial (now, or after backoff); a one-shot
    // PDN (redial: false) stays down until the next connect.
    private func dropped(_ p: PDNState, stopCall: Bool, error: String, detail: String? = nil,
                         ends: [UInt8: WDS.CallEnd] = [:], now: Bool = false) {
        if p.config.oneShot {
            return stopOneShot(p, error: error, reason: .dropped, ends: ends, stopCall: stopCall, detail: detail)
        }
        teardown(p, stopCall: stopCall, state: "backoff", error: error, reason: .dropped, ends: ends)
        p.lastErrorDetail = detail
        guard now else { return scheduleRedial(p) }
        p.attempts = 0
        if p.wanted { dial(p) } else { p.state = "idle"; publishStatus(p) }
    }

    // A one-shot PDN that went down or couldn't be dialled: idle and not wanted.
    private func stopOneShot(_ p: PDNState, error: String, reason: QMIDReason, ends: [UInt8: WDS.CallEnd] = [:],
                             stopCall: Bool = true, detail: String? = nil) {
        p.wanted = false
        p.retry?.cancel()
        p.retry = nil
        teardown(p, stopCall: stopCall, state: "idle", error: error, reason: reason, ends: ends)
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
            guard let self, let p, p.state == "connected" else { return }
            self.stopOneShot(p, error: "max uptime reached (\(limit) s)", reason: .maxUptime)
        }
        p.uptimeLimit = item
        queue.asyncAfter(deadline: .now() + .seconds(limit), execute: item)
    }

    // A family refused with a permanent 3GPP cause is not retried until reload or re-registration.
    private func applyPermanentCauses(_ p: PDNState, _ session: PDNSession) {
        // A rejection of the APN itself (not subscribed, unknown, ...) holds for every family:
        // don't go on dialing the others, which the modem then only throttles.
        if let end = session.ends.values.first(where: \.isAPNLevel),
           p.config.families.contains(where: { p.blocked[$0] == nil }) {
            for f in p.config.families { p.blocked[f] = end.text }
            log("\(p.config.name): \(end); not retrying until the SIM, the registration or the config changes",
                level: .error)
            return
        }
        for (family, end) in session.ends where end.isPermanent && p.blocked[family] == nil {
            p.blocked[family] = end.text
            log("\(p.config.name): ipv\(family) blocked: \(end)", level: .error)
        }
    }

    private func teardown(_ p: PDNState, stopCall: Bool, state: String, error: String?,
                          reason: QMIDReason? = nil, ends: [UInt8: WDS.CallEnd] = [:]) {
        let cancelsDial = p.dialing != nil && !p.dialCancelled
        if p.dialing != nil {
            p.dialCancelled = true                  // dialed() stops its call
            p.dialAgain = false
        }
        p.uptimeLimit?.cancel()
        p.uptimeLimit = nil
        if let dev = device, p.utun != nil { dev.modem.detachMux(p.muxID) }
        publisher.remove(prefix: ServicePublisher.serviceKey(ServicePublisher.serviceID(for: p.config.name)))
        p.qosSnapshot?.cancel()
        p.qosSnapshot = nil
        p.qosSnapshotRunning = false
        p.qosSnapshotDone = false
        p.qosRetries = 0
        p.qosState = PDNQoS.State()
        p.qos?.close(release: stopCall)
        p.qos = nil
        if stopCall { p.session?.disconnect() }
        p.session = nil
        p.utun?.close()
        p.utun = nil
        p.connectedAt = nil
        p.state = state
        p.lastError = error
        p.lastErrorDetail = nil
        p.reason = reason?.rawValue
        p.ends = ends
        publishStatus(p)
        emitBearers(p)
        if cancelsDial { settle(p) }
    }

    // 2 s, 4 s, 8 s … capped at 5 min (PLAN.md §7). Permanent causes block instead (dial()).
    private func scheduleRedial(_ p: PDNState) {
        guard p.wanted else { p.state = "idle"; publishStatus(p); return }
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
                if p.qosSnapshotRunning { p.qosAMBRSince = true }   // newer than the snapshot's read
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
        if s.connection == 1, p.state == "connected" {
            let family = [UInt8(4), 6].first { p.session?.client(family: $0)?.id == m.clientID }
            dropped(p, stopCall: true, error: "dropped: \(s.callEnd.text)", detail: "dropped: \(s.callEnd)",
                    ends: family.map { [$0: s.callEnd] } ?? [:])
        } else if s.connection == 2, s.reconfigurationRequired, p.state == "connected" {
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
            refreshQoS(p)
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
    }

    private func servingChanged(_ s: NAS.ServingSystem, initial: Bool = false) {
        let rats = s.radioInterfaces.map(NAS.ServingSystem.radioName).joined(separator: "+")
        serving = "\(s.registrationName), ps \(s.psAttached ? "attached" : "detached")\(rats.isEmpty ? "" : ", \(rats)")"
        // Indications may leave out the current PLMN (TLV 0x12) when it hasn't changed.
        let current = s.registration != 1 ? nil : s.mcc.flatMap { mcc in s.mnc.map { (mcc: mcc, mnc: $0) } } ?? plmn
        let plmnChanged = current?.mcc != plmn?.mcc || current?.mnc != plmn?.mnc
        if plmnChanged {
            plmn = current
            lteEmergency = NAS.LTEEmergency()
            plmnNITZ = nil
            plmnSPN = nil
            plmnPNN = nil
            plmnModem = nil
            readPLMNName()
        }
        let was = psAttached
        psAttached = s.registration == 1 && s.psAttached
        // EMC BS comes with the attach: read it on attach and on a new network.
        if psAttached == true, plmnChanged || was != true || initial,
           let n = nas, let r = try? n.request(NAS.getSysInfo, timeout: 5) {
            setLTEEmergency(NAS.parseLTEEmergency(r), replace: true)
        }
        guard was != psAttached || initial else { return }
        log("network: \(serving)", level: .notice)
        publishModem()
        guard psAttached == true, !initial else { return }
        // (Re-)attached: a new SIM or carrier config may have changed profiles, and a family
        // blocked on the old registration may be allowed now.
        for p in pdns { p.blocked.removeAll() }
        checkSIM()
        syncProfiles()
        readAttach()
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
        return String(format: "%03d", p.mcc) + String(format: p.mnc > 99 ? "%03d" : "%02d", p.mnc)
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

    private func plmnInfo() -> [String: Any]? {
        guard let p = plmn else { return nil }
        var d: [String: Any] = [QMIDKey.mccmnc: String(format: "%03d", p.mcc) + String(format: p.mnc > 99 ? "%03d" : "%02d", p.mnc)]
        let n = shownName
        if let l = n.longName { d[QMIDKey.longName] = l }
        if let s = n.shortName { d[QMIDKey.shortName] = s }
        d[QMIDKey.nameFromNetwork] = plmnNITZ != nil
        if let b = lteEmergency.bearers { d[QMIDKey.emergencyBearers] = b }
        if let b = lteEmergency.accessBarred { d[QMIDKey.emergencyAccessBarred] = b }
        return d
    }

    private func plmnEvent() -> NSDictionary {
        var d: [String: Any] = [QMIDKey.type: QMIDEventType.plmn]
        if let p = plmnInfo() { d[QMIDKey.plmn] = p as NSDictionary }
        return d as NSDictionary
    }

    // MARK: - SIM (per-SIM attach APN, config "carriers")

    // Reads the SIM's home MCC/MNC and ICCID. A different SIM re-resolves the attach PDN for
    // the next profile sync. Keeps the last identity when the SIM can't be read.
    // Returns whether the identity changed (the attach PDN may resolve differently).
    @discardableResult
    private func checkSIM() -> Bool {
        guard let dev = device else { return false }
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
        id = id.merged(over: sim)
        guard id != sim else { return false }
        // Only a different card earns its own re-attach; the same card gaining its MCC/MNC
        // stays under the re-attach rate limit.
        if id.iccid != sim?.iccid {
            lastReattach = nil
            for p in pdns { p.blocked.removeAll() }   // rejections were the old SIM's
        }
        sim = id
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

    // Puts the SIM's attach PDN settings into the PDN states (see QMIDConfig.resolvedPDNs).
    private func applySIM() {
        let resolved = config.resolvedPDNs(for: sim)
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

    private func simInfo() -> [String: Any]? {
        guard let sim else { return nil }
        var d: [String: Any] = [:]
        if let m = sim.mccmnc { d[QMIDKey.mccmnc] = m }
        if let s = sim.iccidSuffix { d[QMIDKey.iccidSuffix] = s }
        if let m = config.carrier(for: sim) {
            d[QMIDKey.carrier] = m.carrier.name
            d[QMIDKey.matchedBy] = m.matchedBy
        }
        if let apn = attach?.apn, !apn.isEmpty { d[QMIDKey.attachAPN] = apn }
        if attach?.apn?.isEmpty == false { d[QMIDKey.attachAPNFromNetwork] = attachFromNetwork }
        return d
    }

    private func simEvent() -> NSDictionary {
        var d: [String: Any] = [QMIDKey.type: QMIDEventType.sim]
        if let s = simInfo() { d[QMIDKey.sim] = s as NSDictionary }
        return d as NSDictionary
    }

    // MARK: - Device arrival (IOKit)

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
                    .takeRetainedValue() as? NSNumber, v.intValue == Int(QMIDevice.quectelVendorID) {
                    n += 1
                }
                IOObjectRelease(s)
            }
            if n > 0 { me.deviceArrived() }
        }
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, match, callback, ctx, &arrivalIterator)
        while case let s = IOIteratorNext(arrivalIterator), s != 0 { IOObjectRelease(s) }   // arm
    }

    // Every interface of the modem arrives separately; one reopen, after they settle.
    private func deviceArrived() {
        guard device == nil else { return }
        // Each of the modem's interfaces arrives separately: log and schedule once per burst.
        if let last = lastArrival, Date().timeIntervalSince(last) < 5 { return }
        lastArrival = Date()
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
    // termination, no indications). Returns false if the device
    // was dropped.
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
        for p in pdns where p.state == "connected" {
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
        var report: [[String: Any]] = []
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
                var entry: [String: Any] = ["pdn": p.config.name]
                var wrote = false
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
                            lastSyncWrite = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                            wrote = true
                            try wds.request(WDS.modifyProfile, [WDS.profileIdentifier(i)] + want.settingTLVs)
                            log("\(p.config.name): profile \(i) updated (\(diffs.joined(separator: ", ")))")
                            changed.insert(i)
                            if i == attachIndex {
                                if diffs.contains(where: { $0.hasPrefix("pdp") }) { forceReattach = true }
                                else if diffs.contains(where: { $0.hasPrefix("apn:") }) { attachAPNChange = want.apn ?? "" }
                            }
                            entry["action"] = "updated: " + diffs.joined(separator: ", ")
                        } else {
                            entry["action"] = "in sync"
                        }
                    } else if let apn = p.config.apn {
                        // A pinned index ("profile": N) is requested through the PDP context number.
                        if let pinned = index { want.contextNumber = pinned }
                        lastSyncWrite = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                        wrote = true
                        let r = try wds.request(WDS.createProfile, [.u8(0x01, WDS.profileType3GPP)] + want.settingTLVs)
                        guard let i = WDS.parseCreatedProfileIndex(r) else { throw QMIHostError.transport("create profile: no index") }
                        if let pinned = index, pinned != i {
                            log("\(p.config.name): asked for profile \(pinned), modem created \(i)")
                        }
                        want.index = i
                        index = i
                        log("\(p.config.name): created profile \(i) for apn \(apn)")
                        changed.insert(i)
                        entry["action"] = "created"
                    } else {
                        p.lastError = "profile \(index.map(String.init) ?? "?") does not exist and no apn is configured"
                        entry["action"] = p.lastError
                    }
                } catch {
                    log("\(p.config.name): writing profile \(index.map(String.init) ?? "(new)") failed: \(error)", level: .error)
                    entry["action"] = "write failed: \(error)"
                    // A failed modify leaves the profile with its old settings; a failed create, none.
                    if let i = index, !profiles.contains(where: { $0.index == i }) { index = nil }
                }
                p.profileIndex = index
                if p.config.isAttach, let i = index, i != attachIndex {
                    do {
                        lastSyncWrite = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                        wrote = true
                        try wds.request(WDS.setLTEAttachPDNList, WDS.attachPDNListRequest([UInt16(i)]))
                        log("\(p.config.name): LTE attach profile \(attachIndex) → \(i)")
                        attachIndex = i
                        forceReattach = true
                    } catch {
                        log("\(p.config.name): could not make profile \(i) the LTE attach profile: \(error)", level: .error)
                    }
                }
                if let i = index { claimed.insert(i); entry["profile"] = Int(i); savedProfiles[p.config.name] = Int(i) }
                if index == attachIndex { entry["attach"] = true }
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
            if forceReattach {
                reattachLTE()
            } else if let apn = attachAPNChange {
                // Nothing to re-attach for when the default bearer already uses the new APN (the
                // network chose it, or the profile is being put back the way it was attached).
                let current = psAttached == false ? nil : (try? wds.request(WDS.getLTEAttachParameters, timeout: 5)).flatMap { WDS.parseAttachParameters($0).apn }
                if !apn.isEmpty, let current, current.lowercased() == apn.lowercased() {
                    log("default bearer already on apn \"\(current)\"; no re-attach needed")
                } else {
                    reattachLTE()
                }
            }
            for (i, e) in report.enumerated() {
                if let idx = e["profile"] as? Int, let pr = profiles.first(where: { $0.index == UInt8(idx) }) {
                    report[i]["settings"] = pr.summary
                }
            }
        } catch {
            log("profile sync failed: \(error)", level: .error)
            report.append(["error": "\(error)"])
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
        try dms.request(0x002E, [.u8(0x01, 0)], timeout: 20, accept: [.noEffect])
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
        lastReattach = Date()
        guard let dev = device else { return }
        log("attach APN changed; re-attaching (all PDNs drop briefly)", level: .notice)
        reattachStarted = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        do {
            let dms = try dev.allocateClient(.dms)
            defer { dms.release() }
            radioOff = true
            try dms.request(0x002E, [.u8(0x01, 1)], timeout: 20)      // low power
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
        for p in pdns where p.wanted && p.session == nil {
            p.attempts = 0
            dial(p)
        }
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
        let before = Dictionary(uniqueKeysWithValues: pdns.map { ($0.config.name, $0.profileIndex) })
        let changed = syncProfiles()
        for p in pdns {
            guard let i = p.profileIndex, changed.contains(i) || before[p.config.name] != i else { continue }
            if p.state == "connected" || p.state == "backoff" {
                p.retry?.cancel()
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
            out.append(e)
        } else {
            out.append(["sim": "not read yet"])
        }
        out += profileReport
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
            d = ServicePublisher.pdnStatus(name: p.config.name, interface: u.name, muxID: p.muxID,
                                           config: p.pdnConfig, settings: s.merged, policy: p.policy)
        } else {
            d = ["ServiceID": ServicePublisher.serviceID(for: p.config.name), "MuxID": Int(p.muxID),
                 "Policy": p.policy.rawValue]
        }
        d["State"] = p.state
        if let e = p.lastError { d["LastError"] = e }
        if p.qos != nil, let c = p.qosState.qci { d["QCI"] = Int(c) }
        if p.qos != nil, let a = p.qosState.ambr { d["AMBR"] = ["Uplink": NSNumber(value: a.uplink), "Downlink": NSNumber(value: a.downlink)] }
        try? publisher.publish([ServicePublisher.pdnKey(p.config.name): d])
        emitPDN(p)
        updateLinkAnchor()
    }

    // Keeps the stand-in interface up, with the families the connected internet PDN has.
    private func updateLinkAnchor() {
        var v4 = false, v6 = false
        if config.linkAnchor ?? true {
            for p in pdns where p.config.effectiveRole == "internet" && p.state == "connected" {
                if p.session?.merged.ipv4Address != nil { v4 = true }
                if p.session?.merged.ipv6Address != nil { v6 = true }
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

    // PDN dictionary for status() and events (keys: QMIDKey).
    private func pdnInfo(_ p: PDNState, counters: [String: NSNumber]? = nil) -> [String: Any] {
        var d: [String: Any] = [
            QMIDKey.name: p.config.name, QMIDKey.state: p.state, QMIDKey.policy: p.policy.rawValue,
            QMIDKey.role: p.config.effectiveRole, QMIDKey.mux: Int(p.muxID), QMIDKey.wanted: p.wanted,
            QMIDKey.serviceID: ServicePublisher.serviceID(for: p.config.name),
        ]
        if let i = p.profileIndex { d[QMIDKey.profile] = Int(i) }
        if let apn = p.config.apn { d[QMIDKey.apn] = apn }
        if let u = p.utun { d[QMIDKey.interface] = u.name }
        if let s = p.session?.merged {
            if let a = s.ipv4Address { d[QMIDKey.ipv4] = a.description }
            if let a = s.ipv6Address { d[QMIDKey.ipv6] = a.description }
            let dns = s.ipv4DNS.map(\.description) + s.ipv6DNS.map(\.description)
            if !dns.isEmpty { d[QMIDKey.dns] = dns }
            let pcscf = s.pcscfIPv4.map(\.description) + s.pcscfIPv6.map(\.description)
            if !pcscf.isEmpty { d[QMIDKey.pcscf] = pcscf }
            if let m = s.mtu { d[QMIDKey.mtu] = Int(m) }
            if let apn = s.apn { d[QMIDKey.apn] = apn }
        }
        if p.qos != nil {
            let q = p.qosState
            if let c = q.qci { d[QMIDKey.qci] = Int(c) }
            if let a = q.ambr {
                d[QMIDKey.ambr] = [QMIDKey.uplink: NSNumber(value: a.uplink), QMIDKey.downlink: NSNumber(value: a.downlink)]
            }
        }
        if let e = p.lastError { d[QMIDKey.error] = e }
        if let r = p.reason { d[QMIDKey.reason] = r }
        if !p.ends.isEmpty {
            d[QMIDKey.causes] = p.ends.sorted { $0.key < $1.key }.map { family, end -> [String: Any] in
                var c: [String: Any] = [QMIDKey.family: Int(family), QMIDKey.type: end.typeName]
                if let n = end.code { c[QMIDKey.code] = Int(n) }
                if let n = end.codeName { c[QMIDKey.name] = n }
                return c
            }
        }
        if !p.blocked.isEmpty { d[QMIDKey.blocked] = p.blocked.sorted { $0.key < $1.key }.map { "ipv\($0.key): \($0.value)" } }
        if let t = p.connectedAt { d[QMIDKey.uptime] = Int(Date().timeIntervalSince(t)) }
        if let c = counters { d[QMIDKey.counters] = c }
        return d
    }

    // Only real changes are pushed (uptime/counters change every second and are left out).
    private func emitPDN(_ p: PDNState) {
        var info = pdnInfo(p)
        info[QMIDKey.uptime] = nil
        let d = info as NSDictionary
        guard lastPDNEvent[p.config.name] != d else { return }
        lastPDNEvent[p.config.name] = d
        onEvent?([QMIDKey.type: QMIDEventType.pdn, QMIDKey.pdn: d] as NSDictionary)
    }

    // MARK: - QoS (default bearer QCI, AMBR, dedicated bearers)

    private func startQoS(_ p: PDNState, _ dev: QMIDevice) {
        guard let session = p.session else { return }
        p.qos = PDNQoS(device: dev, session: session, callbackQueue: queue, log: { [weak self] in self?.log($0) })
        snapshotQoS(p)
    }

    // After wake or a reconfiguration: reports may have been missed.
    private func refreshQoS(_ p: PDNState) { snapshotQoS(p) }

    // An Event Report for one of this PDN's bearers: applied as is, no query needed.
    private func applyQoSReport(_ p: PDNState, _ m: QMIMessage) {
        let change = PDNQoS.apply(m, to: p.qosState.bearers)
        // Also when the list doesn't change: a deletion of a bearer a running snapshot is
        // still reading must keep the snapshot from bringing it back.
        // The latest event per ID wins: a bearer recreated after a deletion isn't dropped.
        if p.qosSnapshotRunning {
            p.qosTouched.subtract(change.deleted)
            p.qosTouched.formUnion(change.touched)
            p.qosDeleted.subtract(change.touched)
            p.qosDeleted.formUnion(change.deleted)
        }
        guard change.bearers != p.qosState.bearers else { return }
        PDNQoS.changes(from: p.qosState.bearers, to: change.bearers).forEach { log("\(p.config.name): \($0)") }
        p.qosState.bearers = change.bearers
        emitBearers(p)
    }

    // A snapshot the modem didn't answer is retried after 2 s, up to 5 times in a row; the last
    // state stays meanwhile.
    private func snapshotQoS(_ p: PDNState) {
        guard let q = p.qos, !p.qosSnapshotRunning else { return }
        p.qosSnapshot?.cancel()
        p.qosSnapshot = nil
        p.qosSnapshotRunning = true
        p.qosTouched = []
        p.qosDeleted = []
        p.qosAMBRSince = false
        q.snapshot { [weak self, weak p] state in
            guard let self, let p, p.qos === q else { return }
            p.qosSnapshotRunning = false
            guard let state else {
                p.qosRetries += 1
                guard p.qosRetries <= 5 else { p.qosRetries = 0; self.log("\(p.config.name): qos: snapshot failed, giving up"); return }
                let item = DispatchWorkItem { [weak self, weak p] in if let self, let p { self.snapshotQoS(p) } }
                p.qosSnapshot = item
                self.queue.asyncAfter(deadline: .now() + 2, execute: item)
                return
            }
            let first = !p.qosSnapshotDone
            p.qosSnapshotDone = true
            p.qosRetries = 0
            let old = p.qosState
            var new = state
            if p.qosAMBRSince { new.ambr = old.ambr }        // the network changed it meanwhile
            new.bearers = PDNQoS.combine(snapshot: state.bearers, current: old.bearers,
                                         touchedSince: p.qosTouched, deletedSince: p.qosDeleted)
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
         QMIDKey.bearers: (p.qos != nil ? p.qosState.bearers : []).map(Self.bearerInfo)] as NSDictionary
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

    // Bearer dictionary for status() and events (keys: QMIDKey).
    static func bearerInfo(_ b: QoS.Bearer) -> NSDictionary {
        func rates(_ r: QoS.Bitrates) -> NSDictionary {
            var d: [String: Any] = [:]
            if let m = r.max { d[QMIDKey.max] = NSNumber(value: m) }
            if let g = r.guaranteed { d[QMIDKey.guaranteed] = NSNumber(value: g) }
            return d as NSDictionary
        }
        func filter(_ f: QoS.PacketFilter) -> NSDictionary {
            var d: [String: Any] = [QMIDKey.id: Int(f.id), QMIDKey.precedence: Int(f.precedence),
                                    QMIDKey.ipVersion: Int(f.ipVersion)]
            if let a = f.source { d[QMIDKey.source] = a.description }
            if let a = f.destination { d[QMIDKey.destination] = a.description }
            if let p = f.ipProtocol { d[QMIDKey.ipProtocol] = Int(p) }
            if let r = f.sourcePorts { d[QMIDKey.sourcePorts] = [Int(r.lowerBound), Int(r.upperBound)] }
            if let r = f.destinationPorts { d[QMIDKey.destinationPorts] = [Int(r.lowerBound), Int(r.upperBound)] }
            return d as NSDictionary
        }
        var d: [String: Any] = [
            QMIDKey.id: Int(b.qosID),
            QMIDKey.uplink: rates(b.uplink.rates), QMIDKey.downlink: rates(b.downlink.rates),
            QMIDKey.uplinkFilters: b.uplinkFilters.map(filter), QMIDKey.downlinkFilters: b.downlinkFilters.map(filter),
        ]
        if let q = b.qci { d[QMIDKey.qci] = Int(q) }
        if let n = b.networkInitiated { d[QMIDKey.networkInitiated] = n }
        return d as NSDictionary
    }

    private func modemEvent() -> NSDictionary {
        var d: [String: Any] = [QMIDKey.type: QMIDEventType.modem, QMIDKey.modem: deviceState]
        if !serving.isEmpty { d[QMIDKey.network] = serving }
        if let e = deviceError { d[QMIDKey.modemError] = e }
        return d as NSDictionary
    }

    // Current state as events, for a new subscriber.
    public func snapshotEvents() -> [NSDictionary] {
        [modemEvent(), simEvent(), plmnEvent()] + pdns.map {
            var info = pdnInfo($0)
            info[QMIDKey.uptime] = nil
            return [QMIDKey.type: QMIDEventType.pdn, QMIDKey.pdn: info as NSDictionary] as NSDictionary
        } + pdns.filter { $0.qos != nil }.map(bearersEvent)
    }

    private func publishModem() {
        var d: [String: Any] = ["State": deviceState]
        if !serving.isEmpty { d["Network"] = serving }
        if let dev = device {
            d["VendorID"] = Int(dev.modem.vendorID)
            d["ProductID"] = Int(dev.modem.productID)
            d["Interface"] = Int(dev.modem.interfaceNumber)
        }
        if let e = deviceError { d["LastError"] = e }
        if let s = simInfo() { d["SIM"] = s }
        if let p = plmnInfo() { d["PLMN"] = p }
        try? publisher.publish([ServicePublisher.modemKey: d])
        let ev = modemEvent()
        if lastModemEvent != ev {
            lastModemEvent = ev
            onEvent?(ev)
        }
        let se = simEvent()
        if lastSIMEvent != se {
            lastSIMEvent = se
            onEvent?(se)
        }
        let pe = plmnEvent()
        if lastPLMNEvent != pe {
            lastPLMNEvent = pe
            onEvent?(pe)
        }
    }

    // MARK: - Control (called on `queue`)

    public func status() -> NSDictionary {
        let stats = device?.modem.statistics() ?? [:]
        let list = pdns.map {
            var d = pdnInfo($0, counters: stats[NSNumber(value: $0.muxID)])
            if $0.qos != nil { d[QMIDKey.bearers] = $0.qosState.bearers.map(Self.bearerInfo) }
            return d
        }
        var out: [String: Any] = [QMIDKey.apiVersion: qmidAPIVersion, QMIDKey.modem: deviceState, QMIDKey.pdns: list]
        if let v = version { out[QMIDKey.version] = v }
        if !serving.isEmpty { out[QMIDKey.network] = serving }
        if let e = deviceError { out[QMIDKey.modemError] = e }
        if let g = stats[0] { out[QMIDKey.datapath] = g }
        if let s = simInfo() { out[QMIDKey.sim] = s }
        if let p = plmnInfo() { out[QMIDKey.plmn] = p }
        return out as NSDictionary
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
            if p.config.oneShot { return reply("modem not ready (\(deviceState))") }
            p.wanted = true
            return reply("modem not ready (\(deviceState)); will connect when it is")
        }
        p.wanted = true
        if p.state == "connected" {
            armUptimeLimit(p)
            return reply(nil)
        }
        p.waiters.append(reply)
        dial(p)
    }

    public func disconnect(_ name: String) -> String? {
        guard let p = pdns.first(where: { $0.config.name == name }) else { return "no PDN \(name)" }
        p.wanted = false
        p.retry?.cancel()
        p.retry = nil
        teardown(p, stopCall: true, state: "idle", error: nil)
        log("\(name): disconnected by request", level: .notice)
        return nil
    }

    // Re-publishes the service entity only; no reconnect (PLAN.md §5.2).
    public func setPolicy(_ name: String, _ policy: String) -> String? {
        guard let p = pdns.first(where: { $0.config.name == name }) else { return "no PDN \(name)" }
        guard let pol = ServicePublisher.Policy(rawValue: policy) else {
            return "bad policy \(policy) (\(ServicePublisher.Policy.allCases.map(\.rawValue).joined(separator: ", ")))"
        }
        p.policy = pol
        do {
            if p.state == "connected" { try publishService(p) } else { publishStatus(p) }
        } catch {
            return "\(error)"
        }
        log("\(name): policy \(pol.rawValue)")
        return nil
    }

    // Re-reads the config and rebuilds the PDN set.
    public func reload() -> String? {
        let c: QMIDConfig
        do { c = try QMIDConfig.load(path: configPath) } catch { return "\(error)" }
        for p in pdns {
            p.retry?.cancel()
            teardown(p, stopCall: true, state: "idle", error: nil)
            publisher.remove(prefix: ServicePublisher.pdnKey(p.config.name))
        }
        config = c
        if device != nil { checkSIM() }             // resolve against the SIM in the modem now
        pdns = Self.makeStates(c.resolvedPDNs(for: sim))
        lastReattach = nil                          // a deliberate change may re-attach at once
        outsideEdits = []
        outsideEditsHalted = false
        lastPDNEvent = lastPDNEvent.filter { name, _ in c.pdns.contains { $0.name == name } }
        log("config reloaded: \(c.pdns.map(\.name).joined(separator: ", "))")
        if device != nil { syncProfiles() }
        onEvent?([QMIDKey.type: QMIDEventType.config] as NSDictionary)
        for p in pdns {
            publishStatus(p)
            if p.wanted, device != nil { dial(p) }
        }
        return nil
    }

    // Clean shutdown: stop calls, release clients, remove every key.
    public func shutdown() {
        if radioOff, let dev = device { try? radioOnline(dev) }   // don't exit with the radio off
        for p in pdns {
            p.retry?.cancel()
            teardown(p, stopCall: true, state: "idle", error: nil)
        }
        wda?.release()
        control?.release()
        device?.close()
        device = nil
        publisher.removeAll()
        LinkAnchor.down()
        linkAnchor = (false, false)
    }
}
