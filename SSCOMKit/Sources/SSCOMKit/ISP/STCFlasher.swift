import Foundation

/// Programs STC15 / IAP15 8051 parts the way SSCOM 5.13 does.
///
/// Protocol as recovered from SSCOM (FUN_004262ac): the port runs at the chosen
/// speed, 8E1, from the start. The bootloader auto-detects the baud rate from a
/// stream of 0x7F bytes sent while the user power-cycles the chip. Frames are
/// `46 B9 <dir> <len16> <cmd> ... <sum16> 16`, where dir is 6A host→MCU and 68 MCU→host,
/// len counts every byte after `46 B9`, and sum16 is the byte sum from dir to the last data byte.
public struct STCFlasher: Sendable {
    public enum Speed: Int, CaseIterable, Codable, Sendable, Identifiable {
        case normal = 115_200
        case faster = 230_400
        case fastest = 460_800
        public var id: Int { rawValue }

        /// Timer reload byte SSCOM sends in the speed command for each rate.
        var reloadByte: UInt8 {
            switch self {
            case .normal: 0xD0
            case .faster: 0xE8
            case .fastest: 0xF4
            }
        }
    }

    public var speed: Speed
    public init(speed: Speed = .normal) { self.speed = speed }

    static let blockSize = 128

    /// Builds a host→MCU frame around `body` (command byte and payload).
    static func frame(_ body: [UInt8]) -> [UInt8] {
        let length = body.count + 6 // dir + len16 + body + sum16 + end
        var f: [UInt8] = [0x46, 0xB9, 0x6A, UInt8(length >> 8), UInt8(length & 0xFF)] + body
        let sum = Checksum.add16(f[2...])
        f += [UInt8(sum >> 8), UInt8(sum & 0xFF), 0x16]
        return f
    }

    /// Lays out an image the way SSCOM does: 16-bit addresses from offset 0,
    /// gaps filled with 0xFF, length rounded up to a whole 128-byte block.
    static func layout(_ image: FirmwareImage) -> [UInt8] {
        let end = image.blocks.filter { $0.address < 0x10000 }.map { min(Int($0.end), 0x10000) }.max() ?? 0
        let size = (end + blockSize - 1) / blockSize * blockSize
        var buffer = [UInt8](repeating: 0xFF, count: size)
        for block in image.blocks {
            for (i, b) in block.data.enumerated() {
                let addr = Int(block.address) + i
                if addr < size { buffer[addr] = b }
            }
        }
        return buffer
    }

    public func flash(_ image: FirmwareImage, link: any ISPLink, originalBaud: Int,
                      events: @Sendable (ISPEvent) -> Void) async throws {
        let buffer = Self.layout(image)
        guard !buffer.isEmpty else { throw ISPError("The HEX file contains no data.") }
        events(.log("Size: \(buffer.count) Bytes, Baudrate: \(speed.rawValue)bps"))
        try await link.setLine(baudRate: speed.rawValue, parity: .even)
        defer {
            // SSCOM restores no parity and the user's baud rate when done.
            Task { try? await link.setLine(baudRate: originalBaud, parity: .none) }
        }
        try await link.setDTR(true)
        try await link.setRTS(true)
        try await Task.sleep(for: .milliseconds(100))
        try await link.setDTR(true)
        try await Task.sleep(for: .milliseconds(100))
        try await link.setDTR(false)
        events(.log("Start connecting MCU... Power-cycle the MCU now (cold start). Click “Stop” to exit."))

        let started = ContinuousClock.now
        let status = try await synchronise(link: link, events: events)
        // SSCOM reads the oscillator count little-endian from status bytes 5...8.
        if status.count > 8 {
            let freq = status[5...8].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            events(.log("MCU internal oscillator frequency: \(freq)Hz"))
        }
        events(.log("Connected to the MCU. Click “Stop” to quit."))

        // Speed command, then two set-up commands; the last one erases flash.
        await link.discardInput()
        try await link.send(Self.frame([0x01, 0x63, 0x40, 0xFF, speed.reloadByte, 0x00, 0x00, 0xC3]))
        try await expectReply(link, count: 9, command: 0x01)
        try await Task.sleep(for: .milliseconds(100))
        // Like SSCOM, ignore any extra reply bytes before each new command.
        await link.discardInput()
        try await link.send(Self.frame([0x05, 0x00, 0x00, 0x5A, 0xA5]))
        try await expectReply(link, count: 9, command: 0x05)
        await link.discardInput()
        try await link.send(Self.frame([0x03, 0x00, 0x00, 0x5A, 0xA5]))
        try await expectReply(link, count: 16, command: 0x03, timeout: .seconds(10))
        events(.log("Erase complete!"))

        events(.progress(done: 0, total: buffer.count))
        var command: UInt8 = 0x22 // first block; later blocks use 0x02
        var address = 0
        while address < buffer.count {
            try Task.checkCancellation()
            let data = Array(buffer[address..<(address + Self.blockSize)])
            await link.discardInput()
            try await link.send(Self.frame([command, UInt8(address >> 8), UInt8(address & 0xFF), 0x5A, 0xA5] + data))
            let reply = try await read(link, 10, timeout: .seconds(2))
            guard reply[0] == 0x46 else {
                throw ISPError("Data check error (ACKerr) at address \(String(format: "0x%04X", address)). Click “Stop” to quit.")
            }
            command = 0x02
            address += Self.blockSize
            events(.progress(done: address, total: buffer.count))
        }
        let ms = (ContinuousClock.now - started) / .milliseconds(1)
        events(.log("Programmed \(buffer.count) bytes, used \(Int(ms)) ms."))
        events(.log("User's program is running!"))
    }

    /// Sends 0x7F until the bootloader answers, then returns the status payload
    /// (command byte onward, without checksum and end byte).
    private func synchronise(link: any ISPLink, events: @Sendable (ISPEvent) -> Void) async throws -> [UInt8] {
        await link.discardInput()
        var lastHint = ContinuousClock.now
        while true {
            try Task.checkCancellation()
            try await link.send([0x7F])
            guard let first = try? await link.read(1, timeout: .milliseconds(10)) else {
                if ContinuousClock.now - lastHint > .seconds(5) {
                    events(.log("Waiting... power-cycle the MCU."))
                    lastHint = .now
                }
                continue
            }
            guard first[0] == 0x46 else { continue }
            do {
                let head = try await read(link, 4, timeout: .milliseconds(500))
                guard head[0] == 0xB9, head[1] == 0x68, head[2] == 0x00 else {
                    events(.log("First ack error"))
                    await link.discardInput()
                    continue
                }
                let length = Int(head[3])
                guard length > 6 else { continue }
                let payload = try await read(link, length - 6, timeout: .milliseconds(500))
                let tail = try await read(link, 3, timeout: .milliseconds(500))
                guard tail[2] == 0x16 else {
                    events(.log("First ack error"))
                    continue
                }
                return payload
            } catch is ReplyTimeout {
                events(.log("First ack error"))
            }
        }
    }

    private func read(_ link: any ISPLink, _ count: Int, timeout: Duration) async throws -> [UInt8] {
        do {
            return try await link.read(count, timeout: timeout)
        } catch is ReplyTimeout {
            throw ISPError("""
                Can not connect.
                1. Power off? Wrong serial port?
                2. Are RXD and TXD wired correctly?
                3. Try the slower speed.
                """)
        }
    }

    private func expectReply(_ link: any ISPLink, count: Int, command: UInt8, timeout: Duration = .seconds(2)) async throws {
        let reply = try await read(link, count, timeout: timeout)
        guard reply[0] == 0x46, reply[5] == command else {
            throw ISPError(String(format: "Unexpected reply to command 0x%02X.", command))
        }
    }
}
