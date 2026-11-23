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

    public mutating func u64(_ what: String = "u64") throws -> UInt64 {
        guard remaining >= 8 else { throw DecodeError.truncated(what) }
        defer { offset += 8 }
        return (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << (8 * UInt64($1)) }
    }

    public mutating func f32(_ what: String = "f32") throws -> Float { Float(bitPattern: try u32(what)) }
    public mutating func f64(_ what: String = "f64") throws -> Double { Double(bitPattern: try u64(what)) }

    public mutating func take(_ count: Int, _ what: String = "bytes") throws -> [UInt8] {
        guard count >= 0, remaining >= count else { throw DecodeError.truncated(what) }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    // Width of a list's count.
    public enum Count { case u8, u16 }

    // A count, then that many items read by `item`. Throws if the count or an item is cut short.
    public mutating func list<T>(count: Count = .u8, _ what: String = "list",
                                 _ item: (inout ByteReader) throws -> T) throws -> [T] {
        let n = count == .u8 ? Int(try u8(what)) : Int(try u16(what))
        return try (0..<n).map { _ in try item(&self) }
    }

    // The same, lenient: the items up to the first one cut short (the reader stops before it);
    // empty without a count.
    public mutating func partialList<T>(count: Count = .u8, _ item: (inout ByteReader) throws -> T) -> [T] {
        guard let n = count == .u8 ? (try? u8()).map({ Int($0) }) : (try? u16()).map({ Int($0) }) else { return [] }
        var out: [T] = []
        for _ in 0..<n {
            let start = offset
            guard let x = try? item(&self) else { offset = start; break }
            out.append(x)
        }
        return out
    }
}

public struct ByteWriter {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public mutating func u8(_ v: UInt8) { bytes.append(v) }
    public mutating func u16(_ v: UInt16) { bytes += [UInt8(v & 0xff), UInt8(v >> 8)] }
    public mutating func u32(_ v: UInt32) { bytes += (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xff) } }
    public mutating func u64(_ v: UInt64) { bytes += (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xff) } }
    public mutating func f32(_ v: Float) { u32(v.bitPattern) }
    public mutating func f64(_ v: Double) { u64(v.bitPattern) }
    public mutating func append(_ b: [UInt8]) { bytes += b }
}

public extension Array where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined(separator: " ") }

    // The set bits of a little-endian bitmap, bit N being bit N % 8 of byte N / 8 (band
    // bitmaps, Get Supported Messages).
    var bitIndexes: [Int] { (0..<count * 8).filter { self[$0 / 8] & (1 << ($0 % 8)) != 0 } }

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
