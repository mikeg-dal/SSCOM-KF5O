public import Foundation

/// A firmware image loaded from an Intel HEX file.
public struct FirmwareImage: Sendable, Equatable {
    /// Contiguous blocks of data, sorted by address and merged where adjacent.
    public struct Block: Sendable, Equatable {
        public var address: UInt32
        public var data: [UInt8]
        public var end: UInt32 { address + UInt32(data.count) }
    }

    public var blocks: [Block]
    /// Start address from record type 03/05, when present.
    public var startAddress: UInt32?

    public var byteCount: Int { blocks.reduce(0) { $0 + $1.data.count } }
    public var lowestAddress: UInt32? { blocks.first?.address }
}

public enum IntelHexError: Error, Equatable, LocalizedError, Sendable {
    case notHex(line: Int)
    case badChecksum(line: Int)
    case badLength(line: Int)

    public var errorDescription: String? {
        switch self {
        case .notHex(let l): "The file is not a HEX file (line \(l))."
        case .badChecksum(let l): "Checksum error in HEX file at line \(l)."
        case .badLength(let l): "Malformed HEX record at line \(l)."
        }
    }
}

public enum IntelHex {
    public static func parse(_ text: String) throws(IntelHexError) -> FirmwareImage {
        var upper: UInt32 = 0
        var chunks: [(UInt32, [UInt8])] = []
        var start: UInt32?
        var lineNumber = 0
        for raw in text.split(whereSeparator: \.isNewline) {
            lineNumber += 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard line.first == ":" else { throw .notHex(line: lineNumber) }
            guard let bytes = try? HexCodec.parse(String(line.dropFirst())), bytes.count >= 5 else {
                throw .notHex(line: lineNumber)
            }
            let count = Int(bytes[0])
            guard bytes.count == count + 5 else { throw .badLength(line: lineNumber) }
            guard Checksum.add8(bytes) == 0 else { throw .badChecksum(line: lineNumber) }
            let offset = UInt32(bytes[1]) << 8 | UInt32(bytes[2])
            let payload = Array(bytes[4..<(4 + count)])
            switch bytes[3] {
            case 0x00: chunks.append((upper + offset, payload))
            case 0x01: return assemble(chunks, start: start)
            case 0x02 where count == 2: upper = (UInt32(payload[0]) << 8 | UInt32(payload[1])) << 4
            case 0x04 where count == 2: upper = (UInt32(payload[0]) << 8 | UInt32(payload[1])) << 16
            case 0x03 where count == 4:
                start = (UInt32(payload[0]) << 8 | UInt32(payload[1])) << 4 + (UInt32(payload[2]) << 8 | UInt32(payload[3]))
            case 0x05 where count == 4:
                start = payload.reduce(0) { $0 << 8 | UInt32($1) }
            default: break
            }
        }
        return assemble(chunks, start: start)
    }

    private static func assemble(_ chunks: [(UInt32, [UInt8])], start: UInt32?) -> FirmwareImage {
        var blocks: [FirmwareImage.Block] = []
        for (addr, data) in chunks.sorted(by: { $0.0 < $1.0 }) where !data.isEmpty {
            if var last = blocks.last, last.end == addr {
                last.data += data
                blocks[blocks.count - 1] = last
            } else {
                blocks.append(.init(address: addr, data: data))
            }
        }
        return FirmwareImage(blocks: blocks, startAddress: start)
    }
}
