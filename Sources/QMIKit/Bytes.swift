import Foundation

public enum DecodeError: Error, Equatable {
    case truncated(String)
    case invalid(String)
}

// Little-endian cursor over a byte array. QMI is little-endian throughout; QMAP headers are
// big-endian and are handled in C.
public struct ByteReader {
    public let bytes: [UInt8]
    public private(set) var offset: Int

    public init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    public var remaining: Int { bytes.count - offset }
    public var isAtEnd: Bool { offset >= bytes.count }

    public mutating func u8(_ what: String = "u8") throws -> UInt8 {
        guard remaining >= 1 else { throw DecodeError.truncated(what) }
        defer { offset += 1 }
        return bytes[offset]
    }

    public mutating func u16(_ what: String = "u16") throws -> UInt16 {
        guard remaining >= 2 else { throw DecodeError.truncated(what) }
        defer { offset += 2 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    public mutating func u32(_ what: String = "u32") throws -> UInt32 {
        guard remaining >= 4 else { throw DecodeError.truncated(what) }
        defer { offset += 4 }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
    }

    public mutating func take(_ count: Int, _ what: String = "bytes") throws -> [UInt8] {
        guard count >= 0, remaining >= count else { throw DecodeError.truncated(what) }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    public mutating func rest() -> [UInt8] {
        defer { offset = bytes.count }
        return Array(bytes[offset...])
    }
}

public struct ByteWriter {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public mutating func u8(_ v: UInt8) { bytes.append(v) }
    public mutating func u16(_ v: UInt16) { bytes += [UInt8(v & 0xff), UInt8(v >> 8)] }
    public mutating func u32(_ v: UInt32) { bytes += (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xff) } }
    public mutating func append(_ b: [UInt8]) { bytes += b }
}

public extension Array where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined(separator: " ") }

    init?(hex: String) {
        let digits = hex.filter { $0.isHexDigit }
        guard digits.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        var i = digits.startIndex
        while i < digits.endIndex {
            let j = digits.index(i, offsetBy: 2)
            guard let b = UInt8(digits[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        self = out
    }
}
