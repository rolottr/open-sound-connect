import Foundation

/// Sony "MDR" serial framing used over the headset's RFCOMM service.
///
/// ```
/// 0x3E  escape( dataType, sequence, payloadLength:UInt32BE, payload…, checksum )  0x3C
/// ```
/// Checksum is the 8-bit sum of every unescaped byte before it. 0x3C/0x3D/0x3E inside the body are escaped
/// as 0x3D followed by the byte with bit 4 cleared (0x2C/0x2D/0x2E).
/// Provenance: matches Sound Connect's tandem framing and the MIT libmdr implementation (see the README credits).
enum MDRDataType: UInt8, Sendable, CustomStringConvertible {
    case data = 0x00
    case ack = 0x01
    case dataMcNo1 = 0x02
    case dataIcd = 0x09
    case dataEv = 0x0A
    /// Table 1 ("MDR") commands.
    case dataMdr = 0x0C
    case dataCommon = 0x0D
    /// Table 2 ("MDR NO2") commands: peripheral/multipoint, voice guidance, safe listening.
    case dataMdrNo2 = 0x0E
    case shot = 0x10
    case shotMcNo1 = 0x12
    case shotIcd = 0x19
    case shotEv = 0x1A
    case shotMdr = 0x1C
    case shotCommon = 0x1D
    case shotMdrNo2 = 0x1E
    case largeDataCommon = 0x2D

    var description: String {
        switch self {
        case .data: "DATA"
        case .ack: "ACK"
        case .dataMcNo1: "DATA_MC_NO1"
        case .dataIcd: "DATA_ICD"
        case .dataEv: "DATA_EV"
        case .dataMdr: "MDR"
        case .dataCommon: "COMMON"
        case .dataMdrNo2: "MDR2"
        case .shot: "SHOT"
        case .shotMcNo1: "SHOT_MC_NO1"
        case .shotIcd: "SHOT_ICD"
        case .shotEv: "SHOT_EV"
        case .shotMdr: "SHOT_MDR"
        case .shotCommon: "SHOT_COMMON"
        case .shotMdrNo2: "SHOT_MDR2"
        case .largeDataCommon: "LARGE_DATA_COMMON"
        }
    }
}

struct MDRFrame: Sendable, Equatable {
    var rawType: UInt8
    var sequence: UInt8
    var payload: [UInt8]

    var type: MDRDataType? { MDRDataType(rawValue: rawType) }

    init(type: MDRDataType, sequence: UInt8, payload: [UInt8]) {
        self.rawType = type.rawValue
        self.sequence = sequence
        self.payload = payload
    }

    init(rawType: UInt8, sequence: UInt8, payload: [UInt8]) {
        self.rawType = rawType
        self.sequence = sequence
        self.payload = payload
    }

    static let startMarker: UInt8 = 0x3E
    static let endMarker: UInt8 = 0x3C
    static let escapeMarker: UInt8 = 0x3D

    /// Wire bytes including markers.
    func encoded() -> [UInt8] {
        var body: [UInt8] = [rawType, sequence]
        let length = UInt32(payload.count)
        body += [UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)]
        body += payload
        body.append(body.reduce(UInt8(0), &+))
        var wire: [UInt8] = [Self.startMarker]
        wire.reserveCapacity(body.count + 8)
        for byte in body {
            switch byte {
            case 0x3C, 0x3D, 0x3E:
                wire.append(Self.escapeMarker)
                wire.append(byte & ~0x10)
            default:
                wire.append(byte)
            }
        }
        wire.append(Self.endMarker)
        return wire
    }

    enum DecodeError: Error, CustomStringConvertible {
        case badEscape, tooShort, badChecksum(expected: UInt8, actual: UInt8), badLength(declared: Int, actual: Int)
        var description: String {
            switch self {
            case .badEscape: "invalid escape sequence"
            case .tooShort: "frame shorter than header"
            case let .badChecksum(e, a): String(format: "checksum mismatch (expected %02X, got %02X)", e, a)
            case let .badLength(d, a): "declared length \(d) but carried \(a) bytes"
            }
        }
    }

    /// Decodes the bytes strictly between the start and end markers.
    static func decode(body escaped: ArraySlice<UInt8>) throws -> MDRFrame {
        var body: [UInt8] = []
        body.reserveCapacity(escaped.count)
        var iterator = escaped.makeIterator()
        while let byte = iterator.next() {
            if byte == escapeMarker {
                guard let next = iterator.next() else { throw DecodeError.badEscape }
                switch next {
                case 0x2C, 0x2D, 0x2E: body.append(next | 0x10)
                default: throw DecodeError.badEscape
                }
            } else {
                body.append(byte)
            }
        }
        guard body.count >= 7 else { throw DecodeError.tooShort }
        let checksum = body.removeLast()
        let computed = body.reduce(UInt8(0), &+)
        guard checksum == computed else { throw DecodeError.badChecksum(expected: computed, actual: checksum) }
        let declared = Int(body[2]) << 24 | Int(body[3]) << 16 | Int(body[4]) << 8 | Int(body[5])
        let payload = Array(body[6...])
        guard declared == payload.count else { throw DecodeError.badLength(declared: declared, actual: payload.count) }
        return MDRFrame(rawType: body[0], sequence: body[1], payload: payload)
    }
}

/// Reassembles frames from an RFCOMM byte stream that may split or coalesce them.
struct MDRFrameAssembler {
    private var buffer: [UInt8] = []

    enum Output {
        case frame(MDRFrame, raw: [UInt8])
        case malformed(raw: [UInt8], error: Error)
    }

    mutating func append(_ bytes: [UInt8]) -> [Output] {
        buffer += bytes
        var outputs: [Output] = []
        while true {
            guard let start = buffer.firstIndex(of: MDRFrame.startMarker) else {
                buffer.removeAll(keepingCapacity: true)
                break
            }
            if start > 0 { buffer.removeFirst(start) }
            guard let end = buffer.firstIndex(of: MDRFrame.endMarker) else { break }
            let raw = Array(buffer[0...end])
            buffer.removeFirst(end + 1)
            do {
                outputs.append(.frame(try MDRFrame.decode(body: raw[1..<(raw.count - 1)]), raw: raw))
            } catch {
                outputs.append(.malformed(raw: raw, error: error))
            }
        }
        // A runaway buffer without an end marker means the stream is garbage; drop it.
        if buffer.count > 8192 { buffer.removeAll(keepingCapacity: true) }
        return outputs
    }

    mutating func reset() { buffer.removeAll() }
}

extension Array where Element == UInt8 {
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}

extension ArraySlice where Element == UInt8 {
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}
