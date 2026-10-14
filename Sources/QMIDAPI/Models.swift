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

    public init(mccmnc: String? = nil, iccidSuffix: String? = nil) {
        self.mccmnc = mccmnc
        self.iccidSuffix = iccidSuffix
        attachAPNFromNetwork = false
    }

    public init?(_ d: NSDictionary?) {
        guard let d, d[QMIDKey.mccmnc] != nil || d[QMIDKey.iccidSuffix] != nil else { return nil }
        mccmnc = d[QMIDKey.mccmnc] as? String
        iccidSuffix = d[QMIDKey.iccidSuffix] as? String
        carrier = d[QMIDKey.carrier] as? String
        matchedBy = d[QMIDKey.matchedBy] as? String
        attachAPN = d[QMIDKey.attachAPN] as? String
        attachAPNFromNetwork = d[QMIDKey.attachAPNFromNetwork] as? Bool ?? false
        pendingSIM = d[QMIDKey.pendingSIM] as? String
    }

    public var dictionary: NSDictionary {
        var d: [String: Any] = [:]
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
    }

    public var dictionary: NSDictionary {
        var d: [String: Any] = [QMIDKey.mccmnc: mccmnc, QMIDKey.nameFromNetwork: nameFromNetwork]
        d[QMIDKey.longName] = longName
        d[QMIDKey.shortName] = shortName
        d[QMIDKey.emergencyBearers] = emergencyBearers
        d[QMIDKey.emergencyAccessBarred] = emergencyAccessBarred
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
