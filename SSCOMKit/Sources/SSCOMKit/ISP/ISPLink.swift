public import Foundation

/// What the in-system programmers need from a serial port.
public protocol ISPLink: Sendable {
    func send(_ bytes: [UInt8]) async throws
    func read(_ count: Int, timeout: Duration) async throws -> [UInt8]
    func discardInput() async
    func setDTR(_ on: Bool) async throws
    func setRTS(_ on: Bool) async throws
    func setLine(baudRate: Int, parity: Parity) async throws
}

/// Adapts a `SerialPort` plus a `ReplyBuffer` (fed by the session with received data).
public struct SerialISPLink: ISPLink {
    public let port: SerialPort
    public let replies: ReplyBuffer

    public init(port: SerialPort, replies: ReplyBuffer) {
        self.port = port
        self.replies = replies
    }

    public func send(_ bytes: [UInt8]) async throws { try await port.write(bytes) }
    public func read(_ count: Int, timeout: Duration) async throws -> [UInt8] {
        try await replies.read(count, timeout: timeout)
    }
    public func discardInput() async {
        replies.clear()
    }
    public func setDTR(_ on: Bool) async throws { try port.setDTR(on) }
    public func setRTS(_ on: Bool) async throws { try port.setRTS(on) }
    public func setLine(baudRate: Int, parity: Parity) async throws {
        var s = port.settings
        s.baudRate = baudRate
        s.parity = parity
        s.dataBits = 8
        s.stopBits = .one
        s.flowControl = .none
        try port.reconfigure(s)
    }
}

/// Progress and log output from a flashing run.
public enum ISPEvent: Sendable {
    case log(String)
    case progress(done: Int, total: Int)
}

public struct ISPError: Error, LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// How the programmer drives the target's reset and boot-mode pins.
public struct ResetControl: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable, CaseIterable, Identifiable {
        /// The user puts the chip in bootloader mode by hand (BOOT0=1, then reset).
        case manual
        /// DTR drives RESET, RTS drives BOOT0 (the common one-click download circuit).
        case dtrResetRtsBoot
        /// RTS drives RESET, DTR drives BOOT0.
        case rtsResetDtrBoot
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .manual: "Manual (set BOOT0 and reset by hand)"
            case .dtrResetRtsBoot: "Auto: DTR → RESET, RTS → BOOT0"
            case .rtsResetDtrBoot: "Auto: RTS → RESET, DTR → BOOT0"
            }
        }
    }

    public var mode: Mode
    /// Swap the asserted level of the reset line (for circuits without an inverting transistor).
    public var invertReset: Bool
    /// Swap the asserted level of the boot line.
    public var invertBoot: Bool

    public init(mode: Mode = .dtrResetRtsBoot, invertReset: Bool = false, invertBoot: Bool = false) {
        self.mode = mode
        self.invertReset = invertReset
        self.invertBoot = invertBoot
    }

    func setReset(_ active: Bool, on link: any ISPLink) async throws {
        let level = active != invertReset
        switch mode {
        case .manual: break
        case .dtrResetRtsBoot: try await link.setDTR(level)
        case .rtsResetDtrBoot: try await link.setRTS(level)
        }
    }

    func setBoot(_ active: Bool, on link: any ISPLink) async throws {
        let level = active != invertBoot
        switch mode {
        case .manual: break
        case .dtrResetRtsBoot: try await link.setRTS(level)
        case .rtsResetDtrBoot: try await link.setDTR(level)
        }
    }

    /// Pulses reset with the boot line held at `boot`.
    func reset(boot: Bool, on link: any ISPLink) async throws {
        guard mode != .manual else { return }
        try await setBoot(boot, on: link)
        try await setReset(true, on: link)
        try await Task.sleep(for: .milliseconds(50))
        try await setReset(false, on: link)
        try await Task.sleep(for: .milliseconds(100))
    }
}
