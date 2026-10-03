import Foundation
import os
import QMIDAPI
import QMIHost
import Security

// qmid: root LaunchDaemon (PLAN.md §1, §8). Owns the QMI interface, the utuns and the
// SCDynamicStore services; qmictl, the QMI Darwin app and client apps use its XPC API
// (QMIDAPI, docs/API.md).

setvbuf(stdout, nil, _IOLBF, 0)
setvbuf(stderr, nil, _IOLBF, 0)

// Logs go to the unified log (macOS caps and ages it out; no file to rotate):
//   log stream --predicate 'subsystem == "com.qmi-darwin.qmid"' [--level debug]
// Everything is logged public and unredacted, the QMI trace (debug) included, which can carry
// profile credentials and SIM identifiers. The same lines go to XPC log subscribers (LogHub).
// Run from a terminal, qmid also prints to stderr.
let logger = Logger(subsystem: qmidMachService, category: "qmid")
let traceLogger = OSLog(subsystem: qmidMachService, category: "trace")
let interactive = isatty(STDERR_FILENO) != 0
let timestamp = ISO8601DateFormatter()

func log(_ s: String, level: QMIDLogLevel = .info) {
    switch level {
    case .debug: os_log(.debug, log: traceLogger, "%{public}s", s)
    case .info: logger.info("\(s, privacy: .public)")
    case .notice: logger.notice("\(s, privacy: .public)")
    case .error: logger.error("\(s, privacy: .public)")
    }
    logHub.append(level, level == .debug ? "trace" : "qmid", s)
    if interactive, level > .debug || tracing {
        FileHandle.standardError.write(Data("\(timestamp.string(from: Date())) \(s)\n".utf8))
    }
}

// QMID_TRACE=1 forces the trace on (terminal use); otherwise it runs while something collects
// debug messages: `log stream --level debug`, or a debug XPC log subscriber.
let tracing = ProcessInfo.processInfo.environment["QMID_TRACE"] != nil
func debugWanted() -> Bool { tracing || logHub.wantsDebug || traceLogger.isEnabled(type: .debug) }

guard geteuid() == 0 else {
    FileHandle.standardError.write(Data("qmid must run as root (launchd)\n".utf8))
    exit(1)
}

let configPath = CommandLine.arguments.dropFirst().first ?? QMIDConfig.defaultPath
let manager: Manager
do {
    manager = try Manager(configPath: configPath)
} catch {
    log("startup: \(error)", level: .error)
    exit(1)
}
manager.logSink = { log($1, level: $0) }
// From the app bundle's Info.plist when qmid runs from Contents/MacOS (nil for a dev build).
let qmidVersion: String? = {
    guard let info = Bundle.main.infoDictionary, let short = info["CFBundleShortVersionString"] as? String else { return nil }
    return "\(short) (\(info["CFBundleVersion"] as? String ?? "?"))"
}()
manager.version = qmidVersion
manager.debugEnabled = debugWanted
manager.restartProcess = {
    // The SCDynamicStore session and the utuns go with the process; launchd (KeepAlive)
    // starts a fresh qmid.
    exit(75)
}

// MARK: - Who may call

// The team that signed this qmid, from its own signature (nil for an unsigned dev build).
let teamIdentifier: String? = {
    var code: SecCode?
    var staticCode: SecStaticCode?
    var info: CFDictionary?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
          SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
          SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let dictionary = info as? [String: Any] else { return nil }
    return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
}()

func isAdmin(uid: uid_t) -> Bool {
    guard let pw = getpwuid(uid) else { return false }
    var count: Int32 = 64
    var groups = [Int32](repeating: 0, count: Int(count))
    guard getgrouplist(pw.pointee.pw_name, Int32(pw.pointee.pw_gid), &groups, &count) != -1 else { return false }
    return groups.prefix(Int(count)).contains(80)          // admin
}

func callerPath(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : "?"
}

// Signed qmid: callers must be signed by the same team (the QMI Darwin app, qmictl,
// client apps), enforced by the XPC runtime on every message. Root is always allowed.
// Unsigned dev build (swift build): root and admin-group users.
func admit(_ c: NSXPCConnection) -> Bool {
    let uid = c.effectiveUserIdentifier
    if uid == 0 { return true }
    if let team = teamIdentifier {
        // Enforced by the XPC runtime on every message; callers that don't match are dropped
        // silently, so the connection is logged to make a refusal traceable.
        log("XPC connection from pid \(c.processIdentifier) (\(callerPath(c.processIdentifier)))")
        c.setCodeSigningRequirement("anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"")
        return true
    }
    return isAdmin(uid: uid)
}

// MARK: - Events

final class Subscribers {
    private let lock = NSLock()
    private var proxies: [ObjectIdentifier: QMIDEvents] = [:]

    // A repeated subscribe on the same connection is a no-op (the client already has the state).
    func add(_ c: NSXPCConnection, snapshot: () -> [NSDictionary]) {
        let proxy = c.remoteObjectProxyWithErrorHandler { _ in } as! QMIDEvents
        lock.lock()
        let isNew = proxies[ObjectIdentifier(c)] == nil
        if isNew { proxies[ObjectIdentifier(c)] = proxy }
        lock.unlock()
        if isNew { snapshot().forEach { proxy.qmidEvent($0) } }
    }

    func remove(_ c: NSXPCConnection) {
        lock.lock(); proxies[ObjectIdentifier(c)] = nil; lock.unlock()
    }

    func broadcast(_ event: NSDictionary) {
        lock.lock(); let all = Array(proxies.values); lock.unlock()
        all.forEach { $0.qmidEvent(event) }
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return proxies.count }
}

let subscribers = Subscribers()
manager.onEvent = { subscribers.broadcast($0) }

// MARK: - XPC

final class Control: NSObject, QMIDControl {
    let manager: Manager
    weak var connection: NSXPCConnection?

    init(manager: Manager, connection: NSXPCConnection) {
        self.manager = manager
        self.connection = connection
    }

    func apiVersion(reply: @escaping (Int) -> Void) { reply(qmidAPIVersion) }
    func status(reply: @escaping (NSDictionary) -> Void) {
        manager.queue.async { reply(self.manager.status()) }
    }
    func connect(_ pdn: String, reply: @escaping (String?) -> Void) {
        manager.queue.async { self.manager.connect(pdn, reply: reply) }
    }
    func disconnect(_ pdn: String, reply: @escaping (String?) -> Void) {
        manager.queue.async { reply(self.manager.disconnect(pdn)) }
    }
    func setPolicy(_ pdn: String, policy: String, reply: @escaping (String?) -> Void) {
        manager.queue.async { reply(self.manager.setPolicy(pdn, policy)) }
    }
    func reload(reply: @escaping (String?) -> Void) {
        manager.queue.async { reply(self.manager.reload()) }
    }
    func profiles(reply: @escaping (NSArray) -> Void) {
        manager.queue.async { reply(self.manager.profiles()) }
    }
    func getConfig(reply: @escaping (Data?, String?) -> Void) {
        manager.queue.async { reply(self.manager.getConfig(), nil) }
    }
    func setConfig(_ json: Data, reply: @escaping (String?) -> Void) {
        manager.queue.async { reply(self.manager.setConfig(json)) }
    }
    func subscribe(reply: @escaping (Bool) -> Void) {
        guard let c = connection else { reply(false); return }
        // On the manager queue, so no event can slip between the snapshot and the subscription.
        manager.queue.async {
            subscribers.add(c) { self.manager.snapshotEvents() }
            reply(true)
        }
    }
    func restart(reply: @escaping (String?) -> Void) {
        let pid = connection?.processIdentifier ?? 0
        reply(nil)
        // Let the reply go out first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { shutdownAndExit("restart requested by pid \(pid)") }
    }
    func subscribeLogs(_ level: Int, since: Double, reply: @escaping (Bool) -> Void) {
        guard let c = connection, let l = QMIDLogLevel(rawValue: level) else { reply(false); return }
        logHub.subscribe(c, level: l, since: since)
        reply(true)
    }
    func unsubscribeLogs(reply: @escaping () -> Void) {
        if let c = connection { logHub.remove(c) }
        reply()
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let manager: Manager
    init(manager: Manager) { self.manager = manager }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        guard admit(c) else {
            log("rejected XPC connection from uid \(c.effectiveUserIdentifier) pid \(c.processIdentifier)", level: .notice)
            return false
        }
        c.exportedInterface = NSXPCInterface(with: QMIDControl.self)
        c.exportedObject = Control(manager: manager, connection: c)
        c.remoteObjectInterface = NSXPCInterface(with: QMIDEvents.self)
        c.invalidationHandler = { [weak c] in if let c { subscribers.remove(c); logHub.remove(c) } }
        c.interruptionHandler = { [weak c] in if let c { subscribers.remove(c); logHub.remove(c) } }
        c.resume()
        return true
    }
}

let delegate = ListenerDelegate(manager: manager)
let listener = NSXPCListener(machServiceName: qmidMachService)
listener.delegate = delegate
listener.resume()

// Clean exit; launchd (KeepAlive) starts qmid again.
func shutdownAndExit(_ reason: String) -> Never {
    log("shutting down (\(reason))", level: .notice)
    manager.queue.sync { manager.shutdown() }
    exit(0)
}

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler {
        shutdownAndExit("signal \(sig)")
    }
    s.resume()
    signalSources.append(s)
}

log("qmid \(qmidVersion ?? "dev build") starting, config \(configPath), \(teamIdentifier.map { "callers must be signed by team \($0)" } ?? "unsigned build: root and admin callers")", level: .notice)
manager.start()
dispatchMain()
