import Foundation

// QMI service identifiers (QMUX header "service type").
public struct QMIService: RawRepresentable, Hashable, CustomStringConvertible {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let ctl = QMIService(rawValue: 0x00)
    public static let wds = QMIService(rawValue: 0x01)
    public static let dms = QMIService(rawValue: 0x02)
    public static let nas = QMIService(rawValue: 0x03)
    public static let qos = QMIService(rawValue: 0x04)
    public static let wms = QMIService(rawValue: 0x05)
    public static let voice = QMIService(rawValue: 0x09)
    public static let uim = QMIService(rawValue: 0x0B)
    public static let loc = QMIService(rawValue: 0x10)
    public static let ims = QMIService(rawValue: 0x12)
    public static let wda = QMIService(rawValue: 0x1A)
    public static let pdc = QMIService(rawValue: 0x24)
    public static let dsd = QMIService(rawValue: 0x2A)

    static let names: [UInt8: String] = [
        0x00: "ctl", 0x01: "wds", 0x02: "dms", 0x03: "nas", 0x04: "qos", 0x05: "wms", 0x06: "pds",
        0x07: "auth", 0x08: "at", 0x09: "voice", 0x0A: "cat2", 0x0B: "uim", 0x0C: "pbm",
        0x0D: "qchat", 0x0E: "rmtfs", 0x0F: "test", 0x10: "loc", 0x11: "sar", 0x12: "ims",
        0x13: "adc", 0x14: "csd", 0x15: "mfs", 0x16: "time", 0x17: "ts", 0x18: "tmd", 0x19: "sap",
        0x1A: "wda", 0x1B: "tsync", 0x1C: "rfsa", 0x1D: "csvt", 0x1E: "qcmap", 0x1F: "imsp",
        0x20: "imsvt", 0x21: "imsa", 0x22: "coex", 0x24: "pdc", 0x26: "stx", 0x27: "bit",
        0x28: "imsrtp", 0x29: "rfrpe", 0x2A: "dsd", 0x2B: "ssctl", 0x2F: "dpm", 0x30: "dfs",
        0xE0: "cat", 0xE1: "rms", 0xE2: "oma", 0xE6: "fota", 0xE7: "gms", 0xE8: "gas"
    ]

    public var name: String { Self.names[rawValue] ?? String(format: "0x%02x", rawValue) }
    public var description: String { name }
}

public struct TLV: Equatable {
    public var type: UInt8
    public var value: [UInt8]

    public init(_ type: UInt8, _ value: [UInt8]) {
        self.type = type
        self.value = value
    }

    public static func u8(_ type: UInt8, _ v: UInt8) -> TLV { TLV(type, [v]) }
    public static func u16(_ type: UInt8, _ v: UInt16) -> TLV { var w = ByteWriter(); w.u16(v); return TLV(type, w.bytes) }
    public static func u32(_ type: UInt8, _ v: UInt32) -> TLV { var w = ByteWriter(); w.u32(v); return TLV(type, w.bytes) }
    public static func string(_ type: UInt8, _ s: String) -> TLV { TLV(type, Array(s.utf8)) }
}

// QMI result TLV (0x02) error codes. Values from the public QMI definitions.
public struct QMIProtocolError: RawRepresentable, Hashable, CustomStringConvertible {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let none = QMIProtocolError(rawValue: 0x0000)
    public static let invalidClientID = QMIProtocolError(rawValue: 0x0007)
    public static let callFailed = QMIProtocolError(rawValue: 0x000E)
    public static let outOfCall = QMIProtocolError(rawValue: 0x000F)
    public static let noEffect = QMIProtocolError(rawValue: 0x001A)
    public static let deviceNotReady = QMIProtocolError(rawValue: 0x0034)
    public static let invalidDataFormat = QMIProtocolError(rawValue: 0x002D)
    public static let notSupported = QMIProtocolError(rawValue: 0x005E)

    static let names: [UInt16: String] = [
        0: "None", 1: "MalformedMessage", 2: "NoMemory", 3: "Internal", 4: "Aborted",
        5: "ClientIdsExhausted", 6: "UnabortableTransaction", 7: "InvalidClientId",
        8: "NoThresholdsProvided", 9: "InvalidHandle", 10: "InvalidProfile", 11: "InvalidPinId",
        12: "IncorrectPin", 13: "NoNetworkFound", 14: "CallFailed", 15: "OutOfCall",
        16: "NotProvisioned", 17: "MissingArgument", 19: "ArgumentTooLong",
        22: "InvalidTransactionId", 23: "DeviceInUse", 24: "NetworkUnsupported",
        25: "DeviceUnsupported", 26: "NoEffect", 27: "NoFreeProfile", 28: "InvalidPdpType",
        29: "InvalidTechnologyPreference", 30: "InvalidProfileType", 31: "InvalidServiceType",
        32: "InvalidRegisterAction", 33: "InvalidPsAttachAction", 34: "AuthenticationFailed",
        35: "PinBlocked", 36: "PinAlwaysBlocked", 37: "UimUninitialized",
        43: "InterfaceNotFound", 44: "FlowSuspended", 45: "InvalidDataFormat",
        46: "GeneralError", 47: "UnknownError", 48: "InvalidArgument", 49: "InvalidIndex",
        50: "NoEntry", 51: "DeviceStorageFull", 52: "DeviceNotReady", 53: "NetworkNotReady",
        59: "AuthenticationLock", 60: "InvalidTransition", 94: "NotSupported"
    ]

    public var description: String {
        "\(Self.names[rawValue] ?? "Error") (0x\(String(format: "%04x", rawValue)))"
    }
}

public struct QMIResult: Equatable {
    public var success: Bool
    public var error: QMIProtocolError
}

// One QMUX frame: interface type 0x01, QMUX header, and a CTL or service SDU.
public struct QMIMessage {
    public enum Kind: Equatable { case request, response, indication }

    public var service: QMIService
    public var clientID: UInt8
    public var kind: Kind
    public var transactionID: UInt16
    public var messageID: UInt16
    public var tlvs: [TLV]

    public init(service: QMIService, clientID: UInt8, kind: Kind = .request,
                transactionID: UInt16 = 0, messageID: UInt16, tlvs: [TLV] = []) {
        self.service = service
        self.clientID = clientID
        self.kind = kind
        self.transactionID = transactionID
        self.messageID = messageID
        self.tlvs = tlvs
    }

    public subscript(tlv type: UInt8) -> [UInt8]? {
        tlvs.first { $0.type == type }?.value
    }

    public var result: QMIResult? {
        // Only responses carry one; in a request TLV 0x02 is whatever that message defines.
        guard kind == .response, let v = self[tlv: 0x02], v.count >= 4 else { return nil }
        var r = ByteReader(v)
        let status = (try? r.u16()) ?? 1
        let code = (try? r.u16()) ?? 0
        return QMIResult(success: status == 0, error: QMIProtocolError(rawValue: code))
    }

    private var isControl: Bool { service == .ctl }

    public func encoded() -> [UInt8] {
        var tlvBytes = ByteWriter()
        for t in tlvs {
            tlvBytes.u8(t.type)
            tlvBytes.u16(UInt16(t.value.count))
            tlvBytes.append(t.value)
        }
        var sdu = ByteWriter()
        if isControl {
            sdu.u8(kind == .request ? 0x00 : kind == .response ? 0x01 : 0x02)
            sdu.u8(UInt8(truncatingIfNeeded: transactionID))
        } else {
            sdu.u8(kind == .request ? 0x00 : kind == .response ? 0x02 : 0x04)
            sdu.u16(transactionID)
        }
        sdu.u16(messageID)
        sdu.u16(UInt16(tlvBytes.bytes.count))
        sdu.append(tlvBytes.bytes)

        var out = ByteWriter()
        out.u8(0x01)                                  // interface type: QMUX
        out.u16(UInt16(5 + sdu.bytes.count))           // length, excluding the 0x01
        out.u8(kind == .request ? 0x00 : 0x80)         // control flags: 0x80 = from service
        out.u8(service.rawValue)
        out.u8(clientID)
        out.append(sdu.bytes)
        return out.bytes
    }

    public static func decode(_ bytes: [UInt8]) throws -> QMIMessage {
        var h = ByteReader(bytes)
        guard try h.u8("if type") == 0x01 else { throw DecodeError.invalid("not a QMUX frame") }
        let length = Int(try h.u16("qmux length"))
        guard bytes.count >= length + 1 else { throw DecodeError.truncated("qmux frame \(bytes.count)/\(length + 1)") }
        // Parse within the declared frame only: an SDU or TLV running past it is truncated.
        var r = ByteReader(Array(bytes.prefix(length + 1)))
        _ = try r.take(3, "qmux header")
        _ = try r.u8("control flags")
        let service = QMIService(rawValue: try r.u8("service"))
        let client = try r.u8("client")

        let flags = try r.u8("sdu flags")
        let tx: UInt16
        let kind: Kind
        if service == .ctl {
            tx = UInt16(try r.u8("ctl tx"))
            kind = flags & 0x02 != 0 ? .indication : flags & 0x01 != 0 ? .response : .request
        } else {
            tx = try r.u16("tx")
            kind = flags & 0x04 != 0 ? .indication : flags & 0x02 != 0 ? .response : .request
        }
        let msgID = try r.u16("message id")
        let tlvLength = Int(try r.u16("tlv length"))
        var t = ByteReader(try r.take(tlvLength, "tlvs"))
        var tlvs: [TLV] = []
        while !t.isAtEnd {
            let type = try t.u8("tlv type")
            let len = Int(try t.u16("tlv len"))
            tlvs.append(TLV(type, try t.take(len, "tlv 0x\(String(format: "%02x", type))")))
        }
        return QMIMessage(service: service, clientID: client, kind: kind,
                          transactionID: tx, messageID: msgID, tlvs: tlvs)
    }

    public var summary: String {
        let res = result.map { $0.success ? " ok" : " \($0.error)" } ?? ""
        return "\(service) cid=\(clientID) \(kind) tx=\(transactionID) msg=0x\(String(format: "%04x", messageID))\(res)"
    }
}
