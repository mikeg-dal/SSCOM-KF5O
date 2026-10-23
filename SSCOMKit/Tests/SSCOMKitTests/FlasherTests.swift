import Foundation
import Synchronization
import Testing
@testable import SSCOMKit

/// A fake STM32 USART bootloader (AN3155) that records what gets written to flash.
final class FakeSTM32: ISPLink, @unchecked Sendable {
    private let replies = ReplyBuffer()
    private let lock = Mutex<State>(State())
    struct State {
        var pending: [UInt8] = []
        var expect: Expect = .command
        var flash: [UInt32: UInt8] = [:]
        var address: UInt32 = 0
        var erased = false
        var wentTo: UInt32?
    }
    enum Expect { case command, eraseArgs(extended: Bool), address(next: UInt8), writeData, goneAddress }

    var flash: [UInt32: UInt8] { lock.withLock { $0.flash } }
    var erased: Bool { lock.withLock { $0.erased } }
    var wentTo: UInt32? { lock.withLock { $0.wentTo } }

    func send(_ bytes: [UInt8]) async throws {
        let out: [UInt8] = lock.withLock { s in
            s.pending += bytes
            var out: [UInt8] = []
            while true {
                switch s.expect {
                case .command:
                    if s.pending.first == 0x7F { s.pending.removeFirst(); out.append(0x79); continue }
                    guard s.pending.count >= 2 else { return out }
                    let c = s.pending[0]
                    precondition(s.pending[1] == ~c, "bad command complement")
                    s.pending.removeFirst(2)
                    out.append(0x79)
                    switch c {
                    case 0x00: out += [3, 0x31, 0x00, 0x01, 0x02, 0x79] // version 3.1, Get/GetVersion/GetID, then ACK
                    case 0x01: out += [0x31, 0, 0, 0x79]
                    case 0x02: out += [1, 0x04, 0x10, 0x79]
                    case 0x43: s.expect = .eraseArgs(extended: false)
                    case 0x44: s.expect = .eraseArgs(extended: true)
                    case 0x31: s.expect = .address(next: 0x31)
                    case 0x21: s.expect = .address(next: 0x21)
                    default: out[out.count - 1] = 0x1F
                    }
                case .eraseArgs(let ext):
                    let n = ext ? 3 : 2
                    guard s.pending.count >= n else { return out }
                    s.pending.removeFirst(n)
                    s.erased = true
                    s.expect = .command
                    out.append(0x79)
                case .address(let next):
                    guard s.pending.count >= 5 else { return out }
                    let a = Array(s.pending.prefix(5)); s.pending.removeFirst(5)
                    precondition(Checksum.xor8(a.prefix(4)) == a[4], "bad address checksum")
                    s.address = a.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
                    out.append(0x79)
                    if next == 0x21 { s.wentTo = s.address; s.expect = .command } else { s.expect = .writeData }
                case .writeData:
                    guard let n = s.pending.first.map({ Int($0) + 1 }), s.pending.count >= n + 2 else { return out }
                    let frame = Array(s.pending.prefix(n + 2)); s.pending.removeFirst(n + 2)
                    precondition(Checksum.xor8(frame.dropLast()) == frame.last!, "bad data checksum")
                    for (i, b) in frame[1...n].enumerated() { s.flash[s.address + UInt32(i)] = b }
                    out.append(0x79)
                    s.expect = .command
                case .goneAddress:
                    return out
                }
            }
        }
        if !out.isEmpty { replies.append(out) }
    }

    func read(_ count: Int, timeout: Duration) async throws -> [UInt8] { try await replies.read(count, timeout: timeout) }
    func discardInput() async { replies.clear() }
    func setDTR(_ on: Bool) async throws {}
    func setRTS(_ on: Bool) async throws {}
    func setLine(baudRate: Int, parity: Parity) async throws {}
}

/// A fake STC15 bootloader following the frames SSCOM sends.
final class FakeSTC: ISPLink, @unchecked Sendable {
    private let replies = ReplyBuffer()
    private let lock = Mutex<State>(State())
    struct State {
        var pending: [UInt8] = []
        var synced = false
        var writes: [(cmd: UInt8, addr: Int, data: [UInt8])] = []
        var commands: [UInt8] = []
    }
    var writes: [(cmd: UInt8, addr: Int, data: [UInt8])] { lock.withLock { $0.writes } }
    var commands: [UInt8] { lock.withLock { $0.commands } }

    static func reply(_ body: [UInt8]) -> [UInt8] {
        var f: [UInt8] = [0x46, 0xB9, 0x68, 0x00, UInt8(body.count + 6)] + body
        let sum = Checksum.add16(f[2...])
        f += [UInt8(sum >> 8), UInt8(sum & 0xFF), 0x16]
        return f
    }

    func send(_ bytes: [UInt8]) async throws {
        let out: [UInt8] = lock.withLock { s in
            if !s.synced {
                guard bytes == [0x7F] else { return [] }
                s.synced = true
                // Status: cmd 0x50 then data; bytes 5...8 hold the oscillator count (little-endian here).
                return Self.reply([0x50, 0, 0, 0, 0, 0x00, 0x1B, 0xB7, 0x00, 0x72, 0x53])
            }
            s.pending += bytes
            guard s.pending.count >= 5 else { return [] }
            let total = Int(s.pending[3]) << 8 | Int(s.pending[4]) + 2
            guard s.pending.count >= total else { return [] }
            let f = Array(s.pending.prefix(total)); s.pending.removeFirst(total)
            precondition(f[0] == 0x46 && f[1] == 0xB9 && f[2] == 0x6A && f.last == 0x16)
            let sum = Checksum.add16(f[2..<(total - 3)])
            precondition(f[total - 3] == UInt8(sum >> 8) && f[total - 2] == UInt8(sum & 0xFF), "bad STC checksum")
            let cmd = f[5]
            s.commands.append(cmd)
            switch cmd {
            case 0x01: return Self.reply([0x01])
            case 0x05: return Self.reply([0x05])
            case 0x03: return Self.reply([0x03] + [UInt8](repeating: 0, count: 7))
            case 0x22, 0x02:
                s.writes.append((cmd, Int(f[6]) << 8 | Int(f[7]), Array(f[10..<(total - 3)])))
                return Self.reply([cmd, 0])
            default: return []
            }
        }
        if !out.isEmpty { replies.append(out) }
    }

    func read(_ count: Int, timeout: Duration) async throws -> [UInt8] { try await replies.read(count, timeout: timeout) }
    func discardInput() async { replies.clear() }
    func setDTR(_ on: Bool) async throws {}
    func setRTS(_ on: Bool) async throws {}
    func setLine(baudRate: Int, parity: Parity) async throws {}
}

@Suite struct FlasherTests {
    @Test func stm32WritesWholeImageAndStarts() async throws {
        let data = (0..<600).map { UInt8($0 & 0xFF) }
        let image = FirmwareImage(blocks: [.init(address: 0x0800_0000, data: data)], startAddress: nil)
        let fake = FakeSTM32()
        let log = Mutex<[String]>([])
        try await STM32Flasher(speed: .fast, reset: ResetControl(mode: .manual))
            .flash(image, link: fake) { e in if case .log(let s) = e { log.withLock { $0.append(s) } } }
        #expect(fake.erased)
        #expect(fake.wentTo == 0x0800_0000)
        let flash = fake.flash
        #expect((0..<600).allSatisfy { flash[0x0800_0000 + UInt32($0)] == data[$0] })
        #expect(log.withLock { $0.contains("MCU TYPE: 0x0410") })
    }

    @Test func stcFollowsSSCOMSequence() async throws {
        let image = FirmwareImage(blocks: [.init(address: 0, data: [UInt8](repeating: 0xAB, count: 200))], startAddress: nil)
        let fake = FakeSTC()
        let log = Mutex<[String]>([])
        try await STCFlasher(speed: .normal)
            .flash(image, link: fake, originalBaud: 115_200) { e in if case .log(let s) = e { log.withLock { $0.append(s) } } }
        #expect(fake.commands == [0x01, 0x05, 0x03, 0x22, 0x02])
        let writes = fake.writes
        #expect(writes.map(\.addr) == [0, 128])
        #expect(writes[1].data.prefix(72).allSatisfy { $0 == 0xAB })
        #expect(writes[1].data.suffix(56).allSatisfy { $0 == 0xFF })
        #expect(log.withLock { $0.contains { $0.contains("oscillator") } })
    }
}
