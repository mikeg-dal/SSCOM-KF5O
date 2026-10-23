import Foundation
import Testing
@testable import SSCOMKit

@Suite struct ChecksumTests {
    let check = Array("123456789".utf8)

    @Test func standardCheckValues() {
        #expect(Checksum.modbusCRC16(check) == 0x4B37)
        #expect(Checksum.ccittCRC16(check) == 0x31C3) // CRC-16/XMODEM
        #expect(Checksum.crc32(check) == 0xCBF4_3926)
    }

    @Test func outputByteOrderMatchesSSCOM() {
        #expect(ChecksumKind.modbusCRC16.bytes(for: check) == [0x37, 0x4B])
        #expect(ChecksumKind.ccittCRC16.bytes(for: check) == [0xC3, 0x31])
        #expect(ChecksumKind.crc32.bytes(for: check) == [0x26, 0x39, 0xF4, 0xCB])
        #expect(ChecksumKind.add16.bytes(for: [0xFF, 0xFF, 0x03]) == [0x02, 0x01])
        #expect(ChecksumKind.add8.bytes(for: [0xFF, 0x03]) == [0x02])
        #expect(ChecksumKind.zeroAdd8.bytes(for: [0x01, 0x02]) == [0xFD])
    }

    /// The worked example from SSCOM's own checksum help text.
    @Test func helpExampleXor8() throws {
        let result = try PayloadBuilder.build(
            "AA 55 06 FF 00 30 88 99 AB EE", hex: true,
            options: SendOptions(checksum: .xor8, placement: .init(firstByte: 3, trailerBytes: 1)))
        #expect(HexCodec.format(result.frame) == "AA 55 06 FF 00 30 88 99 AB 73 EE ")
    }

    @Test func emptyRangeAddsNothing() {
        let r = ChecksumKind.add8.apply(to: [1, 2], placement: .init(firstByte: 3, trailerBytes: 0))
        #expect(r.rangeWasEmpty)
        #expect(r.frame == [1, 2])
    }

    @Test func modbusFrame() throws {
        // Read holding registers: 01 03 00 00 00 0A -> CRC C5 CD
        let r = try PayloadBuilder.build("01 03 00 00 00 0A", hex: true, options: SendOptions(checksum: .modbusCRC16))
        #expect(r.checksum == [0xC5, 0xCD])
    }
}

@Suite struct PayloadTests {
    @Test func hexParsing() throws {
        #expect(try HexCodec.parse("12 00 FF 80") == [0x12, 0x00, 0xFF, 0x80])
        #expect(try HexCodec.parse("ff81 55 a") == [0xFF, 0x81, 0x55, 0x0A])
        #expect(throws: PayloadError.invalidHex(token: "GG")) { try HexCodec.parse("12 GG") }
        #expect(throws: PayloadError.invalidHex(token: "123")) { try HexCodec.parse("123") }
    }

    @Test func escapes() throws {
        let b = try EscapeParser.encode(#"A\r\n\x41\\\t\0\q"#, encoding: .utf8)
        #expect(b == [0x41, 0x0D, 0x0A, 0x41, 0x5C, 0x09, 0x00, 0x5C, 0x71])
    }

    @Test func crlfIsIncludedInChecksum() throws {
        let r = try PayloadBuilder.build("A", hex: false, options: SendOptions(appendCRLF: true, checksum: .add8))
        #expect(r.frame == [0x41, 0x0D, 0x0A, 0x58])
    }

    @Test func gb18030Text() throws {
        let r = try PayloadBuilder.build("中", hex: false, options: SendOptions(encoding: .gb18030))
        #expect(r.frame == [0xD6, 0xD0])
    }
}

@Suite struct DisplayTests {
    @Test func packetSplittingAndMarkers() {
        var log = TrafficLog()
        let t0 = Date(timeIntervalSince1970: 0)
        log.append(Array("help".utf8), direction: .sent, at: t0, packetTimeout: 0.02)
        log.append(Array("Wel".utf8), direction: .received, at: t0.addingTimeInterval(0.05), packetTimeout: 0.02)
        log.append(Array("come".utf8), direction: .received, at: t0.addingTimeInterval(0.06), packetTimeout: 0.02)
        log.append(Array("!".utf8), direction: .received, at: t0.addingTimeInterval(0.2), packetTimeout: 0.02)
        #expect(log.segments.count == 3)
        var r = TrafficRenderer(options: DisplayOptions(hex: false, timestamps: true, chinese: true))
        let text = r.render(log)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[0].hasSuffix("] 发 help"))
        #expect(lines[1].hasSuffix("] 收 Welcome"))
        #expect(lines[0].hasPrefix("["))
    }

    @Test func timestampIs24Hour() {
        let d = Date(timeIntervalSince1970: 19 * 3600 + 36 * 60 + 5.123)
        #expect(TrafficRenderer.timestamp(d, timeZone: TimeZone(identifier: "UTC")!) == "19:36:05.123")
    }

    @Test func noBlankLineAfterCRLF() {
        var log = TrafficLog()
        let t0 = Date(timeIntervalSince1970: 0)
        log.append(Array("A\r\n".utf8), direction: .received, at: t0, packetTimeout: 0.02)
        log.append(Array("B".utf8), direction: .received, at: t0.addingTimeInterval(1), packetTimeout: 0.02)
        var r = TrafficRenderer(options: DisplayOptions(timestamps: true))
        let lines = r.render(log).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        #expect(lines.count == 2)
    }

    @Test func plainModeHidesSentData() {
        var log = TrafficLog()
        log.append([0x41], direction: .sent, at: .now, packetTimeout: 0.02)
        log.append([0x42, 0x43], direction: .received, at: .now, packetTimeout: 0.02)
        var r = TrafficRenderer(options: DisplayOptions(hex: true, timestamps: false))
        #expect(r.render(log) == "42 43 ")
    }

    @Test func splitUTF8IsJoined() {
        var d = StreamingTextDecoder(encoding: .utf8)
        let bytes = Array("é中".utf8)
        let a = d.decode(Array(bytes[0..<1]))
        let b = d.decode(Array(bytes[1..<3]))
        let c = d.decode(Array(bytes[3...]))
        #expect(a + b + c == "é中")
        #expect(a.isEmpty)
    }

    @Test func splitGB18030IsJoined() {
        var d = StreamingTextDecoder(encoding: .gb18030)
        #expect(d.decode([0x41, 0xD6]) == "A")
        #expect(d.decode([0xD0]) == "中")
    }

    @Test func trimKeepsNewestData() {
        var log = TrafficLog(limit: 1000)
        log.retainAfterTrim = 100
        for i in 0..<17 {
            log.append([UInt8](repeating: UInt8(i), count: 60), direction: .sent, at: .now, packetTimeout: 0)
        }
        #expect(log.byteCount == 100)
        #expect(log.segments.last?.bytes.first == 16)
    }
}

@Suite struct FileFormatTests {
    @Test func intelHex() throws {
        let text = """
        :020000040800F2
        :10000000000102030405060708090A0B0C0D0E0F78
        :0400100010111213A6
        :00000001FF
        """
        let image = try IntelHex.parse(text)
        #expect(image.blocks.count == 1)
        #expect(image.blocks[0].address == 0x0800_0000)
        #expect(image.byteCount == 20)
    }

    @Test func intelHexRejectsBadChecksum() {
        #expect(throws: IntelHexError.badChecksum(line: 1)) {
            try IntelHex.parse(":0400100010111213AB")
        }
    }

    @Test func legacyIni() {
        let ini = """
        N101=1,十六进制数据串1,1000
        N1=H,13 00 FF 88
        N102=3,note, with comma,250
        N2=A,output string
        N1081=,115200
        N1064=,Y
        """
        let s = LegacyIniImporter.parse(ini)
        #expect(s.presets.count == 99)
        #expect(s.presets[0] == PresetString(id: 1, hex: true, text: "13 00 FF 88", note: "十六进制数据串1", order: 1, delayMs: 1000))
        #expect(s.presets[1].note == "note, with comma")
        #expect(s.presets[1].delayMs == 250)
        #expect(s.baudRate == 115_200)
        #expect(s.timestamps == true)
    }

    @Test func controlBytesAreVisible() {
        #expect(TrafficRenderer.visibleControls("\u{01}\u{05}A\u{00}\u{7F}") == "<01><05>A<00><7F>")
        #expect(TrafficRenderer.visibleControls("line\r\n\tend") == "line\r\n\tend")
        #expect(TrafficRenderer.visibleControls("plain") == "plain")
    }

    @Test func iniChecksumSetting() {
        let rtu = LegacyIniImporter.parse("N101=0,on,1000\nN1=H,01 05 00 00 FF 00\nN1060=,1")
        #expect(rtu.effectiveChecksumKind == .modbusCRC16)
        // Waveshare's modbus tcp.ini asks for ModbusCRC16 on Modbus TCP frames; that's corrected to None.
        let tcp = LegacyIniImporter.parse("N101=0,on,1000\nN1=H,00 00 00 00 00 06 01 05 00 00 FF 00\nN1060=,1")
        #expect(tcp.effectiveChecksumKind == ChecksumKind.none)
    }

    /// The relay presets, with the checksum applied, match the frames in Waveshare's wiki.
    @Test func relayPresetsMatchWiki() throws {
        func frame(_ set: PresetSet, _ slot: Int) throws -> String {
            let p = set.presets[slot - 1]
            let r = try PayloadBuilder.build(p.text, hex: true, options: SendOptions(hexMode: true, checksum: set.checksum))
            return r.frame.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
        let rtu = PresetLibrary.relayRTU
        #expect(try frame(rtu, 1) == "01 05 00 00 FF 00 8C 3A")
        #expect(try frame(rtu, 2) == "01 05 00 00 00 00 CD CA")
        #expect(try frame(rtu, 18) == "01 05 00 00 55 00 F2 9A")
        #expect(try frame(rtu, 23) == "01 05 00 FF FF 00 BC 0A")
        #expect(try frame(rtu, 27) == "01 0F 00 00 00 08 01 FF BE D5")
        #expect(try frame(rtu, 31) == "01 05 02 00 00 07 8D B0")
        #expect(try frame(rtu, 36) == "01 01 00 00 00 08 3D CC")
        #expect(try frame(rtu, 37) == "01 02 00 00 00 08 79 CC")
        #expect(try frame(rtu, 40) == "01 06 10 00 00 01 4C CA")
        #expect(try frame(rtu, 42) == "01 10 10 00 00 08 10 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 0B 5C")
        let tcp = PresetLibrary.relayTCP
        #expect(try frame(tcp, 1) == "00 00 00 00 00 06 01 05 00 00 FF 00")
        #expect(try frame(tcp, 41).hasPrefix("00 00 00 00 00 17 01 10 10 00"))
        #expect(rtu.presets.filter { !$0.text.isEmpty }.count == 38)
    }

    @Test func loopOrder() {
        var p = PresetString.defaults()
        p[5] = PresetString(id: 6, text: "x", order: 1)
        let seq = PresetString.loopSequence(p).map(\.id)
        #expect(seq == [1, 6, 3, 2])
    }

    @Test func stcFrames() {
        #expect(STCFlasher.frame([0x05, 0x00, 0x00, 0x5A, 0xA5]) ==
                [0x46, 0xB9, 0x6A, 0x00, 0x0B, 0x05, 0x00, 0x00, 0x5A, 0xA5, 0x01, 0x79, 0x16])
        #expect(STCFlasher.frame([0x03, 0x00, 0x00, 0x5A, 0xA5]).suffix(3) == [0x01, 0x77, 0x16])
        let speed = STCFlasher.frame([0x01, 0x63, 0x40, 0xFF, 0xD0, 0x00, 0x00, 0xC3])
        #expect(speed.count == 16 && speed[4] == 0x0E)
        var block = [0x22, 0x00, 0x00, 0x5A, 0xA5] + [UInt8](repeating: 0, count: 128)
        #expect(STCFlasher.frame(block).count == 0x8D)
        block[0] = 0x02
        #expect(STCFlasher.frame(block)[4] == 0x8B)
    }

    @Test func stcLayoutPadsToBlocks() {
        let image = FirmwareImage(blocks: [.init(address: 2, data: [1, 2, 3])], startAddress: nil)
        let b = STCFlasher.layout(image)
        #expect(b.count == 128)
        #expect(b[0] == 0xFF && b[2] == 1 && b[4] == 3 && b[5] == 0xFF)
    }
}

@Suite struct ReplyBufferTests {
    @Test func readsAndTimesOut() async throws {
        let buf = ReplyBuffer()
        buf.append([1, 2, 3])
        #expect(try await buf.read(2, timeout: .milliseconds(10)) == [1, 2])
        await #expect(throws: ReplyTimeout.self) { try await buf.read(2, timeout: .milliseconds(20)) }
        Task { try? await Task.sleep(for: .milliseconds(10)); buf.append([4]) }
        #expect(try await buf.read(2, timeout: .seconds(1)) == [3, 4])
    }
}
