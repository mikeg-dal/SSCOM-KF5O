public import Foundation
import Synchronization

/// Events every transport reports to the session.
public enum TransportEvent: Sendable {
    /// The link is up. The string describes it for the status bar.
    case opened(String)
    case received([UInt8])
    /// A human-readable status change (for example a TCP server accepting a client).
    case status(String)
    /// The link went down. `error` is nil for a normal close.
    case closed(error: String?)
    /// Serial modem input lines changed.
    case modemLines(ModemLines)
}

public struct ModemLines: Sendable, Equatable, OptionSet {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }

    public static let cts = ModemLines(rawValue: 0x020)  // TIOCM_CTS
    public static let dsr = ModemLines(rawValue: 0x100)  // TIOCM_DSR
    public static let dcd = ModemLines(rawValue: 0x040)  // TIOCM_CD
    public static let ring = ModemLines(rawValue: 0x080) // TIOCM_RI
}

public struct TransportError: Error, LocalizedError, Sendable {
    public var message: String
    /// The POSIX error code, when the failure came from a system call.
    public var code: Int32?
    public init(_ message: String, code: Int32? = nil) {
        self.message = message
        self.code = code
    }
    public var errorDescription: String? { message }

    static func posix(_ what: String, _ code: Int32 = errno) -> TransportError {
        TransportError("\(what): \(String(cString: strerror(code)))", code: code)
    }
}

/// A byte link: a serial port, TCP client/server or UDP socket.
public protocol ByteTransport: AnyObject, Sendable {
    /// Events for this transport. A transport produces one stream for its lifetime.
    var events: AsyncStream<TransportEvent> { get }
    func open() async throws
    func write(_ bytes: [UInt8]) async throws
    func close()
}

/// A byte buffer that lets protocol code (the ISP flashers) await replies with timeouts.
///
/// `append` is synchronous so received bytes are queued strictly in arrival order.
public final class ReplyBuffer: Sendable {
    private struct State {
        var bytes: [UInt8] = []
        var waiter: (id: UInt64, count: Int, continuation: CheckedContinuation<Void, Never>)?
        var nextID: UInt64 = 0
    }
    private let state = Mutex(State())

    public init() {}

    public func append(_ new: [UInt8]) {
        let ready: CheckedContinuation<Void, Never>? = state.withLock { s in
            s.bytes += new
            guard let w = s.waiter, s.bytes.count >= w.count else { return nil }
            s.waiter = nil
            return w.continuation
        }
        ready?.resume()
    }

    public func clear() { state.withLock { $0.bytes.removeAll() } }

    public var available: Int { state.withLock { $0.bytes.count } }

    /// Reads exactly `count` bytes, or throws `ReplyTimeout` after `timeout`.
    public func read(_ count: Int, timeout: Duration) async throws -> [UInt8] {
        if let bytes = take(count) { return bytes }
        let id = state.withLock { s in s.nextID += 1; return s.nextID }
        let deadline = Task { [weak self] in
            try await Task.sleep(for: timeout)
            self?.wake(id)
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { s -> Bool in
                    if s.bytes.count >= count { return true }
                    s.waiter = (id, count, c)
                    return false
                }
                if resumeNow { c.resume() }
            }
        } onCancel: {
            wake(id)
        }
        deadline.cancel()
        try Task.checkCancellation()
        guard let bytes = take(count) else { throw ReplyTimeout() }
        return bytes
    }

    private func take(_ count: Int) -> [UInt8]? {
        state.withLock { s in
            guard s.bytes.count >= count else { return nil }
            defer { s.bytes.removeFirst(count) }
            return Array(s.bytes.prefix(count))
        }
    }

    private func wake(_ id: UInt64) {
        let c: CheckedContinuation<Void, Never>? = state.withLock { s in
            guard let w = s.waiter, w.id == id else { return nil }
            s.waiter = nil
            return w.continuation
        }
        c?.resume()
    }
}

public struct ReplyTimeout: Error, LocalizedError, Sendable {
    public var errorDescription: String? { "Timed out waiting for a reply." }
}
