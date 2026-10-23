import Darwin
import Foundation
import Testing
@testable import SSCOMKit

/// Collects `.received` bytes from a transport until `count` bytes arrive.
private func collect(_ t: any ByteTransport, count: Int) async -> [UInt8] {
    var out: [UInt8] = []
    for await e in t.events {
        if case .received(let b) = e { out += b }
        if out.count >= count { break }
    }
    return out
}

private func withTimeout<T: Sendable>(_ seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { g in
        g.addTask { try await body() }
        g.addTask { try await Task.sleep(for: .seconds(seconds)); throw ReplyTimeout() }
        let r = try await g.next()!
        g.cancelAll()
        return r
    }
}

@Suite(.serialized) struct TransportTests {
    @Test func tcpServerAndClientExchangeData() async throws {
        let port = UInt16.random(in: 40_000...50_000)
        let server = TCPServerTransport(port: port)
        try await server.open()
        let client = TCPClientTransport(host: "127.0.0.1", port: port)
        try await client.open()
        // Wait for the server to register the client.
        for _ in 0..<50 where server.clientCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(server.clientCount == 1)

        let atServer = Task { await collect(server, count: 5) }
        try await client.write(Array("hello".utf8))
        #expect(try await withTimeout(3) { await atServer.value } == Array("hello".utf8))

        let atClient = Task { await collect(client, count: 3) }
        try await server.write([1, 2, 3])
        #expect(try await withTimeout(3) { await atClient.value } == [1, 2, 3])
        client.close()
        server.close()
    }

    @Test func udpLoopback() async throws {
        let a = UInt16.random(in: 50_001...55_000)
        let b = a + 1
        let x = UDPTransport(remoteHost: "127.0.0.1", remotePort: b, localPort: a)
        let y = UDPTransport(remoteHost: "localhost", remotePort: a, localPort: b)
        try await x.open()
        try await y.open()
        let atY = Task { await collect(y, count: 4) }
        try await x.write([0xDE, 0xAD, 0xBE, 0xEF])
        #expect(try await withTimeout(3) { await atY.value } == [0xDE, 0xAD, 0xBE, 0xEF])
        x.close()
        y.close()
    }

    /// Drives SerialPort through a pseudo-terminal: the "device" end echoes in uppercase.
    @Test func serialPortOverPTY() async throws {
        var master: Int32 = 0, slave: Int32 = 0
        var name = [CChar](repeating: 0, count: 128)
        try #require(openpty(&master, &slave, &name, nil, nil) == 0)
        defer { close(master); close(slave) }
        let path = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)

        let port = SerialPort(path: path, settings: SerialSettings(baudRate: 115_200, dtr: false))
        try await port.open()
        try await port.write(Array("ping".utf8))
        var buf = [UInt8](repeating: 0, count: 16)
        var got = 0
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        for _ in 0..<100 where got < 4 {
            let n = buf.withUnsafeMutableBytes { read(master, $0.baseAddress! + got, 16 - got) }
            if n > 0 { got += n } else { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(Array(buf[0..<4]) == Array("ping".utf8))

        let back = Task { await collect(port, count: 4) }
        _ = write(master, "PONG", 4)
        #expect(try await withTimeout(3) { await back.value } == Array("PONG".utf8))
        port.close()
    }
}
