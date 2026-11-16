import Foundation

// Typed views of qmid's dictionaries. Unknown keys are ignored and missing optional keys
// stay nil, so newer or older qmid versions decode fine. qmid builds its dictionaries from the
// same types (`dictionary`), so both sides share one definition of every key.

// The modem as qmid sees it (QMIDKey.modem).
public enum QMIDModemState: String {
    case absent, opening, ready
}

// How the system ranks a PDN's network service against Wi-Fi and Ethernet (QMIDKey.policy,
// setPolicy, the config's "policy").
public enum QMIDPolicy: String, CaseIterable {
    case preferWifi = "prefer-wifi"
    case preferCellular = "prefer-cellular"
    case lastResort = "last-resort"
    case never = "never"
}

public struct QMIDPDN: Equatable {
    public enum State: String {
        case idle, waiting, dialing, connected, backoff, blocked
    }

    public var name: String
    public var state: State?
    public var stateName: String
    public var policy: String?            // QMIDPolicy raw value; see policyKind
    public var role: String?
    public var interface: String?
    public var ipv4: String?
    public var ipv6: String?          // "addr/prefix"
    public var dns: [String]
    public var pcscf: [String]
    public var mtu: Int?
    public var profile: Int?
    public var apn: String?
    public var serviceID: String?
    public var mux: Int?
    public var wanted: Bool
    public var uptime: Int?
    public var error: String?
    public var blocked: [String]
    public var reason: QMIDReason?        // `error` as a word; nil without an error or for a newer reason
    public var causes: [QMIDCause]        // `error`'s call end causes, per family; [] when none
    public var qci: Int?                  // default bearer's QCI, while connected
    public var ambr: QMIDAMBR?            // APN-AMBR, while connected (when the modem reports it)
    // Dedicated bearers: only in status() (nil in "pdn" events; those come through onBearers).
    public var bearers: [QMIDBearer]?
    // Redialing right after a drop with its interface, network service and stand-in interface
    // kept (state dialing/backoff/waiting, `interface` set): a stall, not the link going away.
    public var linkHeld: Bool
    // While connected: the technology its data goes over, as QMIDBandPreference.modes names
    // ("nr", "lte", …). Per PDN: in EN-DC one APN can be on the NR leg while another stays on LTE.
    public var rat: String?

    public var isConnected: Bool { state == .connected }
    public var policyKind: QMIDPolicy? { policy.flatMap(QMIDPolicy.init(rawValue:)) }

    // IPv6 address without the prefix length, for binding sockets.
    public var ipv6Address: String? { ipv6.map { String($0.split(separator: "/").first ?? Substring($0)) } }

    public init(name: String, state: State) {
        self.name = name
        self.state = state
        stateName = state.rawValue
        dns = []
        pcscf = []
        wanted = true
        blocked = []
        causes = []
        linkHeld = false
    }

    public init?(_ d: NSDictionary) {
        guard let name = d[QMIDKey.name] as? String else { return nil }
        self.name = name
        stateName = d[QMIDKey.state] as? String ?? "unknown"
        state = State(rawValue: stateName)
        policy = d[QMIDKey.policy] as? String
        role = d[QMIDKey.role] as? String
        interface = d[QMIDKey.interface] as? String
        ipv4 = d[QMIDKey.ipv4] as? String
        ipv6 = d[QMIDKey.ipv6] as? String
        dns = d[QMIDKey.dns] as? [String] ?? []
        pcscf = d[QMIDKey.pcscf] as? [String] ?? []
        mtu = d[QMIDKey.mtu] as? Int
        profile = d[QMIDKey.profile] as? Int
        apn = d[QMIDKey.apn] as? String
        serviceID = d[QMIDKey.serviceID] as? String
        mux = d[QMIDKey.mux] as? Int
        wanted = d[QMIDKey.wanted] as? Bool ?? true
        uptime = d[QMIDKey.uptime] as? Int
        error = d[QMIDKey.error] as? String
        blocked = d[QMIDKey.blocked] as? [String] ?? []
        reason = (d[QMIDKey.reason] as? String).flatMap(QMIDReason.init(rawValue:))
        causes = (d[QMIDKey.causes] as? [NSDictionary] ?? []).compactMap(QMIDCause.init)
        qci = d[QMIDKey.qci] as? Int
        ambr = QMIDAMBR(d[QMIDKey.ambr] as? NSDictionary)
        bearers = (d[QMIDKey.bearers] as? [NSDictionary]).map { $0.compactMap(QMIDBearer.init) }
        linkHeld = d[QMIDKey.linkHeld] as? Bool ?? false
        rat = d[QMIDKey.rat] as? String
    }

    public var dictionary: NSDictionary {
        var d: [String: Any] = [QMIDKey.name: name, QMIDKey.state: state?.rawValue ?? stateName,
                                QMIDKey.wanted: wanted, QMIDKey.linkHeld: linkHeld]
        d[QMIDKey.policy] = policy
        d[QMIDKey.role] = role
        d[QMIDKey.interface] = interface
        d[QMIDKey.ipv4] = ipv4
        d[QMIDKey.ipv6] = ipv6
        if !dns.isEmpty { d[QMIDKey.dns] = dns }
        if !pcscf.isEmpty { d[QMIDKey.pcscf] = pcscf }
        d[QMIDKey.mtu] = mtu
        d[QMIDKey.profile] = profile
        d[QMIDKey.apn] = apn
        d[QMIDKey.serviceID] = serviceID
        d[QMIDKey.mux] = mux
        d[QMIDKey.uptime] = uptime
        d[QMIDKey.error] = error
        if !blocked.isEmpty { d[QMIDKey.blocked] = blocked }
        d[QMIDKey.reason] = reason?.rawValue
        if !causes.isEmpty { d[QMIDKey.causes] = causes.map(\.dictionary) }
        d[QMIDKey.qci] = qci
        d[QMIDKey.ambr] = ambr?.dictionary
        d[QMIDKey.bearers] = bearers?.map(\.dictionary)
        d[QMIDKey.rat] = rat
        return d as NSDictionary
    }
}

// Why a PDN isn't up, as a word (QMIDPDN.reason); `error` has it in words.
public enum QMIDReason: String {
    case notAttached = "not-attached"   // the modem isn't attached to a network (PS detached)
    case noProfile = "no-profile"       // no modem profile for the PDN
    case rejected                       // the network or the modem ended the call: see `causes`
    case failed                         // the dial failed without a cause (e.g. a timeout)
    case dropped                        // went down after connecting (`causes` when the modem said why)
    case maxUptime = "max-uptime"       // hung up after the config's maxUptime
    case modemLost = "modem-lost"       // the modem went away
    case airplaneMode = "airplane-mode" // waiting: the modem's radio is off
}

// One family's call end cause.
public struct QMIDCause: Equatable {
    public var family: Int?             // 4 | 6
    public var type: String             // "3GPP" (TS 24.301 ESM cause), "internal", "CM", … or "call end reason"
    public var code: Int?
    public var name: String?            // official name, when known

    public var is3GPP: Bool { type == "3GPP" }

    public init(type: String, family: Int? = nil, code: Int? = nil, name: String? = nil) {
        self.type = type
        self.family = family
        self.code = code
        self.name = name
    }

    public init?(_ d: NSDictionary) {
        guard let type = d[QMIDKey.type] as? String else { return nil }
        self.type = type
        family = d[QMIDKey.family] as? Int
        code = d[QMIDKey.code] as? Int
        name = d[QMIDKey.name] as? String
    }

    public var dictionary: NSDictionary {
        var d: [String: Any] = [QMIDKey.type: type]
        d[QMIDKey.family] = family
        d[QMIDKey.code] = code
        d[QMIDKey.name] = name
        return d as NSDictionary
    }
}

private func u64(_ v: Any?) -> UInt64? { (v as? NSNumber)?.uint64Value }

// APN-AMBR of a PDN, bits per second.
public struct QMIDAMBR: Equatable {
    public var uplink: UInt64
    public var downlink: UInt64

    public init(uplink: UInt64, downlink: UInt64) { self.uplink = uplink; self.downlink = downlink }

    public init?(_ d: NSDictionary?) {
        guard let d, let ul = u64(d[QMIDKey.uplink]), let dl = u64(d[QMIDKey.downlink]) else { return nil }
        uplink = ul
        downlink = dl
    }

    public var dictionary: NSDictionary {
        [QMIDKey.uplink: NSNumber(value: uplink), QMIDKey.downlink: NSNumber(value: downlink)]
    }
}

// One direction of a bearer, bits per second; nil where the network set no value
// (guaranteed is nil on non-GBR bearers).
public struct QMIDBitrates: Equatable {
    public var max: UInt64?
    public var guaranteed: UInt64?

    public init(max: UInt64? = nil, guaranteed: UInt64? = nil) { self.max = max; self.guaranteed = guaranteed }

    init(_ d: NSDictionary?) {
        max = u64(d?[QMIDKey.max])
        guaranteed = u64(d?[QMIDKey.guaranteed])
    }

    public var dictionary: NSDictionary {
        var d: [String: Any] = [:]
        d[QMIDKey.max] = max.map { NSNumber(value: $0) }
        d[QMIDKey.guaranteed] = guaranteed.map { NSNumber(value: $0) }
        return d as NSDictionary
    }
}

// One packet filter of a bearer's TFT. Unset fields match anything.
public struct QMIDPacketFilter: Equatable {
    public var id: Int                    // 3GPP packet filter identifier, 0–15
    public var precedence: Int            // lower is evaluated first
    public var ipVersion: Int             // 4 or 6
    public var source: String?            // "203.0.113.0/27", "2001:db8:0:c0::/59"
    public var destination: String?
    public var ipProtocol: Int?           // 6 TCP, 17 UDP, …
    public var sourcePorts: ClosedRange<Int>?
    public var destinationPorts: ClosedRange<Int>?

    public init(id: Int, precedence: Int, ipVersion: Int) {
        self.id = id
        self.precedence = precedence
        self.ipVersion = ipVersion
    }

    public init?(_ d: NSDictionary) {
        guard let id = d[QMIDKey.id] as? Int, let p = d[QMIDKey.precedence] as? Int,
              let v = d[QMIDKey.ipVersion] as? Int else { return nil }
        func range(_ k: String) -> ClosedRange<Int>? {
            guard let a = d[k] as? [Int], a.count == 2, a[0] <= a[1] else { return nil }
            return a[0]...a[1]
        }
        self.id = id
        precedence = p
        ipVersion = v
        source = d[QMIDKey.source] as? String
        destination = d[QMIDKey.destination] as? String
        ipProtocol = d[QMIDKey.ipProtocol] as? Int
        sourcePorts = range(QMIDKey.sourcePorts)
        destinationPorts = range(QMIDKey.destinationPorts)
    }

    public var dictionary: NSDictionary {
        var d: [String: Any] = [QMIDKey.id: id, QMIDKey.precedence: precedence, QMIDKey.ipVersion: ipVersion]
        d[QMIDKey.source] = source
        d[QMIDKey.destination] = destination
        d[QMIDKey.ipProtocol] = ipProtocol
        d[QMIDKey.sourcePorts] = sourcePorts.map { [$0.lowerBound, $0.upperBound] }
        d[QMIDKey.destinationPorts] = destinationPorts.map { [$0.lowerBound, $0.upperBound] }
        return d as NSDictionary
    }
}

// A dedicated EPS bearer of a PDN, as the network set it up.
public struct QMIDBearer: Equatable {
    public var id: Int                    // opaque; stable while the bearer lives, new after re-creation
    public var qci: Int?
    public var networkInitiated: Bool?    // nil: the modem didn't say
    public var uplink: QMIDBitrates
    public var downlink: QMIDBitrates
    public var uplinkFilters: [QMIDPacketFilter]
    public var downlinkFilters: [QMIDPacketFilter]

    public var isGBR: Bool { uplink.guaranteed != nil || downlink.guaranteed != nil }

    public init(id: Int, qci: Int? = nil, networkInitiated: Bool? = nil, uplink: QMIDBitrates = .init(),
                downlink: QMIDBitrates = .init(), uplinkFilters: [QMIDPacketFilter] = [],
                downlinkFilters: [QMIDPacketFilter] = []) {
        self.id = id
        self.qci = qci
        self.networkInitiated = networkInitiated
        self.uplink = uplink
        self.downlink = downlink
        self.uplinkFilters = uplinkFilters
        self.downlinkFilters = downlinkFilters
    }

    public init?(_ d: NSDictionary) {
        guard let id = d[QMIDKey.id] as? Int else { return nil }
        self.id = id
        qci = d[QMIDKey.qci] as? Int
        networkInitiated = d[QMIDKey.networkInitiated] as? Bool
        uplink = QMIDBitrates(d[QMIDKey.uplink] as? NSDictionary)
        downlink = QMIDBitrates(d[QMIDKey.downlink] as? NSDictionary)
        uplinkFilters = (d[QMIDKey.uplinkFilters] as? [NSDictionary] ?? []).compactMap(QMIDPacketFilter.init)
        downlinkFilters = (d[QMIDKey.downlinkFilters] as? [NSDictionary] ?? []).compactMap(QMIDPacketFilter.init)
    }

    public var dictionary: NSDictionary {
        var d: [String: Any] = [
            QMIDKey.id: id, QMIDKey.uplink: uplink.dictionary, QMIDKey.downlink: downlink.dictionary,
            QMIDKey.uplinkFilters: uplinkFilters.map(\.dictionary), QMIDKey.downlinkFilters: downlinkFilters.map(\.dictionary),
        ]
        d[QMIDKey.qci] = qci
        d[QMIDKey.networkInitiated] = networkInitiated
        return d as NSDictionary
    }
}

// The SIM qmid identified and how the default internet bearer follows it (config "carriers").
public struct QMIDSIM: Equatable {
    public var mccmnc: String?            // home PLMN, "00101" / "001001"
    public var iccidSuffix: String?       // "…1234"
    public var carrier: String?           // matching "carriers" entry; nil: none matched (or none configured)
    public var matchedBy: String?         // "iccid 8900" | "mccmnc 00101"
    public var attachAPN: String?         // APN of the default bearer as attached
    public var attachAPNFromNetwork: Bool // the network chose attachAPN (empty APN in the attach profile)
    public var pendingSIM: String?        // "…1234": a prepareSIM card not in yet
    // Identities: in XPC replies and events only, never in SCDynamicStore (readable by any
    // local user).
    public var iccid: String?             // full ICCID
    public var imsi: String?              // nil until the PIN is verified
    public var msisdn: String?            // own number as stored on the SIM; many SIMs have none
    public var card: CardState?
    public var pin: PINState?             // PIN1 of the USIM (or the universal PIN)
    public var pinRetries: Int?
    public var pukRetries: Int?

    public enum CardState: String { case present, absent, error }

    public enum PINState: String {
        case disabled                     // no PIN asked
        case verified                     // PIN entered
        case required                     // PIN needed before the SIM works
        case pukRequired = "puk-required" // PIN blocked: PUK needed
        case blocked                      // PUK blocked too: the card is unusable
        case unknown
    }

    // The SIM can't be used until someone enters its PIN or PUK.
    public var isLocked: Bool { pin == .required || pin == .pukRequired || pin == .blocked }

    public init(mccmnc: String? = nil, iccidSuffix: String? = nil) {
        self.mccmnc = mccmnc
        self.iccidSuffix = iccidSuffix
        attachAPNFromNetwork = false
    }

    public init?(_ d: NSDictionary?) {
        guard let d, d[QMIDKey.mccmnc] != nil || d[QMIDKey.iccidSuffix] != nil || d[QMIDKey.card] != nil else { return nil }
        mccmnc = d[QMIDKey.mccmnc] as? String
        iccidSuffix = d[QMIDKey.iccidSuffix] as? String
        carrier = d[QMIDKey.carrier] as? String
        matchedBy = d[QMIDKey.matchedBy] as? String
        attachAPN = d[QMIDKey.attachAPN] as? String
        attachAPNFromNetwork = d[QMIDKey.attachAPNFromNetwork] as? Bool ?? false
        pendingSIM = d[QMIDKey.pendingSIM] as? String
        iccid = d[QMIDKey.iccid] as? String
        imsi = d[QMIDKey.imsi] as? String
        msisdn = d[QMIDKey.msisdn] as? String
        card = (d[QMIDKey.card] as? String).flatMap(CardState.init)
        pin = (d[QMIDKey.pin] as? String).map { PINState(rawValue: $0) ?? .unknown }
        pinRetries = d[QMIDKey.pinRetries] as? Int
        pukRetries = d[QMIDKey.pukRetries] as? Int
    }

    public var dictionary: NSDictionary {
        var d: [String: Any] = [:]
        d[QMIDKey.iccid] = iccid
        d[QMIDKey.imsi] = imsi
        d[QMIDKey.msisdn] = msisdn
        d[QMIDKey.card] = card?.rawValue
        d[QMIDKey.pin] = pin?.rawValue
        d[QMIDKey.pinRetries] = pinRetries
        d[QMIDKey.pukRetries] = pukRetries
        d[QMIDKey.mccmnc] = mccmnc
        d[QMIDKey.iccidSuffix] = iccidSuffix
        d[QMIDKey.carrier] = carrier
        d[QMIDKey.matchedBy] = matchedBy
        d[QMIDKey.attachAPN] = attachAPN
        if attachAPN != nil { d[QMIDKey.attachAPNFromNetwork] = attachAPNFromNetwork }
        d[QMIDKey.pendingSIM] = pendingSIM
        return d as NSDictionary
    }
}

// prepareSIM's reply: what the prepared card's first attach will use.
public struct QMIDPreparedSIM: Equatable {
    public var apn: String                // attach APN; "" = the network's choice
    public var carrier: String?           // matching "carriers" entry
    public var matchedBy: String?         // "iccid 8900" | "mccmnc 00101"

    public init(apn: String, carrier: String? = nil, matchedBy: String? = nil) {
        self.apn = apn
        self.carrier = carrier
        self.matchedBy = matchedBy
    }

    public init(_ d: NSDictionary) {
        apn = d[QMIDKey.apn] as? String ?? ""
        carrier = d[QMIDKey.carrier] as? String
        matchedBy = d[QMIDKey.matchedBy] as? String
    }

    public var dictionary: NSDictionary {
        var d: [String: Any] = [QMIDKey.apn: apn]
        d[QMIDKey.carrier] = carrier
        d[QMIDKey.matchedBy] = matchedBy
        return d as NSDictionary
    }
}

// The network the modem is registered on and its operator names. Each name from the first
// source that has one: the network (NITZ), the SIM's service provider name (home network
// only), the SIM's name for the network (EF_OPL/EF_PNN), the modem's operator table.
// nameFromNetwork: the network sent names for this PLMN. Both names can be nil.
public struct QMIDPLMN: Equatable {
    public var mccmnc: String             // registered PLMN, "00101"
    public var longName: String?          // "Example Mobile Network"
    public var shortName: String?         // "ExampleNet"
    public var nameFromNetwork: Bool
    // LTE: the network supports emergency bearers (EMC BS, from the Attach/TAU Accept); a UE
    // shouldn't request an emergency PDN when it's false. nil when the modem doesn't say.
    public var emergencyBearers: Bool?
    public var emergencyAccessBarred: Bool?
    public var roaming: Bool?             // the modem's roaming indicator; nil when it doesn't say

    // Long name, else short name; nil when there is neither (don't show the MCC/MNC instead).
    public var displayName: String? { longName ?? shortName }

    public init(mccmnc: String, longName: String? = nil, shortName: String? = nil, nameFromNetwork: Bool = false) {
        self.mccmnc = mccmnc
        self.longName = longName
        self.shortName = shortName
        self.nameFromNetwork = nameFromNetwork
    }

    public init?(_ d: NSDictionary?) {
        guard let d, let m = d[QMIDKey.mccmnc] as? String else { return nil }
        mccmnc = m
        longName = d[QMIDKey.longName] as? String
        shortName = d[QMIDKey.shortName] as? String
        nameFromNetwork = d[QMIDKey.nameFromNetwork] as? Bool ?? false
        emergencyBearers = d[QMIDKey.emergencyBearers] as? Bool
        emergencyAccessBarred = d[QMIDKey.emergencyAccessBarred] as? Bool
        roaming = d[QMIDKey.roaming] as? Bool
    }

    public var dictionary: NSDictionary {
        var d: [String: Any] = [QMIDKey.mccmnc: mccmnc, QMIDKey.nameFromNetwork: nameFromNetwork]
        d[QMIDKey.longName] = longName
        d[QMIDKey.shortName] = shortName
        d[QMIDKey.emergencyBearers] = emergencyBearers
        d[QMIDKey.emergencyAccessBarred] = emergencyAccessBarred
        d[QMIDKey.roaming] = roaming
        return d as NSDictionary
    }
}

public struct QMIDStatus: Equatable {
    public var apiVersion: Int?
    public var version: String?
    public var modem: String              // QMIDModemState raw value; see modemState
    public var modemError: String?
    public var network: String?
    public var pdns: [QMIDPDN]
    public var sim: QMIDSIM?
    public var plmn: QMIDPLMN?
    public var imei: String?
    public var airplaneMode: Bool
    public var gnss: QMIDGNSS?
    public var sharing: QMIDSharing?          // nil unless config "sharing" is set

    public var modemState: QMIDModemState? { QMIDModemState(rawValue: modem) }
    public var isModemReady: Bool { modemState == .ready }
    public func pdn(_ name: String) -> QMIDPDN? { pdns.first { $0.name == name } }

    public init(_ d: NSDictionary) {
        apiVersion = d[QMIDKey.apiVersion] as? Int
        version = d[QMIDKey.version] as? String
        modem = d[QMIDKey.modem] as? String ?? "unknown"
        modemError = d[QMIDKey.modemError] as? String
        network = d[QMIDKey.network] as? String
        pdns = (d[QMIDKey.pdns] as? [NSDictionary] ?? []).compactMap(QMIDPDN.init)
        sim = QMIDSIM(d[QMIDKey.sim] as? NSDictionary)
        plmn = QMIDPLMN(d[QMIDKey.plmn] as? NSDictionary)
        imei = d[QMIDKey.imei] as? String
        airplaneMode = d[QMIDKey.airplaneMode] as? Bool ?? false
        gnss = (d[QMIDKey.gnss] as? NSDictionary).map(QMIDGNSS.init)
        sharing = (d[QMIDKey.sharing] as? NSDictionary).flatMap(QMIDSharing.init)
    }
}

public enum QMIDEvent: Equatable {
    case modem(state: String, network: String?, error: String?)
    case pdn(QMIDPDN)
    case config
    case unknown(type: String)

    public init?(_ d: NSDictionary) {
        guard let type = d[QMIDKey.type] as? String else { return nil }
        switch type {
        case QMIDEventType.modem:
            self = .modem(state: d[QMIDKey.modem] as? String ?? "unknown",
                          network: d[QMIDKey.network] as? String, error: d[QMIDKey.modemError] as? String)
        case QMIDEventType.pdn:
            guard let p = (d[QMIDKey.pdn] as? NSDictionary).flatMap(QMIDPDN.init) else { return nil }
            self = .pdn(p)
        case QMIDEventType.config:
            self = .config
        default:
            self = .unknown(type: type)
        }
    }
}

public struct QMIDError: Error, CustomStringConvertible, Equatable {
    public var message: String
    // connect: the PDN as the failed attempt left it (reason, causes); nil for other calls.
    public var pdn: QMIDPDN?
    public init(_ message: String) { self.message = message }
    public var description: String { message }

    // Explains an XPC connection error. qmid (launched on demand) refusing the caller's code
    // signature shows up as an interrupted connection; a missing service as an invalid one.
    public init(xpc error: Error) {
        let e = error as NSError
        switch (e.domain, e.code) {
        case (NSCocoaErrorDomain, NSXPCConnectionInterrupted):
            message = "qmid closed the connection: the caller must be signed by the same team as qmid "
                + "(or run as root), or qmid just restarted"
        case (NSCocoaErrorDomain, NSXPCConnectionInvalid):
            message = "qmid isn't available: not installed, or not approved in Login Items "
                + "(launchctl print system/\(qmidMachService))"
        default:
            message = "qmid: \(e.localizedDescription)"
        }
    }
}

public struct QMIDLogEntry: Equatable {
    public var time: Date
    public var level: QMIDLogLevel
    public var category: String
    public var message: String

    public init(time: Date, level: QMIDLogLevel, category: String, message: String) {
        self.time = time
        self.level = level
        self.category = category
        self.message = message
    }

    public init?(_ d: NSDictionary) {
        guard let t = d[QMIDKey.time] as? Double, let m = d[QMIDKey.message] as? String else { return nil }
        time = Date(timeIntervalSince1970: t)
        level = (d[QMIDKey.level] as? Int).flatMap(QMIDLogLevel.init(rawValue:)) ?? .info
        category = d[QMIDKey.category] as? String ?? "qmid"
        message = m
    }

    public var dictionary: NSDictionary {
        [QMIDKey.time: time.timeIntervalSince1970, QMIDKey.level: level.rawValue,
         QMIDKey.category: category, QMIDKey.message: message]
    }
}

// qmid's log levels, lowest first. `debug` is the QMI message trace.
public enum QMIDLogLevel: Int, Comparable, CaseIterable {
    case debug, info, notice, error

    public var name: String { String(describing: self) }
    public init?(name: String) { self.init(rawValue: Self.allCases.firstIndex { $0.name == name } ?? -1) }
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

// radio(): the cells the modem is using and sees. Serving cells first (primary, then
// secondary: LTE carrier aggregation and the NR leg of EN-DC), then neighbours. A snapshot
// read when asked; values the modem didn't report are nil.
public struct QMIDRadio: Equatable {
    public var cells: [QMIDCell]
    public var endcAvailable: Bool?       // the LTE cell offers EN-DC (NR as a secondary leg)
    public var raw: [String]?             // radio(raw: true): the modem's TLVs, "0x0043 0x13: 00 15 …"

    public var serving: [QMIDCell] { cells.filter { $0.role != .neighbor } }
    public var neighbors: [QMIDCell] { cells.filter { $0.role == .neighbor } }

    public init(cells: [QMIDCell] = [], endcAvailable: Bool? = nil, raw: [String]? = nil) {
        self.cells = cells
        self.endcAvailable = endcAvailable
        self.raw = raw
    }

    public init(_ d: NSDictionary) {
        cells = (d[QMIDKey.cells] as? [NSDictionary] ?? []).compactMap(QMIDCell.init)
        endcAvailable = d[QMIDKey.endcAvailable] as? Bool
        raw = d[QMIDKey.raw] as? [String]
    }

    public var dictionary: NSDictionary {
        var d: [String: Any] = [QMIDKey.cells: cells.map(\.dictionary)]
        d[QMIDKey.endcAvailable] = endcAvailable
        d[QMIDKey.raw] = raw
        return d as NSDictionary
    }
}

public struct QMIDCell: Equatable {
    public enum RAT: String { case lte, nr }
    public enum Role: String { case primary, secondary, neighbor }

    public var rat: RAT
    public var role: Role
    public var channel: Int?              // EARFCN / NR-ARFCN (downlink)
    public var band: Int?                 // 3GPP band number: 3 for B3, 41 for n41
    public var pci: Int?
    public var cellID: UInt64?            // ECI (28 bits: eNB ID << 8 | cell) / NCI (36 bits)
    public var tac: Int?
    public var bandwidth: Double?         // MHz, downlink
    public var rsrp: Double?              // dBm
    public var rsrq: Double?              // dB
    public var rssi: Double?              // dBm
    public var snr: Double?               // dB
    public var active: Bool?              // secondary cell: activated; false = configured only
    public var scellIndex: Int?           // LTE secondary cell: the RRC sCellIndex (1–7)

    public init(rat: RAT, role: Role) {
        self.rat = rat
        self.role = role
    }

    public init?(_ d: NSDictionary) {
        guard let rat = (d[QMIDKey.rat] as? String).flatMap(RAT.init),
              let role = (d[QMIDKey.role] as? String).flatMap(Role.init) else { return nil }
        self.rat = rat
        self.role = role
        channel = d[QMIDKey.channel] as? Int
        band = d[QMIDKey.band] as? Int
        pci = d[QMIDKey.pci] as? Int
        cellID = (d[QMIDKey.cellID] as? NSNumber)?.uint64Value
        tac = d[QMIDKey.tac] as? Int
        bandwidth = d[QMIDKey.bandwidth] as? Double
        rsrp = d[QMIDKey.rsrp] as? Double
        rsrq = d[QMIDKey.rsrq] as? Double
        rssi = d[QMIDKey.rssi] as? Double
        snr = d[QMIDKey.snr] as? Double
        active = d[QMIDKey.active] as? Bool
        scellIndex = d[QMIDKey.scellIndex] as? Int
    }

    public var dictionary: NSDictionary {
        var d: [String: Any] = [QMIDKey.rat: rat.rawValue, QMIDKey.role: role.rawValue]
        d[QMIDKey.channel] = channel
        d[QMIDKey.band] = band
        d[QMIDKey.pci] = pci
        d[QMIDKey.cellID] = cellID.map { NSNumber(value: $0) }
        d[QMIDKey.tac] = tac
        d[QMIDKey.bandwidth] = bandwidth
        d[QMIDKey.rsrp] = rsrp
        d[QMIDKey.rsrq] = rsrq
        d[QMIDKey.rssi] = rssi
        d[QMIDKey.snr] = snr
        d[QMIDKey.active] = active
        d[QMIDKey.scellIndex] = scellIndex
        return d as NSDictionary
    }

    // The band of a downlink channel number, for cells the modem doesn't name the band of
    // (qmid uses the modem's when it reports one: the LTE cells, NR in SA). LTE: exact (EARFCN ranges don't overlap, TS 36.101
    // table 5.7.3-1). NR: the NR-ARFCN raster is shared, so overlapping bands can't be told
    // apart; the first match wins, the more common band listed first (n78 before n77, n41
    // before n7 and n90, n1 before n65/n66).
    public static func band(_ rat: RAT, channel: Int) -> Int? {
        let table = rat == .lte ? lteBands : nrBands
        return table.first { $0.range.contains(channel) }?.band
    }

    static let lteBands: [(band: Int, range: ClosedRange<Int>)] = [
        (1, 0...599), (2, 600...1199), (3, 1200...1949), (4, 1950...2399), (5, 2400...2649),
        (6, 2650...2749), (7, 2750...3449), (8, 3450...3799), (9, 3800...4149), (10, 4150...4749),
        (11, 4750...4949), (12, 5010...5179), (13, 5180...5279), (14, 5280...5379), (17, 5730...5849),
        (18, 5850...5999), (19, 6000...6149), (20, 6150...6449), (21, 6450...6599), (22, 6600...7399),
        (23, 7500...7699), (24, 7700...8039), (25, 8040...8689), (26, 8690...9039), (27, 9040...9209),
        (28, 9210...9659), (29, 9660...9769), (30, 9770...9869), (31, 9870...9919), (32, 9920...10359),
        (33, 36000...36199), (34, 36200...36349), (35, 36350...36949), (36, 36950...37549),
        (37, 37550...37749), (38, 37750...38249), (39, 38250...38649), (40, 38650...39649),
        (41, 39650...41589), (42, 41590...43589), (43, 43590...45589), (44, 45590...46589),
        (45, 46590...46789), (46, 46790...54539), (47, 54540...55239), (48, 55240...56739),
        (49, 56740...58239), (50, 58240...59089), (51, 59090...59139), (52, 59140...60139),
        (53, 60140...60254), (65, 65536...66435), (66, 66436...67335), (67, 67336...67535),
        (68, 67536...67835), (69, 67836...68335), (70, 68336...68585), (71, 68586...68935),
        (72, 68936...68985), (73, 68986...69035), (74, 69036...69465), (75, 69466...70315),
        (76, 70316...70365), (85, 70366...70545), (87, 70546...70595), (88, 70596...70645),
    ]

    static let nrBands: [(band: Int, range: ClosedRange<Int>)] = [
        (78, 620000...653333), (77, 620000...680000), (79, 693334...733333), (41, 499200...537999),
        (7, 524000...538000), (90, 499200...538000), (38, 514000...524000), (40, 460000...480000),
        (1, 422000...434000), (66, 422000...440000), (65, 422000...440000), (3, 361000...376000),
        (39, 376000...384000), (2, 386000...398000), (25, 386000...399000), (70, 399000...404000),
        (34, 402000...405000), (30, 470000...472000), (53, 496700...499000), (48, 636667...646666),
        (46, 743334...795000), (96, 795000...875000), (28, 151600...160600), (14, 151600...153600),
        (20, 158200...164200), (8, 185000...192000), (5, 173800...178800), (26, 171800...178800),
        (18, 172000...175000), (12, 145800...149200), (13, 149200...151200), (29, 143400...145600),
        (71, 123400...130400), (50, 286400...303400), (75, 286400...303400), (51, 285400...286400),
        (76, 285400...286400), (74, 295000...303600), (257, 2054166...2104165),
        (258, 2016667...2070832), (261, 2070833...2084999), (260, 2229166...2279165),
    ]
}

// bandPreference(): what the modem may use. Empty lists: the modem didn't report that field.
public struct QMIDBandPreference: Equatable {
    public var modes: [String]            // "lte", "nr", "umts", "gsm", "td-scdma", "cdma1x", "evdo"
    public var lteBands: [Int]            // 1, 3, 40, …
    public var nrNSABands: [Int]          // NR bands allowed for EN-DC: 41, 78, …
    public var nrSABands: [Int]           // NR bands allowed for SA
    public var supportedLTEBands: [Int]   // the bands the modem can use at all
    public var supportedNRBands: [Int]
    public var supportedModes: [String]   // the technologies the modem has: setModePreference's choices

    public init(modes: [String] = [], lteBands: [Int] = [], nrNSABands: [Int] = [], nrSABands: [Int] = [],
                supportedLTEBands: [Int] = [], supportedNRBands: [Int] = [], supportedModes: [String] = []) {
        self.modes = modes
        self.lteBands = lteBands
        self.nrNSABands = nrNSABands
        self.nrSABands = nrSABands
        self.supportedLTEBands = supportedLTEBands
        self.supportedNRBands = supportedNRBands
        self.supportedModes = supportedModes
    }

    public init(_ d: NSDictionary) {
        modes = d[QMIDKey.modes] as? [String] ?? []
        lteBands = d[QMIDKey.lteBands] as? [Int] ?? []
        nrNSABands = d[QMIDKey.nrNSABands] as? [Int] ?? []
        nrSABands = d[QMIDKey.nrSABands] as? [Int] ?? []
        supportedLTEBands = d[QMIDKey.supportedLTEBands] as? [Int] ?? []
        supportedNRBands = d[QMIDKey.supportedNRBands] as? [Int] ?? []
        supportedModes = d[QMIDKey.supportedModes] as? [String] ?? []
    }

    public var dictionary: NSDictionary {
        [QMIDKey.modes: modes, QMIDKey.lteBands: lteBands, QMIDKey.nrNSABands: nrNSABands, QMIDKey.nrSABands: nrSABands,
         QMIDKey.supportedLTEBands: supportedLTEBands, QMIDKey.supportedNRBands: supportedNRBands,
         QMIDKey.supportedModes: supportedModes]
    }
}

// GNSS assistance data (XTRA): predicted satellite orbits the modem uses for a fast first fix.
// The modem has not been seen fetching it by itself under qmid; loadXTRA puts in a file a
// client downloaded from one of `servers`.
public struct QMIDXTRA: Equatable {
    public var supported: Bool
    public var validFrom: Date?           // nil: the modem holds no XTRA data
    public var validHours: Int?
    public var servers: [String]
    // qmid's own updates (config "xtra"): on, the last file it loaded, its next look, and the
    // last failure while it lasts.
    public var autoUpdate: Bool = false
    public var lastDownload: Date?
    public var nextCheck: Date?
    public var lastError: String?

    // How old the data is (since validFrom).
    public func age(at date: Date = Date()) -> TimeInterval? { validFrom.map { date.timeIntervalSince($0) } }

    public var expires: Date? {
        guard let validFrom, let validHours else { return nil }
        return validFrom.addingTimeInterval(TimeInterval(validHours) * 3600)
    }

    // The data covers `date` (now by default).
    public func isValid(at date: Date = Date()) -> Bool {
        guard let validFrom, let expires else { return false }
        return date >= validFrom && date < expires
    }

    public init(supported: Bool, validFrom: Date? = nil, validHours: Int? = nil, servers: [String] = []) {
        self.supported = supported
        self.validFrom = validFrom
        self.validHours = validHours
        self.servers = servers
    }

    public init(_ d: NSDictionary) {
        supported = d[QMIDKey.supported] as? Bool ?? false
        validFrom = (d[QMIDKey.validFrom] as? Double).map(Date.init(timeIntervalSince1970:))
        validHours = d[QMIDKey.validHours] as? Int
        servers = d[QMIDKey.servers] as? [String] ?? []
        autoUpdate = d[QMIDKey.autoUpdate] as? Bool ?? false
        lastDownload = (d[QMIDKey.lastDownload] as? Double).map(Date.init(timeIntervalSince1970:))
        nextCheck = (d[QMIDKey.nextCheck] as? Double).map(Date.init(timeIntervalSince1970:))
        lastError = d[QMIDKey.error] as? String
    }

    public var dictionary: NSDictionary {
        var d: [String: Any] = [QMIDKey.supported: supported, QMIDKey.servers: servers, QMIDKey.autoUpdate: autoUpdate]
        d[QMIDKey.validFrom] = validFrom?.timeIntervalSince1970
        d[QMIDKey.validHours] = validHours
        d[QMIDKey.lastDownload] = lastDownload?.timeIntervalSince1970
        d[QMIDKey.nextCheck] = nextCheck?.timeIntervalSince1970
        d[QMIDKey.error] = lastError
        return d as NSDictionary
    }
}

// A position from the modem's GNSS ("location" events, after startLocation).
public struct QMIDLocation: Equatable {
    public enum Fix: String {
        case fix                              // a satellite fix
        case intermediate                     // while searching: coarse (e.g. cell based, ±km), may improve
        case failed                           // the attempt failed (no position)
    }

    public var fixName: String                // raw value, kept when unknown
    public var latitude: Double?
    public var longitude: Double?
    public var horizontalAccuracy: Double?
    public var altitude: Double?
    public var altitudeMSL: Double?
    public var verticalAccuracy: Double?
    public var speed: Double?
    public var verticalSpeed: Double?
    public var heading: Double?
    public var time: Date?
    public var satellitesUsed: Int?
    public var technology: [String]

    public var fix: Fix? { Fix(rawValue: fixName) }

    public init(fix: Fix) {
        fixName = fix.rawValue
        technology = []
    }

    public init(_ d: NSDictionary) {
        fixName = d[QMIDKey.fix] as? String ?? "unknown"
        latitude = d[QMIDKey.latitude] as? Double
        longitude = d[QMIDKey.longitude] as? Double
        horizontalAccuracy = d[QMIDKey.horizontalAccuracy] as? Double
        altitude = d[QMIDKey.altitude] as? Double
        altitudeMSL = d[QMIDKey.altitudeMSL] as? Double
        verticalAccuracy = d[QMIDKey.verticalAccuracy] as? Double
        speed = d[QMIDKey.speed] as? Double
        verticalSpeed = d[QMIDKey.verticalSpeed] as? Double
        heading = d[QMIDKey.heading] as? Double
        time = (d[QMIDKey.time] as? Double).map(Date.init(timeIntervalSince1970:))
        satellitesUsed = d[QMIDKey.satellitesUsed] as? Int
        technology = d[QMIDKey.technology] as? [String] ?? []
    }

    public var dictionary: NSDictionary {
        var d: [String: Any] = [QMIDKey.fix: fixName, QMIDKey.technology: technology]
        d[QMIDKey.latitude] = latitude
        d[QMIDKey.longitude] = longitude
        d[QMIDKey.horizontalAccuracy] = horizontalAccuracy
        d[QMIDKey.altitude] = altitude
        d[QMIDKey.altitudeMSL] = altitudeMSL
        d[QMIDKey.verticalAccuracy] = verticalAccuracy
        d[QMIDKey.speed] = speed
        d[QMIDKey.verticalSpeed] = verticalSpeed
        d[QMIDKey.heading] = heading
        d[QMIDKey.time] = time?.timeIntervalSince1970
        d[QMIDKey.satellitesUsed] = satellitesUsed
        return d as NSDictionary
    }
}

// One signal of one satellite: a dual-frequency receiver lists a satellite once per signal.
public struct QMIDSatellite: Equatable {
    public var system: String                 // "gps", "beidou", …; "system N" when unknown
    public var id: Int
    public var signal: String?
    public var tracking: Bool                 // false: searching
    public var elevation: Double?
    public var azimuth: Double?
    public var cn0: Double?
    public var used: Bool

    public init(system: String, id: Int, signal: String? = nil, tracking: Bool, elevation: Double? = nil,
                azimuth: Double? = nil, cn0: Double? = nil, used: Bool = false) {
        self.system = system
        self.id = id
        self.signal = signal
        self.tracking = tracking
        self.elevation = elevation
        self.azimuth = azimuth
        self.cn0 = cn0
        self.used = used
    }

    public init?(_ d: NSDictionary) {
        guard let system = d[QMIDKey.system] as? String, let id = d[QMIDKey.id] as? Int else { return nil }
        self.system = system
        self.id = id
        signal = d[QMIDKey.signal] as? String
        tracking = d[QMIDKey.state] as? String == "tracking"
        elevation = d[QMIDKey.elevation] as? Double
        azimuth = d[QMIDKey.azimuth] as? Double
        cn0 = d[QMIDKey.cn0] as? Double
        used = d[QMIDKey.used] as? Bool ?? false
    }

    public var dictionary: NSDictionary {
        var d: [String: Any] = [QMIDKey.system: system, QMIDKey.id: id, QMIDKey.state: tracking ? "tracking" : "searching",
                                QMIDKey.used: used]
        d[QMIDKey.signal] = signal
        d[QMIDKey.elevation] = elevation
        d[QMIDKey.azimuth] = azimuth
        d[QMIDKey.cn0] = cn0
        return d as NSDictionary
    }
}

// The satellites the engine sees ("satellites" events): searched and tracked signals.
public struct QMIDSatellites: Equatable {
    public var satellites: [QMIDSatellite]
    public var time: Date

    public init(satellites: [QMIDSatellite], time: Date) {
        self.satellites = satellites
        self.time = time
    }

    public init(_ d: NSDictionary) {
        satellites = (d[QMIDKey.satellites] as? [NSDictionary] ?? []).compactMap(QMIDSatellite.init)
        time = (d[QMIDKey.time] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
    }

    public var dictionary: NSDictionary {
        [QMIDKey.satellites: satellites.map(\.dictionary), QMIDKey.time: time.timeIntervalSince1970]
    }

    public var tracking: [QMIDSatellite] { satellites.filter(\.tracking) }

    // Per system: signals tracked and satellites (not signals) used in the fix.
    public var summary: [(system: String, tracking: Int, used: Int)] {
        Dictionary(grouping: satellites, by: \.system).map { system, list in
            (system, list.filter(\.tracking).count, Set(list.filter(\.used).map(\.id)).count)
        }.sorted { $0.system < $1.system }
    }
}

// The GNSS engine and the location session qmid runs for its clients; never a position.
public struct QMIDGNSS: Equatable {
    public var engine: String                 // "on" | "off" | "unknown"
    public var running: Bool                  // a session runs (some connection started location)
    public var interval: Int?                 // ms between reports while running
    public var lastFix: Date?
    public var clients: Int
    public var assist: QMIDGNSSAssist?        // the last starting position qmid gave the modem

    public init(engine: String = "unknown", running: Bool = false, interval: Int? = nil, lastFix: Date? = nil, clients: Int = 0,
                assist: QMIDGNSSAssist? = nil) {
        self.engine = engine
        self.running = running
        self.interval = interval
        self.lastFix = lastFix
        self.clients = clients
        self.assist = assist
    }

    public init(_ d: NSDictionary) {
        engine = d[QMIDKey.engine] as? String ?? "unknown"
        running = d[QMIDKey.session] as? String == "running"
        interval = d[QMIDKey.interval] as? Int
        lastFix = (d[QMIDKey.lastFix] as? Double).map(Date.init(timeIntervalSince1970:))
        clients = d[QMIDKey.clients] as? Int ?? 0
        assist = (d[QMIDKey.assist] as? NSDictionary).map(QMIDGNSSAssist.init)
    }

    public var dictionary: NSDictionary {
        var d: [String: Any] = [QMIDKey.engine: engine, QMIDKey.session: running ? "running" : "idle",
                                QMIDKey.clients: clients]
        d[QMIDKey.interval] = interval
        d[QMIDKey.lastFix] = lastFix?.timeIntervalSince1970
        d[QMIDKey.assist] = assist?.dictionary
        return d as NSDictionary
    }
}

// A starting position qmid gave (or tried to give) the modem before a session: from a SUPL
// server, for the serving cell. Never the position itself.
public struct QMIDGNSSAssist: Equatable {
    public enum Result: String { case injected, rejected, failed, skipped }

    public var time: Date
    public var result: Result
    public var source: String                 // "supl"
    public var server: String?                // "host:port"
    public var cell: String?
    public var uncertainty: Double?           // m, as injected
    public var duration: Double?              // s the server took
    public var error: String?                 // failed / rejected / skipped: why
    public var firstFixAfter: Double?         // s from the session's start
    public var firstFixDistance: Double?      // m between the injected position and the first fix

    public init(time: Date, result: Result, source: String = "supl", server: String? = nil, cell: String? = nil,
                uncertainty: Double? = nil, duration: Double? = nil, error: String? = nil) {
        self.time = time
        self.result = result
        self.source = source
        self.server = server
        self.cell = cell
        self.uncertainty = uncertainty
        self.duration = duration
        self.error = error
    }

    public init(_ d: NSDictionary) {
        time = Date(timeIntervalSince1970: d[QMIDKey.time] as? Double ?? 0)
        result = (d[QMIDKey.result] as? String).flatMap(Result.init) ?? .failed
        source = d[QMIDKey.source] as? String ?? "supl"
        server = d[QMIDKey.server] as? String
        cell = d[QMIDKey.cell] as? String
        uncertainty = d[QMIDKey.uncertainty] as? Double
        duration = d[QMIDKey.duration] as? Double
        error = d[QMIDKey.error] as? String
        firstFixAfter = d[QMIDKey.firstFixAfter] as? Double
        firstFixDistance = d[QMIDKey.firstFixDistance] as? Double
    }

    public var dictionary: NSDictionary {
        var d: [String: Any] = [QMIDKey.time: time.timeIntervalSince1970, QMIDKey.result: result.rawValue, QMIDKey.source: source]
        d[QMIDKey.server] = server
        d[QMIDKey.cell] = cell
        d[QMIDKey.uncertainty] = uncertainty
        d[QMIDKey.duration] = duration
        d[QMIDKey.error] = error
        d[QMIDKey.firstFixAfter] = firstFixAfter
        d[QMIDKey.firstFixDistance] = firstFixDistance
        return d as NSDictionary
    }
}

// macOS Internet Sharing with a PDN as its source (config "sharing"). qmid provides the source
// service; Internet Sharing itself (System Settings › General › Sharing) is turned on by the
// user, and qmid turns it back on after an outage of the PDN made it switch itself off.
public struct QMIDSharing: Equatable {
    public enum State: String {
        case notSelected = "not-selected"     // Internet Sharing's source is another service
        case off                              // turned off (by the user)
        case waiting                          // on, or to be turned back on, once the PDN is up
        case on                               // sharing runs over the PDN
    }

    public var pdn: String
    public var state: State
    public var interface: String?             // the PDN's utun, while on
    public var bridge: String?                // the shared network's interface, while on
    public var sharedTo: [String]             // interfaces shared to ("en0")
    public var clients: Int                   // devices on the shared network

    public init(pdn: String, state: State, interface: String? = nil, bridge: String? = nil,
                sharedTo: [String] = [], clients: Int = 0) {
        self.pdn = pdn
        self.state = state
        self.interface = interface
        self.bridge = bridge
        self.sharedTo = sharedTo
        self.clients = clients
    }

    public init?(_ d: NSDictionary) {
        guard let p = d[QMIDKey.pdn] as? String,
              let s = (d[QMIDKey.state] as? String).flatMap(State.init(rawValue:)) else { return nil }
        pdn = p
        state = s
        interface = d[QMIDKey.interface] as? String
        bridge = d[QMIDKey.bridge] as? String
        sharedTo = d[QMIDKey.sharedTo] as? [String] ?? []
        clients = d[QMIDKey.clients] as? Int ?? 0
    }

    public var dictionary: NSDictionary {
        var d: [String: Any] = [QMIDKey.pdn: pdn, QMIDKey.state: state.rawValue, QMIDKey.sharedTo: sharedTo,
                                QMIDKey.clients: clients]
        d[QMIDKey.interface] = interface
        d[QMIDKey.bridge] = bridge
        return d as NSDictionary
    }
}
