import AppKit
import QMIDAPI
import ServiceManagement

// QMI Darwin.app host: registers qmid (in this bundle's Contents/Library/LaunchDaemons) with
// launchd through SMAppService, so qmid runs as root without password prompts (PLAN.md §8.2).
//
//   QMI Darwin.app                        (Finder) register, then show the state
//   Contents/MacOS/QMI Darwin register    CLI forms, for scripts and testing; register (and a
//                                         Finder launch) also restarts qmid after an app update
//   Contents/MacOS/QMI Darwin unregister
//   Contents/MacOS/QMI Darwin status

let plistName = "com.qmi-darwin.qmid.plist"
let service = SMAppService.daemon(plistName: plistName)

func describe(_ s: SMAppService.Status) -> String {
    switch s {
    case .notRegistered: return "not registered"
    case .enabled: return "enabled"
    case .requiresApproval: return "requires approval in System Settings › General › Login Items"
    case .notFound: return "not registered"   // what launchd reports before the first register, too
    @unknown default: return "unknown (\(s.rawValue))"
    }
}

// BundleProgram is relative to the bundle launchd recorded at registration; moving the app
// afterwards breaks the daemon.
var locationWarning: String? {
    let path = Bundle.main.bundlePath
    return path.hasPrefix("/Applications/") ? nil
        : "QMI Darwin is at \(path). Move it to /Applications before registering; qmid stops working if the app moves later."
}

func register() -> String? {
    // Right after an unregister (e.g. during an update), launchd refuses with EPERM for a
    // couple of seconds; retry for up to ~10 s.
    var attempt = 0
    while true {
        do {
            try service.register()
            return nil
        } catch {
            // Already registered but waiting for approval reports an error too; the status says which.
            if service.status == .requiresApproval { return nil }
            attempt += 1
            if attempt >= 10 { return "register: \(error.localizedDescription)" }
            Thread.sleep(forTimeInterval: 1)
        }
    }
}

// This bundle's build, in the format qmid reports.
let bundleVersion = QMIDVersion.string() ?? "?"

// Calls qmid and waits up to `timeout` (QMIDClient.sync); a timeout is a failure with timedOut.
func withQMID<T>(timeout: TimeInterval = 5,
                 _ call: (QMIDClient, @escaping (Result<T, QMIDError>) -> Void) -> Void) -> Result<T, QMIDError> {
    let client = QMIDClient(queue: DispatchQueue(label: "qmid"))
    defer { client.invalidate() }
    return client.sync(timeout: timeout) { call(client, $0) }
}

// Asks qmid to remove what it added to the network preferences (the Internet Sharing source
// service) before it is unregistered. A warning when it couldn't; nothing to do when qmid
// doesn't answer (it adds nothing while stopped).
func prepareUninstall() -> String? {
    guard service.status == .enabled else { return nil }
    switch withQMID({ c, done in c.prepareUninstall(done) }) {
    case .failure(let e) where e.timedOut: return "qmid didn't answer; an Internet Sharing source service it added may remain"
    case .failure(let e): return "couldn't remove the Internet Sharing source service: \(e.message)"
    case .success: return nil
    }
}

func fetchStatus() -> QMIDStatus? {
    try? withQMID { c, done in c.status(done) }.get()
}

func describe(_ s: QMIDStatus) -> String {
    var lines = ["qmid \(s.version ?? "dev build")", "modem \(s.modem)" + (s.network.map { ", \($0)" } ?? "")]
    for p in s.pdns {
        lines.append("\(p.name): \(p.stateName)" + (p.interface.map { " on \($0)" } ?? ""))
    }
    return lines.joined(separator: "\n")
}

// After the app was replaced, launchd keeps running the old qmid until it exits. If the running
// build differs from this bundle's, ask it to restart (launchd then starts the new binary) and
// wait for the new one. Returns a line to show, or nil when nothing needed doing.
func restartIfOutdated() -> String? {
    guard service.status == .enabled, let s = fetchStatus(), let running = s.version, running != bundleVersion else { return nil }
    let asked = (try? withQMID { c, done in c.restart(done) }.get()) != nil
    guard asked else { return "qmid \(running) is running but didn't accept a restart; the app has \(bundleVersion)" }
    // launchd may throttle the relaunch for up to 10 s.
    for _ in 0..<30 {
        Thread.sleep(forTimeInterval: 1)
        if let n = fetchStatus(), n.version == bundleVersion { return "updated qmid \(running) → \(bundleVersion)" }
    }
    return "asked qmid \(running) to restart, but \(bundleVersion) isn't answering yet"
}

// MARK: - CLI

let args = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
if let command = args.first {
    switch command {
    case "register":
        if let w = locationWarning { FileHandle.standardError.write(Data("warning: \(w)\n".utf8)) }
        if let e = register() { print(e); exit(1) }
        print("qmid: \(describe(service.status))")
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        if let note = restartIfOutdated() { print(note) }
    case "unregister":
        if let e = prepareUninstall() { print("warning: \(e)") }
        do { try service.unregister() } catch { print("unregister: \(error.localizedDescription)"); exit(1) }
        print("qmid: \(describe(service.status))")
    case "status":
        print("qmid: \(describe(service.status))")
        print("app: \(bundleVersion)")
        if service.status == .enabled { print(fetchStatus().map(describe) ?? "qmid not answering") }
    default:
        print("usage: \(CommandLine.arguments[0]) register | unregister | status")
        exit(2)
    }
    exit(0)
}

// MARK: - Finder launch

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)

func alert(_ title: String, _ text: String, buttons: [String]) -> NSApplication.ModalResponse {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = text
    buttons.forEach { a.addButton(withTitle: $0) }
    return a.runModal()
}

if let w = locationWarning, service.status != .enabled {
    _ = alert("Move QMI Darwin to Applications", w, buttons: ["Quit"])
    exit(1)
}
if service.status != .enabled, let e = register() {
    _ = alert("Couldn't register qmid", e, buttons: ["Quit"])
    exit(1)
}

switch service.status {
case .requiresApproval:
    let r = alert("Allow qmid in Login Items",
                  "qmid manages the cellular modem and needs to run in the background. "
                  + "Turn on QMI Darwin under “Allow in the Background” in System Settings › General › Login Items. "
                  + "This is needed once; qmid then starts at every boot without asking for a password.",
                  buttons: ["Open Login Items", "Later"])
    if r == .alertFirstButtonReturn { SMAppService.openSystemSettingsLoginItems() }
case .enabled:
    let note = restartIfOutdated()
    let state = fetchStatus().map(describe) ?? "qmid is registered but not answering yet. Check its log with `qmictl log`."
    let r = alert("qmid is running", [note, state].compactMap { $0 }.joined(separator: "\n\n"),
                  buttons: ["OK", "Unregister qmid"])
    if r == .alertSecondButtonReturn {
        if let e = prepareUninstall() { _ = alert("qmid", e, buttons: ["OK"]) }
        do { try service.unregister() } catch {
            _ = alert("Couldn't unregister qmid", error.localizedDescription, buttons: ["OK"])
        }
    }
default:
    _ = alert("qmid", describe(service.status), buttons: ["OK"])
}
exit(0)
