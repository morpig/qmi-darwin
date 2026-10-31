import Foundation
import SystemConfiguration

// Proxy settings for qmid's services. Proxy tools (and System Settings) store proxies per
// network service in Setup: (`networksetup -setwebproxy` on every service); qmid's services are
// State:-only, so none of them get any, and while cellular is primary configd's
// State:/Network/Global/Proxies comes out empty: apps see no proxy. IPMonitor also reads a
// Proxies entity under State:/Network/Service/<id>, so qmid publishes a copy of the settings of
// the first enabled service in ServiceOrder that has a proxy turned on, and follows changes.
// "mirrorProxies": false in qmid.json turns it off.
public final class ProxyMirror {
    // The settings to publish; nil when no service has a proxy on.
    public private(set) var current: [String: Any]?
    private var store: SCDynamicStore?
    private let onChange: () -> Void

    private static let order = "Setup:/Network/Global/IPv4"
    private static let services = "Setup:/Network/Service/[^/]+"
    private static let proxies = "Setup:/Network/Service/[^/]+/Proxies"

    // onChange runs on queue whenever `current` changes.
    public init(queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var ctx = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                        retain: nil, release: nil, copyDescription: nil)
        guard let s = SCDynamicStoreCreate(nil, "qmid-proxies" as CFString, { _, _, info in
            guard let info else { return }
            Unmanaged<ProxyMirror>.fromOpaque(info).takeUnretainedValue().refresh()
        }, &ctx) else { return }
        SCDynamicStoreSetNotificationKeys(s, [Self.order] as CFArray, [Self.services, Self.proxies] as CFArray)
        SCDynamicStoreSetDispatchQueue(s, queue)
        store = s
        current = read()
    }

    deinit {
        if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
    }

    private func refresh() {
        let next = read()
        guard !Self.same(next, current) else { return }
        current = next
        onChange()
    }

    private func read() -> [String: Any]? {
        guard let store else { return nil }
        let order = (SCDynamicStoreCopyValue(store, Self.order as CFString) as? [String: Any])?["ServiceOrder"] as? [String] ?? []
        let all = SCDynamicStoreCopyMultiple(store, nil, [Self.services, Self.proxies] as CFArray) as? [String: Any] ?? [:]
        var proxies: [String: [String: Any]] = [:], inactive: Set<String> = []
        for (key, value) in all {
            let parts = key.split(separator: "/")
            guard parts.count >= 4, let d = value as? [String: Any] else { continue }
            let id = String(parts[3])
            if parts.count == 5 { proxies[id] = d } else if d["__INACTIVE__"] != nil { inactive.insert(id) }
        }
        return Self.select(order: order, proxies: proxies, inactive: inactive)
    }

    // The first service in order (then the rest, sorted) that is enabled and has a proxy on.
    static func select(order: [String], proxies: [String: [String: Any]], inactive: Set<String>) -> [String: Any]? {
        let ids = order + proxies.keys.filter { !order.contains($0) }.sorted()
        for id in ids where !inactive.contains(id) {
            if let p = proxies[id], isOn(p) { return p }
        }
        return nil
    }

    // Any of HTTPEnable, HTTPSEnable, SOCKSEnable, ProxyAutoConfigEnable, … set.
    static func isOn(_ p: [String: Any]) -> Bool {
        p.contains { $0.key.hasSuffix("Enable") && ($0.value as? NSNumber)?.intValue ?? 0 != 0 }
    }

    static func same(_ a: [String: Any]?, _ b: [String: Any]?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return NSDictionary(dictionary: a).isEqual(to: b)
        default: return false
        }
    }
}
