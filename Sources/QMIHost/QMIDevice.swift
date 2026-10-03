import Foundation
import QMIDatapath
import QMIKit

public enum QMIHostError: Error, CustomStringConvertible {
    case open(String)
    case transport(String)
    case timeout(QMIService, UInt16)
    case protocolError(QMIProtocolError, QMIMessage)

    public var description: String {
        switch self {
        case .open(let s): return "open: \(s)"
        case .transport(let s): return "transport: \(s)"
        case .timeout(let svc, let msg): return "timeout waiting for \(svc) 0x\(String(format: "%04x", msg))"
        case .protocolError(let e, let m): return "\(m.service) 0x\(String(format: "%04x", m.messageID)): \(e)"
        }
    }

    public var protocolError: QMIProtocolError? {
        if case .protocolError(let e, _) = self { return e }
        return nil
    }
}

// The QMI control channel of one modem: request/response matching by (service, client, txid)
// and indication dispatch. Requests are synchronous; call them off the main thread if a UI
// is involved.
public final class QMIDevice {
    public static let quectelVendorID: UInt16 = 0x2C7C

    public let modem: QDModem
    public var onIndication: ((QMIMessage) -> Void)?
    // Message trace. Formatted only while `traceEnabled` says someone is collecting it.
    public var trace: ((String) -> Void)?
    public var traceEnabled: () -> Bool = { true }

    private func tr(_ s: @autoclosure () -> String) {
        if let trace, traceEnabled() { trace(s()) }
    }

    // Message ID is part of the key: after a crash the modem may still hold responses to an
    // earlier process's requests with the same transaction IDs.
    private struct Key: Hashable { let service: UInt8; let client: UInt8; let tx: UInt16; let message: UInt16 }
    private final class Waiter { let done = DispatchSemaphore(value: 0); var response: QMIMessage? }

    private let lock = NSLock()
    private var waiters: [Key: Waiter] = [:]
    private var ctlTX: UInt8 = 0
    private var serviceTX: UInt16 = 0

    public init(modem: QDModem) throws {
        self.modem = modem
        do {
            try modem.startControlChannel { [weak self] data in self?.received([UInt8](data)) }
        } catch {
            throw QMIHostError.open("\(error.localizedDescription)")
        }
    }

    public static func open(interface: Int? = nil) throws -> QMIDevice {
        do {
            let modem = try QDModem.open(withVendorID: quectelVendorID, interfaceNumber: interface ?? -1)
            return try QMIDevice(modem: modem)
        } catch let e as QMIHostError {
            throw e
        } catch {
            throw QMIHostError.open(error.localizedDescription)
        }
    }

    public func close() { modem.close() }

    private func received(_ bytes: [UInt8]) {
        guard let msg = try? QMIMessage.decode(bytes) else {
            tr("<< undecodable \(bytes.hex)")
            return
        }
        tr("<< \(msg.summary)  \(bytes.hex)")
        switch msg.kind {
        case .response:
            lock.lock()
            let w = waiters.removeValue(forKey: Key(service: msg.service.rawValue, client: msg.clientID,
                                                  tx: msg.transactionID, message: msg.messageID))
            lock.unlock()
            if let w {
                w.response = msg
                w.done.signal()
            }
        case .indication:
            if msg.service == .ctl, msg.messageID == CTL.sync {
                syncIndicationAt = Date()
                tr("<< CTL Sync indication: QMI ready")
            }
            onIndication?(msg)
        case .request:
            break
        }
    }

    // Sends a request and returns the response. Throws protocolError when the result TLV
    // reports failure, unless the code is in `accept`.
    @discardableResult
    public func send(_ service: QMIService, client: UInt8, message: UInt16, tlvs: [TLV] = [],
                     timeout: TimeInterval = 10, accept: Set<QMIProtocolError> = []) throws -> QMIMessage {
        let w = Waiter()
        lock.lock()
        let tx: UInt16
        if service == .ctl {
            ctlTX = ctlTX == 0xFF ? 1 : ctlTX + 1
            tx = UInt16(ctlTX)
        } else {
            serviceTX = serviceTX == 0xFFFF ? 1 : serviceTX + 1
            tx = serviceTX
        }
        let key = Key(service: service.rawValue, client: client, tx: tx, message: message)
        waiters[key] = w
        lock.unlock()

        let req = QMIMessage(service: service, clientID: client, transactionID: tx, messageID: message, tlvs: tlvs)
        let bytes = req.encoded()
        tr(">> \(req.summary)  \(bytes.hex)")
        do {
            try modem.sendEncapsulatedCommand(Data(bytes))
        } catch {
            lock.lock(); waiters[key] = nil; lock.unlock()
            throw QMIHostError.transport(error.localizedDescription)
        }
        guard w.done.wait(timeout: .now() + timeout) == .success, let resp = w.response else {
            lock.lock(); waiters[key] = nil; lock.unlock()
            throw QMIHostError.timeout(service, message)
        }
        if let r = resp.result, !r.success, !accept.contains(r.error) {
            throw QMIHostError.protocolError(r.error, resp)
        }
        return resp
    }

    // Set when the modem announces its QMI stack with a CTL Sync indication (it does so when
    // the firmware finishes booting after a reset or replug).
    public private(set) var syncIndicationAt: Date?

    // CTL Sync: resets every client the modem holds for this port. Right after the modem
    // (re-)enumerates its USB interfaces are up ~20 s before QMI answers, so keep the interface
    // open and resend every 2 s until `within` runs out (instead of closing and reopening).
    public func sync(within: TimeInterval = 10) throws {
        let deadline = Date().addingTimeInterval(within)
        var last: Error?
        repeat {
            let attempt = Date()
            do {
                try send(.ctl, client: 0, message: CTL.sync, timeout: 2)
                return
            } catch {
                last = error
            }
            // A failed USB transfer (device resetting) throws at once: keep the 2 s pace anyway.
            let wait = 2 - Date().timeIntervalSince(attempt)
            if wait > 0 {
                guard Date().addingTimeInterval(wait) < deadline else { break }
                Thread.sleep(forTimeInterval: wait)
            }
        } while Date() < deadline
        throw last ?? QMIHostError.timeout(.ctl, CTL.sync)
    }

    public func versions() throws -> [CTL.ServiceVersion] {
        try CTL.parseVersions(send(.ctl, client: 0, message: CTL.getVersionInfo))
    }

    public func allocateClient(_ service: QMIService) throws -> QMIClient {
        let resp = try send(.ctl, client: 0, message: CTL.getClientID, tlvs: CTL.getClientIDRequest(service))
        let (svc, cid) = try CTL.parseAllocatedClient(resp)
        guard svc == service else { throw QMIHostError.transport("allocated \(svc), asked for \(service)") }
        return QMIClient(device: self, service: service, id: cid)
    }
}

// One allocated client ID of one service.
public final class QMIClient {
    public let device: QMIDevice
    public let service: QMIService
    public let id: UInt8
    private var released = false

    init(device: QMIDevice, service: QMIService, id: UInt8) {
        self.device = device
        self.service = service
        self.id = id
    }

    @discardableResult
    public func request(_ message: UInt16, _ tlvs: [TLV] = [], timeout: TimeInterval = 10,
                        accept: Set<QMIProtocolError> = []) throws -> QMIMessage {
        try device.send(service, client: id, message: message, tlvs: tlvs, timeout: timeout, accept: accept)
    }

    public func release() {
        guard !released else { return }
        released = true
        _ = try? device.send(.ctl, client: 0, message: CTL.releaseClientID,
                             tlvs: CTL.releaseClientIDRequest(service, id), timeout: 3)
    }
}
