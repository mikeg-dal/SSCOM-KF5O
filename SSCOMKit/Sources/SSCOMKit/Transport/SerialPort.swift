public import Foundation
import Darwin
import Synchronization

public enum Parity: String, CaseIterable, Codable, Sendable, Identifiable {
    case none, odd, even
    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
}

public enum StopBits: Int, CaseIterable, Codable, Sendable, Identifiable {
    case one = 1, two = 2
    public var id: Int { rawValue }
}

public enum FlowControl: String, CaseIterable, Codable, Sendable, Identifiable {
    case none, hardware, software
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .none: "None"
        case .hardware: "Hardware (RTS/CTS)"
        case .software: "Software (XON/XOFF)"
        }
    }
}

public struct SerialSettings: Codable, Sendable, Equatable {
    public var baudRate: Int
    public var dataBits: Int
    public var parity: Parity
    public var stopBits: StopBits
    public var flowControl: FlowControl
    public var dtr: Bool
    public var rts: Bool

    public init(baudRate: Int = 115_200, dataBits: Int = 8, parity: Parity = .none, stopBits: StopBits = .one,
                flowControl: FlowControl = .none, dtr: Bool = true, rts: Bool = false) {
        self.baudRate = baudRate
        self.dataBits = dataBits
        self.parity = parity
        self.stopBits = stopBits
        self.flowControl = flowControl
        self.dtr = dtr
        self.rts = rts
    }

    /// SSCOM accepts custom rates from 110 bps up to 50 Mbps.
    public static let baudRange = 110...50_000_000
    public static let standardBaudRates = [
        300, 600, 1200, 2400, 4800, 9600, 14400, 19200, 38400, 56000, 57600, 115_200, 128_000,
        230_400, 256_000, 460_800, 500_000, 512_000, 600_000, 750_000, 921_600, 1_000_000,
        1_500_000, 2_000_000, 3_000_000,
    ]
}

// ioctl request codes. The C macros that build these aren't importable into Swift.
private let IOSSIOSPEED: UInt = 0x8008_5402 // _IOW('T', 2, speed_t)
private let TIOCMBIS: UInt = 0x8004_746C    // _IOW('t', 108, int)
private let TIOCMBIC: UInt = 0x8004_746B    // _IOW('t', 107, int)
private let TIOCMGET: UInt = 0x4004_746A    // _IOR('t', 106, int)
private let TIOCEXCL: UInt = 0x2000_740D    // _IO('t', 13)
private let TIOCM_DTR: Int32 = 0x002
private let TIOCM_RTS: Int32 = 0x004

/// A serial port opened through its BSD callout device (/dev/cu.*).
///
/// All file-descriptor work happens on one private serial queue; the Mutex only
/// guards the descriptor and settings so callers on any thread can query them.
public final class SerialPort: ByteTransport {
    public let path: String
    public let events: AsyncStream<TransportEvent>

    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let queue: DispatchQueue
    private struct State {
        var fd: Int32 = -1
        var settings: SerialSettings
        var readSource: (any DispatchSourceRead)?
        var lineTimer: (any DispatchSourceTimer)?
        var lastLines = ModemLines()
    }
    private let state: Mutex<State>

    public init(path: String, settings: SerialSettings) {
        self.path = path
        self.queue = DispatchQueue(label: "serial.\(path)", qos: .userInitiated)
        self.state = Mutex(State(settings: settings))
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    deinit { close() }

    public var settings: SerialSettings { state.withLock { $0.settings } }

    public func open() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                do {
                    try openOnQueue()
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func openOnQueue() throws {
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw TransportError.posix("Unable to open \(path)") }
        _ = ioctl(fd, TIOCEXCL)
        let settings = state.withLock { $0.settings }
        do {
            try Self.apply(settings, to: fd)
        } catch {
            Darwin.close(fd)
            throw error
        }
        tcflush(fd, TCIOFLUSH)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.pollModemLines() }
        state.withLock {
            $0.fd = fd
            $0.readSource = source
            $0.lineTimer = timer
        }
        source.resume()
        timer.resume()
        continuation.yield(.opened("\(path) \(settings.baudRate)bps"))
    }

    private static func apply(_ s: SerialSettings, to fd: Int32) throws {
        var t = termios()
        guard tcgetattr(fd, &t) == 0 else { throw TransportError.posix("tcgetattr") }
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(CSIZE | PARENB | PARODD | CSTOPB | CCTS_OFLOW | CRTS_IFLOW)
        let size: Int32 = switch s.dataBits { case 5: CS5; case 6: CS6; case 7: CS7; default: CS8 }
        t.c_cflag |= tcflag_t(size)
        switch s.parity {
        case .none: break
        case .even: t.c_cflag |= tcflag_t(PARENB)
        case .odd: t.c_cflag |= tcflag_t(PARENB | PARODD)
        }
        if s.stopBits == .two { t.c_cflag |= tcflag_t(CSTOPB) }
        t.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        switch s.flowControl {
        case .none: break
        case .hardware: t.c_cflag |= tcflag_t(CCTS_OFLOW | CRTS_IFLOW)
        case .software: t.c_iflag |= tcflag_t(IXON | IXOFF)
        }
        // Non-blocking reads: return whatever is available.
        withUnsafeMutableBytes(of: &t.c_cc) { cc in
            cc[Int(VMIN)] = 0
            cc[Int(VTIME)] = 0
        }
        // On macOS the termios speed fields hold the rate in bps, so standard rates
        // can be set directly; anything else needs the IOSSIOSPEED ioctl after tcsetattr.
        let standard = s.baudRate <= 230_400 && SerialSettings.standardBaudRates.contains(s.baudRate)
        cfsetspeed(&t, speed_t(standard ? s.baudRate : 9600))
        guard tcsetattr(fd, TCSANOW, &t) == 0 else { throw TransportError.posix("tcsetattr") }
        if !standard {
            var speed = speed_t(s.baudRate)
            guard ioctl(fd, IOSSIOSPEED, &speed) == 0 else {
                throw TransportError("This port does not support \(s.baudRate) bps. Please try 115200 bps.")
            }
        }
        // Devices without modem-control lines (ptys, some virtual ports) reject these; that's fine.
        do {
            try setLine(fd, TIOCM_DTR, on: s.dtr)
            if s.flowControl != .hardware { try setLine(fd, TIOCM_RTS, on: s.rts) }
        } catch let error as TransportError where error.code == ENOTTY || error.code == EINVAL {
            // No modem-control lines on this device.
        }
    }

    private static func setLine(_ fd: Int32, _ bit: Int32, on: Bool) throws {
        var bits = bit
        guard ioctl(fd, on ? TIOCMBIS : TIOCMBIC, &bits) == 0 else {
            throw TransportError.posix(bit == TIOCM_DTR ? "Unable to set DTR" : "Unable to set RTS")
        }
    }

    private func readAvailable() {
        let fd = state.withLock { $0.fd }
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                continuation.yield(.received(Array(buffer[..<n])))
                if n < buffer.count { return }
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                // A zero-length read on a readable source means the device vanished
                // (for example a USB adapter was unplugged).
                let message = n == 0 ? "The serial device was disconnected." : String(cString: strerror(errno))
                shutdown(error: message)
                return
            } else {
                return
            }
        }
    }

    private func pollModemLines() {
        let fd = state.withLock { $0.fd }
        guard fd >= 0 else { return }
        var bits: Int32 = 0
        guard ioctl(fd, TIOCMGET, &bits) == 0 else { return }
        let lines = ModemLines(rawValue: bits).intersection([.cts, .dsr, .dcd, .ring])
        let changed = state.withLock { s -> Bool in
            defer { s.lastLines = lines }
            return s.lastLines != lines
        }
        if changed { continuation.yield(.modemLines(lines)) }
    }

    public func write(_ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                let fd = state.withLock { $0.fd }
                guard fd >= 0 else { return cont.resume(throwing: TransportError("The port is not open.")) }
                var offset = 0
                while offset < bytes.count {
                    let n = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                    if n > 0 {
                        offset += n
                    } else if n < 0, errno == EAGAIN || errno == EINTR {
                        // Output buffer full: wait until the driver drains it.
                        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        _ = poll(&p, 1, 1000)
                    } else {
                        return cont.resume(throwing: TransportError.posix("Write failed"))
                    }
                }
                cont.resume()
            }
        }
    }

    /// Changes DTR/RTS while the port is open.
    public func setDTR(_ on: Bool) throws {
        try queue.sync {
            let fd = state.withLock { s in s.settings.dtr = on; return s.fd }
            if fd >= 0 { try Self.setLine(fd, TIOCM_DTR, on: on) }
        }
    }

    public func setRTS(_ on: Bool) throws {
        try queue.sync {
            let fd = state.withLock { s in s.settings.rts = on; return s.fd }
            if fd >= 0 { try Self.setLine(fd, TIOCM_RTS, on: on) }
        }
    }

    /// Re-applies line settings on an open port (baud rate, parity, ...).
    public func reconfigure(_ settings: SerialSettings) throws {
        try queue.sync {
            let fd = state.withLock { s in s.settings = settings; return s.fd }
            if fd >= 0 {
                try Self.apply(settings, to: fd)
            }
        }
    }

    /// Discards unread input and unsent output.
    public func flush() {
        queue.sync {
            let fd = state.withLock { $0.fd }
            if fd >= 0 { tcflush(fd, TCIOFLUSH) }
        }
    }

    /// Blocks until all queued output has been transmitted.
    public func drain() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                let fd = state.withLock { $0.fd }
                if fd >= 0 { tcdrain(fd) }
                cont.resume()
            }
        }
    }

    public func close() {
        queue.async { [weak self] in self?.shutdown(error: nil) }
    }

    private func shutdown(error: String?) {
        let (fd, source, timer) = state.withLock { s in
            defer { s.fd = -1; s.readSource = nil; s.lineTimer = nil }
            return (s.fd, s.readSource, s.lineTimer)
        }
        guard fd >= 0 else { return }
        source?.cancel()
        timer?.cancel()
        Darwin.close(fd)
        continuation.yield(.closed(error: error))
    }
}
