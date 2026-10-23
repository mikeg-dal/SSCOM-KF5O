public import Foundation
public import Network
import Synchronization

/// TCP client, like SSCOM's "TCPClient" mode.
public final class TCPClientTransport: ByteTransport {
    public let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let host: String
    private let port: UInt16
    private let localPort: UInt16?
    private let queue = DispatchQueue(label: "tcp.client")

    /// How long a new connection may sit in "waiting" before it's reported as failed.
    static let waitingGrace: DispatchTimeInterval = .seconds(6)

    /// "Network down" is what a connection reports while macOS checks Local Network permission.
    static func isTransient(_ error: NWError) -> Bool {
        if case .posix(let code) = error { return code == .ENETDOWN }
        return false
    }
    private let connection: Mutex<NWConnection?> = Mutex(nil)

    public init(host: String, port: UInt16, localPort: UInt16? = nil) {
        self.host = host
        self.port = port
        self.localPort = localPort
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    public func open() async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw TransportError("Invalid port.") }
        let params = NWParameters.tcp
        if let localPort, localPort != 0, let lp = NWEndpoint.Port(rawValue: localPort) {
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.any), port: lp)
            params.allowLocalEndpointReuse = true
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        connection.withLock { $0 = conn }
        let opened = Mutex(false)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if opened.withLock({ o in defer { o = true }; return !o }) {
                        let local = conn.currentPath?.localEndpoint.map { "\($0)" } ?? "?"
                        self.continuation.yield(.opened("TCPClient local \(local) → remote \(self.host):\(self.port)"))
                        self.receive(on: conn)
                        cont.resume()
                    }
                case .waiting(let error) where Self.isTransient(error) && !opened.withLock({ $0 }):
                    // The first connection after launch waits with "network down" while macOS checks
                    // Local Network permission, then becomes ready. Give it a few seconds.
                    self.queue.asyncAfter(deadline: .now() + Self.waitingGrace) {
                        if opened.withLock({ o in defer { o = true }; return !o }) {
                            conn.cancel()
                            cont.resume(throwing: TransportError("TCPClient error: \(error.localizedDescription)"))
                        }
                    }
                case .failed(let error), .waiting(let error):
                    if opened.withLock({ o in defer { o = true }; return !o }) {
                        conn.cancel()
                        cont.resume(throwing: TransportError("TCPClient error: \(error.localizedDescription)"))
                    } else {
                        conn.cancel()
                        self.continuation.yield(.closed(error: error.localizedDescription))
                    }
                case .cancelled:
                    if opened.withLock({ $0 }) { self.continuation.yield(.closed(error: nil)) }
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.continuation.yield(.received(Array(data))) }
            if isComplete || error != nil {
                conn.cancel()
            } else {
                self.receive(on: conn)
            }
        }
    }

    public func write(_ bytes: [UInt8]) async throws {
        guard let conn = connection.withLock({ $0 }) else { throw TransportError("Not connected.") }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            conn.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    public func close() {
        connection.withLock { $0?.cancel(); $0 = nil }
    }
}

/// TCP server, like SSCOM's "TCPServer" mode. Sent data goes to every connected client.
public final class TCPServerTransport: ByteTransport {
    public let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let port: UInt16
    private let localHost: String?
    private let queue = DispatchQueue(label: "tcp.server")
    private struct State {
        var listener: NWListener?
        var clients: [ObjectIdentifier: NWConnection] = [:]
    }
    private let state = Mutex(State())

    /// - Parameter localHost: address to listen on, or nil for all interfaces.
    public init(port: UInt16, localHost: String? = nil) {
        self.port = port
        self.localHost = localHost
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    public var clientCount: Int { state.withLock { $0.clients.count } }

    public func open() async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw TransportError("Invalid port.") }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if let localHost, !localHost.isEmpty, localHost != "0.0.0.0" {
            params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(localHost), port: nwPort)
        }
        let listener: NWListener
        do {
            listener = params.requiredLocalEndpoint == nil
                ? try NWListener(using: params, on: nwPort)
                : try NWListener(using: params)
        } catch {
            throw TransportError("TCPServer error: \(error.localizedDescription)")
        }
        state.withLock { $0.listener = listener }
        let started = Mutex(false)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { [weak self] st in
                guard let self else { return }
                switch st {
                case .ready:
                    if started.withLock({ s in defer { s = true }; return !s }) {
                        let where_ = self.localHost.flatMap { $0.isEmpty ? nil : $0 } ?? "all addresses"
                        self.continuation.yield(.opened("TCPServer listening on \(where_):\(self.port)"))
                        cont.resume()
                    }
                case .failed(let error):
                    if started.withLock({ s in defer { s = true }; return !s }) {
                        cont.resume(throwing: TransportError("TCPServer error: \(error.localizedDescription)"))
                    } else {
                        self.continuation.yield(.closed(error: error.localizedDescription))
                    }
                    listener.cancel()
                case .cancelled:
                    if started.withLock({ $0 }) { self.continuation.yield(.closed(error: nil)) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener.start(queue: queue)
        }
    }

    private func accept(_ conn: NWConnection) {
        let key = ObjectIdentifier(conn)
        state.withLock { $0.clients[key] = conn }
        conn.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.continuation.yield(.status("TCPServer: client connected from \(conn.endpoint)"))
                self.receive(on: conn)
            case .failed, .cancelled:
                if self.state.withLock({ $0.clients.removeValue(forKey: key) }) != nil {
                    self.continuation.yield(.status("TCPServer: client \(conn.endpoint) disconnected"))
                }
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.continuation.yield(.received(Array(data))) }
            if isComplete || error != nil { conn.cancel() } else { self.receive(on: conn) }
        }
    }

    public func write(_ bytes: [UInt8]) async throws {
        let clients = state.withLock { Array($0.clients.values) }
        guard !clients.isEmpty else { throw TransportError("No client is connected.") }
        for conn in clients {
            conn.send(content: Data(bytes), completion: .idempotent)
        }
    }

    public func close() {
        let (listener, clients) = state.withLock { s in
            defer { s.listener = nil; s.clients.removeAll() }
            return (s.listener, Array(s.clients.values))
        }
        clients.forEach { $0.cancel() }
        listener?.cancel()
    }
}

/// UDP, like SSCOM's "UDP" mode: binds a local port, receives from anyone,
/// and sends to the configured remote host and port. Uses a BSD socket so
/// replies from any peer arrive on the same local port.
public final class UDPTransport: ByteTransport {
    public let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let remoteHost: String
    private let remotePort: UInt16
    private let localPort: UInt16
    private let queue = DispatchQueue(label: "udp")
    private struct State {
        var fd: Int32 = -1
        var source: (any DispatchSourceRead)?
        var remote: sockaddr_storage?
        var remoteLength: socklen_t = 0
    }
    private let state = Mutex(State())

    public init(remoteHost: String, remotePort: UInt16, localPort: UInt16) {
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.localPort = localPort
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    public func open() async throws {
        let (remote, length) = try await Self.resolve(remoteHost, remotePort)
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw TransportError.posix("socket") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = localPort.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            let e = errno
            Darwin.close(fd)
            throw TransportError.posix("Unable to bind UDP port \(localPort)", e)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        state.withLock {
            $0.fd = fd
            $0.source = source
            $0.remote = remote
            $0.remoteLength = length
        }
        source.resume()
        continuation.yield(.opened("UDP local port \(localPort) ↔ remote \(remoteHost):\(remotePort)"))
    }

    private static func resolve(_ host: String, _ port: UInt16) async throws -> (sockaddr_storage, socklen_t) {
        try await Task.detached {
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_DGRAM
            var result: UnsafeMutablePointer<addrinfo>?
            let rc = getaddrinfo(host, String(port), &hints, &result)
            guard rc == 0, let info = result else {
                throw TransportError("UDP remote IP error: \(String(cString: gai_strerror(rc)))")
            }
            defer { freeaddrinfo(result) }
            var storage = sockaddr_storage()
            memcpy(&storage, info.pointee.ai_addr, Int(info.pointee.ai_addrlen))
            return (storage, info.pointee.ai_addrlen)
        }.value
    }

    private func readAvailable() {
        let fd = state.withLock { $0.fd }
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            guard n > 0 else { return }
            continuation.yield(.received(Array(buffer[..<n])))
        }
    }

    public func write(_ bytes: [UInt8]) async throws {
        let (fd, remote, length) = state.withLock { ($0.fd, $0.remote, $0.remoteLength) }
        guard fd >= 0, var remote else { throw TransportError("UDP socket is not open.") }
        let sent = bytes.withUnsafeBytes { buf in
            withUnsafePointer(to: &remote) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, length)
                }
            }
        }
        if sent < 0 { throw TransportError.posix("UDP send failed") }
    }

    public func close() {
        let (fd, source) = state.withLock { s in
            defer { s.fd = -1; s.source = nil }
            return (s.fd, s.source)
        }
        guard fd >= 0 else { return }
        source?.cancel()
        Darwin.close(fd)
        continuation.yield(.closed(error: nil))
    }
}

public enum NetworkInterfaces {
    /// IPv4 addresses of this Mac, for the TCP server's local IP list.
    public static func ipv4Addresses() -> [String] {
        var result: [String] = ["0.0.0.0", "127.0.0.1"]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return result }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let s = String(decoding: host.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
                if !result.contains(s) { result.append(s) }
            }
        }
        return result
    }
}
