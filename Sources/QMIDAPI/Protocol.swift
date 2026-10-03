import Foundation

// qmid's public API (XPC). This target depends only on Foundation so other apps can import
// it without the USB/QMI code. See docs/API.md.

public let qmidMachService = "com.qmi-darwin.qmid"

// Bumped when a method or a dictionary key changes incompatibly. Additive changes (new keys,
// new event types) keep the version; clients must ignore what they don't know.
public let qmidAPIVersion = 1

// Methods qmid exports. Replies with a String? carry an error message, nil on success.
// Dictionaries use the keys in QMIDKey; see QMIDStatus / QMIDPDN for typed access.
@objc public protocol QMIDControl {
    func apiVersion(reply: @escaping (Int) -> Void)
    func status(reply: @escaping (NSDictionary) -> Void)
    func connect(_ pdn: String, reply: @escaping (String?) -> Void)
    func disconnect(_ pdn: String, reply: @escaping (String?) -> Void)
    func setPolicy(_ pdn: String, policy: String, reply: @escaping (String?) -> Void)
    func reload(reply: @escaping (String?) -> Void)
    func profiles(reply: @escaping (NSArray) -> Void)
    // qmid.json as UTF-8 JSON (the built-in default if the file doesn't exist).
    func getConfig(reply: @escaping (Data?, String?) -> Void)
    // Validates, writes qmid.json and applies it (like reload). The config is the source of
    // truth for the modem's data profiles, so APN edits go here, not to AT+CGDCONT.
    func setConfig(_ json: Data, reply: @escaping (String?) -> Void)
    // Starts pushing QMIDEvents to the caller's exported object for this connection. The
    // current modem and PDN state is sent right away as events.
    func subscribe(reply: @escaping (Bool) -> Void)
    // Starts pushing qmid's log to this connection as events of type "log", at `level`
    // (QMIDLogLevel raw value) and above. qmid first sends the lines it still holds (a ring of
    // about 2000) newer than `since` (Unix time; 0 for all), then new ones. A debug subscriber
    // turns the QMI message trace on while it stays subscribed. Nothing is redacted.
    // Calling it again changes the level; unsubscribeLogs stops it.
    // Shuts qmid down cleanly (calls stopped, services removed); launchd starts it again right
    // away, from the binary now in the app bundle. Used after an app update.
    func restart(reply: @escaping (String?) -> Void)
    func subscribeLogs(_ level: Int, since: Double, reply: @escaping (Bool) -> Void)
    func unsubscribeLogs(reply: @escaping () -> Void)
}

// Implemented by the client (the connection's exportedObject) to receive events.
@objc public protocol QMIDEvents {
    func qmidEvent(_ event: NSDictionary)
}

public enum QMIDKey {
    // status()
    public static let apiVersion = "apiVersion"
    public static let version = "version"             // qmid build, "0.2.0 (20260930120000)"
    public static let modem = "modem"                 // "absent" | "opening" | "ready"
    public static let modemError = "modemError"
    public static let network = "network"             // e.g. "registered, ps attached, lte"
    public static let pdns = "pdns"                   // [PDN dictionary]
    public static let datapath = "datapath"           // counters
    public static let sim = "sim"                     // SIM dictionary, absent until the SIM is read
    public static let plmn = "plmn"                   // PLMN dictionary, absent while not registered

    // SIM dictionary (status() "sim" and "sim" events)
    public static let mccmnc = "mccmnc"               // home PLMN, "00101" / "001001"
    public static let iccidSuffix = "iccidSuffix"     // "…1234", last 4 digits of the ICCID
    public static let carrier = "carrier"             // name of the matching "carriers" entry
    public static let matchedBy = "matchedBy"         // "iccid 8900" | "mccmnc 00101"
    public static let attachAPN = "attachAPN"         // APN of the default bearer as attached
    public static let attachAPNFromNetwork = "attachAPNFromNetwork" // Bool: the network chose it

    // PLMN dictionary (status() "plmn" and "plmn" events): the registered network
    // mccmnc                                         // registered PLMN, "00101"
    public static let longName = "longName"           // operator long name
    public static let shortName = "shortName"         // operator short name
    public static let nameFromNetwork = "nameFromNetwork" // Bool: names sent by the network (NITZ)
    public static let emergencyBearers = "emergencyBearers"   // Bool: LTE EMC BS; absent when unknown
    public static let emergencyAccessBarred = "emergencyAccessBarred" // Bool; absent when unknown

    // PDN dictionary (status() entries and "pdn" events)
    public static let name = "name"
    public static let state = "state"                 // idle | waiting | dialing | connected | backoff | blocked
    public static let policy = "policy"               // prefer-wifi | prefer-cellular | last-resort | never
    public static let role = "role"                   // internet | ims | other
    public static let interface = "interface"         // utunN while connected
    public static let ipv4 = "ipv4"
    public static let ipv6 = "ipv6"                   // "addr/prefix"
    public static let dns = "dns"                     // [String]
    public static let pcscf = "pcscf"                 // [String] (IMS)
    public static let mtu = "mtu"
    public static let profile = "profile"             // modem profile index (AT+CGDCONT cid)
    public static let apn = "apn"
    public static let serviceID = "serviceID"         // SCDynamicStore service UUID
    public static let mux = "mux"
    public static let wanted = "wanted"               // false after disconnect(), true otherwise
    public static let uptime = "uptime"               // seconds connected
    public static let error = "error"
    public static let blocked = "blocked"             // ["ipv4: 3GPP #51: PDN type IPv6 only allowed", ...]
    public static let reason = "reason"               // error as a word: QMIDReason raw value
    public static let causes = "causes"               // [cause dictionary]: error's call end causes
    public static let counters = "counters"
    public static let qci = "qci"                     // default bearer's QCI (Int)
    public static let ambr = "ambr"                   // APN-AMBR: {uplink, downlink} in bps
    public static let bearers = "bearers"             // [bearer dictionary]: in status() and "bearers" events

    // bearer dictionary (dedicated EPS bearers of a PDN)
    public static let id = "id"                       // bearer: opaque, stable while the bearer lives; filter: 3GPP ID 0–15
    public static let networkInitiated = "networkInitiated"  // Bool
    public static let uplink = "uplink"               // {max, guaranteed} bps; AMBR: bps
    public static let downlink = "downlink"
    public static let max = "max"
    public static let guaranteed = "guaranteed"
    public static let uplinkFilters = "uplinkFilters" // [filter dictionary]
    public static let downlinkFilters = "downlinkFilters"

    // cause dictionary (one family's call end cause): family, type, code, name
    public static let family = "family"               // 4 | 6
    // type                                           // "3GPP" | "internal" | "CM" | … | "call end reason"
    public static let code = "code"                   // the cause number within its type
    // name                                           // its official name, when known

    // filter dictionary (one TFT packet filter)
    public static let precedence = "precedence"
    public static let ipVersion = "ipVersion"         // 4 | 6
    public static let source = "source"               // "addr/prefix"
    public static let destination = "destination"
    public static let ipProtocol = "protocol"         // 6 TCP, 17 UDP, …
    public static let sourcePorts = "sourcePorts"     // [low, high]
    public static let destinationPorts = "destinationPorts"

    // events
    public static let type = "type"                   // "modem" | "pdn" | "config" | "log" | "sim" | "plmn" | "bearers"
    public static let pdn = "pdn"                     // PDN dictionary for type "pdn"; PDN name for type "bearers"

    // "log" events: a batch of entries, plus how many were dropped before them because the
    // client fell behind.
    public static let entries = "entries"             // [log entry dictionary]
    public static let dropped = "dropped"
    public static let time = "time"                   // Unix time (Double)
    public static let level = "level"                 // QMIDLogLevel raw value
    public static let category = "category"           // "qmid", "trace", ...
    public static let message = "message"
}

public enum QMIDEventType {
    public static let modem = "modem"
    public static let pdn = "pdn"
    public static let config = "config"
    public static let log = "log"
    public static let sim = "sim"                     // key QMIDKey.sim, absent when no SIM is known
    public static let plmn = "plmn"                   // key QMIDKey.plmn, absent while not registered
    public static let bearers = "bearers"             // keys QMIDKey.pdn (name) and QMIDKey.bearers
}

// Status keys qmid publishes in SCDynamicStore (readable without XPC, e.g. with
// SCDynamicStoreCopyValue or `scutil`), mirrored from the same data.
public enum QMIDStoreKey {
    public static let modem = "State:/Network/QMI/Modem"
    public static func pdn(_ name: String) -> String { "State:/Network/QMI/PDN/\(name)" }
    public static let pdnPattern = "State:/Network/QMI/PDN/.*"
}
