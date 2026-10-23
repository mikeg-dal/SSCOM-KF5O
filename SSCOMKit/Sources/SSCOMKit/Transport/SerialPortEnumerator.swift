import Foundation
import IOKit
import IOKit.serial

public struct SerialPortInfo: Sendable, Hashable, Identifiable {
    /// Callout device path, for example /dev/cu.usbserial-1410.
    public var path: String
    /// USB product name when available, for example "USB Serial" or "CP2102N USB to UART".
    public var productName: String?
    public var id: String { path }

    public var displayName: String {
        let name = path.replacingOccurrences(of: "/dev/cu.", with: "")
        if let productName, !productName.isEmpty { return "\(name) — \(productName)" }
        return name
    }
}

/// Lists serial ports and reports when they appear or disappear.
public final class SerialPortEnumerator: Sendable {
    /// Yields the full port list on start and after every hot-plug event.
    public let updates: AsyncStream<[SerialPortInfo]>
    private let continuation: AsyncStream<[SerialPortInfo]>.Continuation
    private let queue = DispatchQueue(label: "serial.enumerator")
    private nonisolated(unsafe) var notifyPort: IONotificationPortRef?
    private nonisolated(unsafe) var iterators: [io_iterator_t] = []

    public init() {
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        queue.async { [self] in start() }
    }

    deinit {
        for it in iterators { IOObjectRelease(it) }
        if let notifyPort { IONotificationPortDestroy(notifyPort) }
    }

    public static func currentPorts() -> [SerialPortInfo] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var ports: [SerialPortInfo] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString,
                                                              kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String else { continue }
            // Skip the built-in Bluetooth placeholder ports and the debug console.
            if path.hasSuffix("Bluetooth-Incoming-Port") || path.hasSuffix(".debug-console") { continue }
            let product = IORegistryEntrySearchCFProperty(
                service, kIOServicePlane, "USB Product Name" as CFString, kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? String
            ports.append(SerialPortInfo(path: path, productName: product))
        }
        return ports.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func start() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, queue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            // Drain the iterator to re-arm the notification, then publish a fresh list.
            while case let s = IOIteratorNext(iterator), s != 0 { IOObjectRelease(s) }
            guard let refcon else { return }
            Unmanaged<SerialPortEnumerator>.fromOpaque(refcon).takeUnretainedValue().publish()
        }
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            if IOServiceAddMatchingNotification(port, type, IOServiceMatching(kIOSerialBSDServiceValue),
                                                callback, context, &iterator) == KERN_SUCCESS {
                while case let s = IOIteratorNext(iterator), s != 0 { IOObjectRelease(s) }
                iterators.append(iterator)
            }
        }
        publish()
    }

    private func publish() {
        continuation.yield(Self.currentPorts())
    }
}
