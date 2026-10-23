/// The checksum algorithms offered by SSCOM's "add checksum" option.
///
/// Raw values match the index of SSCOM's checksum combo box, which is also
/// what its ini file stores. Output byte order follows the original exactly:
/// the CRC16 variants and CRC32 are emitted low byte first, ADD16 high byte first.
public enum ChecksumKind: Int, CaseIterable, Codable, Sendable, Identifiable {
    case none = 0
    case modbusCRC16 = 1
    case ccittCRC16 = 2
    case crc32 = 3
    case zeroAdd8 = 4
    case add8 = 5
    case xor8 = 6
    case add16 = 7

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .none: "None"
        case .modbusCRC16: "ModbusCRC16"
        case .ccittCRC16: "CCITT-CRC16"
        case .crc32: "CRC32"
        case .zeroAdd8: "0-ADD8"
        case .add8: "ADD8"
        case .xor8: "XOR8"
        case .add16: "ADD16"
        }
    }

    /// Computes the checksum bytes, in the order SSCOM transmits them.
    public func bytes<C: Collection<UInt8>>(for data: C) -> [UInt8] {
        switch self {
        case .none:
            return []
        case .modbusCRC16:
            let crc = Checksum.modbusCRC16(data)
            return [UInt8(crc & 0xFF), UInt8(crc >> 8)]
        case .ccittCRC16:
            let crc = Checksum.ccittCRC16(data)
            return [UInt8(crc & 0xFF), UInt8(crc >> 8)]
        case .crc32:
            let crc = Checksum.crc32(data)
            return [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8((crc >> 16) & 0xFF), UInt8(crc >> 24)]
        case .zeroAdd8:
            return [0 &- Checksum.add8(data)]
        case .add8:
            return [Checksum.add8(data)]
        case .xor8:
            return [Checksum.xor8(data)]
        case .add16:
            let sum = Checksum.add16(data)
            return [UInt8(sum >> 8), UInt8(sum & 0xFF)]
        }
    }
}

public enum Checksum {
    /// CRC-16/MODBUS: init 0xFFFF, reflected polynomial 0xA001.
    public static func modbusCRC16<C: Collection<UInt8>>(_ data: C) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }

    /// CRC-16/XMODEM (what SSCOM labels "CCITT-CRC16"): init 0, polynomial 0x1021, MSB first.
    public static func ccittCRC16<C: Collection<UInt8>>(_ data: C) -> UInt16 {
        var crc: UInt16 = 0
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    private static let crc32Table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1
        }
        return c
    }

    /// Standard CRC-32 (IEEE 802.3, as used by zip).
    public static func crc32<C: Collection<UInt8>>(_ data: C) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return ~crc
    }

    public static func add8<C: Collection<UInt8>>(_ data: C) -> UInt8 {
        data.reduce(0) { $0 &+ $1 }
    }

    public static func xor8<C: Collection<UInt8>>(_ data: C) -> UInt8 {
        data.reduce(0) { $0 ^ $1 }
    }

    public static func add16<C: Collection<UInt8>>(_ data: C) -> UInt16 {
        data.reduce(0) { $0 &+ UInt16($1) }
    }
}

/// Where the checksum is calculated and inserted inside an outgoing frame.
public struct ChecksumPlacement: Codable, Sendable, Equatable {
    /// 1-based index of the first byte included in the checksum (1 = whole frame).
    public var firstByte: Int
    /// Number of trailing frame-tail bytes excluded from the checksum (0...4).
    /// The checksum is inserted in front of these bytes.
    public var trailerBytes: Int

    public init(firstByte: Int = 1, trailerBytes: Int = 0) {
        self.firstByte = firstByte
        self.trailerBytes = trailerBytes
    }
}

public struct ChecksumResult: Sendable, Equatable {
    public var frame: [UInt8]
    /// The checksum bytes inserted, empty when none or when the range was empty.
    public var checksum: [UInt8]
    /// True when the configured range selected no bytes, so nothing was added.
    public var rangeWasEmpty: Bool
}

extension ChecksumKind {
    /// Inserts the checksum into `frame` according to `placement`, as SSCOM does.
    public func apply(to frame: [UInt8], placement: ChecksumPlacement) -> ChecksumResult {
        guard self != .none else {
            return ChecksumResult(frame: frame, checksum: [], rangeWasEmpty: false)
        }
        let start = max(placement.firstByte, 1) - 1
        let end = frame.count - max(placement.trailerBytes, 0)
        guard start < end else {
            return ChecksumResult(frame: frame, checksum: [], rangeWasEmpty: true)
        }
        let sum = bytes(for: frame[start..<end])
        var out = Array(frame[..<end])
        out += sum
        out += frame[end...]
        return ChecksumResult(frame: out, checksum: sum, rangeWasEmpty: false)
    }
}
