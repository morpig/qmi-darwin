import Foundation
import QMIKit

public struct PDNConfig: CustomStringConvertible {
    public var name: String
    public var profile: UInt8?
    public var apn: String?
    public var muxID: UInt8
    public var families: [UInt8]          // [4], [6] or [4, 6]

    public init(name: String, profile: UInt8?, apn: String?, muxID: UInt8, families: [UInt8]) {
        self.name = name
        self.profile = profile
        self.apn = apn
        self.muxID = muxID
        self.families = families
    }

    public var description: String {
        let target = profile.map { "profile \($0)" } ?? apn.map { "apn \($0)" } ?? "default"
        return "\(name) (\(target), mux 0x\(String(format: "%02x", muxID)), ipv\(families.map(String.init).joined(separator: "v")))"
    }
}

// One PDN: a WDS client per IP family, all bound to the same mux (PLAN.md §4.2).
public final class PDNSession {
    public let config: PDNConfig
    public let dataInterface: UInt8
    public private(set) var settings: [UInt8: WDS.RuntimeSettings] = [:]
    public private(set) var failures: [UInt8: String] = [:]
    public private(set) var ends: [UInt8: WDS.CallEnd] = [:]

    private let device: QMIDevice
    private var clients: [UInt8: QMIClient] = [:]
    private var handles: [UInt8: UInt32] = [:]

    public init(device: QMIDevice, config: PDNConfig, dataInterface: UInt8) {
        self.device = device
        self.config = config
        self.dataInterface = dataInterface
    }

    public var clientIDs: Set<UInt8> { Set(clients.values.map(\.id)) }

    // Per-family failures in words; one line when every family failed for the same reason.
    public var failureSummary: String { Self.summary(failures) }

    // The same with the codes, for the log.
    public var failureDetail: String {
        Self.summary(failures.reduce(into: [:]) { d, f in d[f.key] = ends[f.key].map { "\($0)" } ?? f.value })
    }

    public static func summary(_ byFamily: [UInt8: String]) -> String {
        let values = Set(byFamily.values)
        if byFamily.count > 1, values.count == 1, let only = values.first { return only }
        return byFamily.sorted { $0.key < $1.key }.map { "ipv\($0.key): \($0.value)" }.joined(separator: "; ")
    }

    // Brings up every family; succeeds if at least one does. Per-family errors are in `failures`.
    public func connect() throws {
        for family in config.families {
            do {
                try connect(family: family)
            } catch {
                failures[family] = ends[family]?.text ?? "\(error)"
                // A family that didn't come up keeps no client: its call doesn't exist, and a
                // leftover client would make isConnected() report the PDN as down.
                if settings[family] == nil, let wds = clients.removeValue(forKey: family) {
                    handles[family] = nil
                    wds.release()
                }
            }
        }
        if settings.isEmpty {
            throw QMIHostError.transport("no family came up: " + failureSummary)
        }
    }

    private func connect(family: UInt8) throws {
        let wds = try device.allocateClient(.wds)
        clients[family] = wds
        try wds.request(WDS.bindMuxDataPort, WDS.bindMuxDataPortRequest(interface: UInt32(dataInterface), muxID: config.muxID))
        try wds.request(WDS.setIPFamily, [.u8(0x01, family)])

        let resp = try wds.request(WDS.startNetworkInterface,
                                   WDS.startRequest(profile: config.profile, apn: config.apn, family: family),
                                   timeout: 60, accept: [.noEffect, .callFailed])
        if let r = resp.result, !r.success {
            if r.error == .callFailed {
                let end = WDS.parseCallEnd(resp)
                ends[family] = end
                throw QMIHostError.transport("start ipv\(family): \(end)")
            }
            // NoEffect: the call already exists on this client/mux; adopt it (no handle).
        } else if let h = WDS.parseHandle(resp) {
            handles[family] = h
        }
        settings[family] = try runtimeSettings(family: family)
    }

    public func runtimeSettings(family: UInt8) throws -> WDS.RuntimeSettings {
        guard let wds = clients[family] else { throw QMIHostError.transport("no client for ipv\(family)") }
        return WDS.parseRuntimeSettings(try wds.request(WDS.getRuntimeSettings, WDS.runtimeSettingsRequest()))
    }

    // The WDS client carrying one family's call.
    public func client(family: UInt8) -> QMIClient? { clients[family] }

    // Re-reads runtime settings for every family (after a reconfiguration indication or wake).
    public func refresh() throws {
        for family in settings.keys { settings[family] = try runtimeSettings(family: family) }
    }

    // True if every family that came up is still connected (WDS Get Packet Service Status).
    public func isConnected() -> Bool {
        for (family, wds) in clients where settings[family] != nil {
            guard let r = try? wds.request(WDS.getPacketServiceStatus, timeout: 5),
                  let v = r[tlv: 0x01], v.first == 2 else { return false }
        }
        return !clients.isEmpty
    }

    // Merged view for configuring the PDN's single utun.
    public var merged: WDS.RuntimeSettings {
        var m = settings[4] ?? WDS.RuntimeSettings()
        if let v6 = settings[6] {
            m.ipv6Address = v6.ipv6Address
            m.ipv6Gateway = v6.ipv6Gateway
            m.ipv6DNS = v6.ipv6DNS
            m.pcscfIPv6 = v6.pcscfIPv6
            if m.mtu == nil { m.mtu = v6.mtu }
            if m.apn == nil { m.apn = v6.apn }
        }
        return m
    }

    public func disconnect() {
        for (family, wds) in clients {
            if let h = handles[family] {
                _ = try? wds.request(WDS.stopNetworkInterface, [.u32(0x01, h)], timeout: 10,
                                     accept: [.noEffect, .outOfCall, .invalidHandle])
            }
            wds.release()
        }
        clients.removeAll()
        handles.removeAll()
    }
}

extension QMIProtocolError {
    public static let invalidHandle = QMIProtocolError(rawValue: 0x0009)
}
