import Foundation

/// Programs STM32 / GD32 parts through the ROM USART bootloader (ST AN3155).
public struct STM32Flasher: Sendable {
    public enum Speed: Int, CaseIterable, Codable, Sendable, Identifiable {
        /// SSCOM: "115200bps, 64KB in about 10 s (normal serial port)".
        case normal = 115_200
        /// SSCOM: "460800bps, 64KB in about 5 s (CH340 and other USB adapters)".
        case fast = 460_800
        public var id: Int { rawValue }
    }

    public var speed: Speed
    public var reset: ResetControl
    /// Where images without an absolute address (and Go) start. STM32 main flash is at 0x08000000.
    public var flashBase: UInt32 = 0x0800_0000

    public init(speed: Speed = .fast, reset: ResetControl = .init()) {
        self.speed = speed
        self.reset = reset
    }

    private static let ack: UInt8 = 0x79
    private static let nack: UInt8 = 0x1F

    public func flash(_ image: FirmwareImage, link: any ISPLink, events: @Sendable (ISPEvent) -> Void) async throws {
        guard image.byteCount > 0 else { throw ISPError("The HEX file contains no data.") }
        let started = ContinuousClock.now
        try await link.setLine(baudRate: speed.rawValue, parity: .even)
        events(.log("Start connecting MCU... Click “Stop” to exit."))
        try await connect(link: link, events: events)

        let commands = try await getCommands(link)
        if let pid = try? await getID(link) {
            events(.log(String(format: "MCU TYPE: 0x%04X", pid)))
        }
        if let (version, opt1, opt2) = try? await getVersion(link) {
            events(.log(String(format: "Bootloader V%d.%d, Protection state: 0x%02X 0x%02X", version >> 4, version & 0xF, opt1, opt2)))
        }
        events(.log("Connected to the MCU. Erasing..."))
        try await erase(link, extended: commands.contains(0x44) && !commands.contains(0x43))
        events(.log("Erased OK! Start download..."))

        let total = image.byteCount
        var done = 0
        events(.progress(done: 0, total: total))
        for block in image.blocks {
            let base = block.address < flashBase ? block.address + flashBase : block.address
            var offset = 0
            while offset < block.data.count {
                try Task.checkCancellation()
                let chunk = Array(block.data[offset..<min(offset + 256, block.data.count)])
                try await writeMemory(link, address: base + UInt32(offset), data: chunk)
                offset += chunk.count
                done += chunk.count
                events(.progress(done: done, total: total))
            }
        }

        let goAddress = image.lowestAddress.map { $0 < flashBase ? $0 + flashBase : $0 } ?? flashBase
        if reset.mode == .manual {
            try await go(link, address: goAddress)
        } else {
            // Release BOOT0 and reset so the part also boots user code on later resets.
            try? await go(link, address: goAddress)
            try await reset.reset(boot: false, on: link)
        }
        let seconds = (ContinuousClock.now - started).components.seconds
        events(.log("Wrote \(total) bytes, used \(seconds) s."))
        events(.log("User's program is running!"))
    }

    private func connect(link: any ISPLink, events: @Sendable (ISPEvent) -> Void) async throws {
        try await reset.reset(boot: true, on: link)
        for attempt in 1...60 {
            try Task.checkCancellation()
            await link.discardInput()
            try await link.send([0x7F])
            if let reply = try? await link.read(1, timeout: .milliseconds(200)), reply[0] == Self.ack || reply[0] == Self.nack {
                // NACK means the bootloader was already synchronised from an earlier attempt.
                return
            }
            if attempt.isMultiple(of: 10) {
                events(.log("Still waiting for the bootloader..."))
                try await reset.reset(boot: true, on: link)
            }
        }
        throw ISPError("""
            Can not connect.
            1. Power off? Wrong serial port?
            2. Are RXD, TXD, DTR and RTS wired correctly?
            3. Try the slower speed.
            4. In manual mode, is the MCU in ISP (bootloader) mode?
            """)
    }

    private func command(_ link: any ISPLink, _ code: UInt8, timeout: Duration = .seconds(1)) async throws {
        try await link.send([code, ~code])
        try await expectAck(link, timeout: timeout, what: String(format: "command 0x%02X", code))
    }

    private func expectAck(_ link: any ISPLink, timeout: Duration = .seconds(1), what: String) async throws {
        let b: UInt8
        do {
            b = try await link.read(1, timeout: timeout)[0]
        } catch is ReplyTimeout {
            throw ISPError("No reply from the MCU (\(what)).")
        }
        guard b == Self.ack else {
            throw ISPError(String(format: "Data check error (ACK error 0x%02X during %@).", b, what))
        }
    }

    private func getCommands(_ link: any ISPLink) async throws -> [UInt8] {
        try await command(link, 0x00)
        let n = Int(try await link.read(1, timeout: .seconds(1))[0])
        let body = try await link.read(n + 1, timeout: .seconds(1))
        try await expectAck(link, what: "Get")
        return Array(body.dropFirst())
    }

    private func getID(_ link: any ISPLink) async throws -> Int {
        try await command(link, 0x02)
        let n = Int(try await link.read(1, timeout: .seconds(1))[0])
        let pid = try await link.read(n + 1, timeout: .seconds(1))
        try await expectAck(link, what: "Get ID")
        return pid.reduce(0) { $0 << 8 | Int($1) }
    }

    private func getVersion(_ link: any ISPLink) async throws -> (UInt8, UInt8, UInt8) {
        try await command(link, 0x01)
        let r = try await link.read(3, timeout: .seconds(1))
        try await expectAck(link, what: "Get Version")
        return (r[0], r[1], r[2])
    }

    private func erase(_ link: any ISPLink, extended: Bool) async throws {
        if extended {
            try await command(link, 0x44)
            try await link.send([0xFF, 0xFF, 0x00])
        } else {
            try await command(link, 0x43)
            try await link.send([0xFF, 0x00])
        }
        // Mass erase of large parts can take many seconds.
        do {
            try await expectAck(link, timeout: .seconds(40), what: "Erase")
        } catch {
            throw ISPError("Erase failed. The chip may be read-protected. (\(error.localizedDescription))")
        }
    }

    private func sendAddress(_ link: any ISPLink, _ address: UInt32) async throws {
        let a = [UInt8(address >> 24), UInt8((address >> 16) & 0xFF), UInt8((address >> 8) & 0xFF), UInt8(address & 0xFF)]
        try await link.send(a + [Checksum.xor8(a)])
        try await expectAck(link, what: String(format: "address 0x%08X", address))
    }

    private func writeMemory(_ link: any ISPLink, address: UInt32, data: [UInt8]) async throws {
        var data = data
        while !data.count.isMultiple(of: 4) { data.append(0xFF) }
        try await command(link, 0x31)
        try await sendAddress(link, address)
        let frame = [UInt8(data.count - 1)] + data
        try await link.send(frame + [Checksum.xor8(frame)])
        try await expectAck(link, timeout: .seconds(2), what: String(format: "write at 0x%08X", address))
    }

    private func go(_ link: any ISPLink, address: UInt32) async throws {
        try await command(link, 0x21)
        try await sendAddress(link, address)
    }
}
