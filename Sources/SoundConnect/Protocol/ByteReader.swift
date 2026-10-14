import Foundation

struct ByteReader {
    enum ReadError: Error { case outOfBounds }

    let bytes: [UInt8]
    private(set) var offset: Int

    init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    var remaining: Int { bytes.count - offset }
    var isAtEnd: Bool { offset >= bytes.count }

    mutating func u8() throws -> UInt8 {
        guard offset < bytes.count else { throw ReadError.outOfBounds }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func i8() throws -> Int8 { Int8(bitPattern: try u8()) }

    mutating func u16() throws -> Int { Int(try u8()) << 8 | Int(try u8()) }

    mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= bytes.count else { throw ReadError.outOfBounds }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    /// One-byte length-prefixed UTF-8 string (Sony "prefixed string").
    mutating func string() throws -> String {
        let length = Int(try u8())
        let raw = try take(length)
        return String(decoding: raw, as: UTF8.self)
    }

    mutating func skip(_ count: Int) throws { _ = try take(count) }
}

extension Array where Element == UInt8 {
    func byte(_ index: Int) -> UInt8? { indices.contains(index) ? self[index] : nil }
}
