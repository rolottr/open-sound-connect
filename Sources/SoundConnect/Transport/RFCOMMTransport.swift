import Foundation
import IOBluetooth

/// Which MDR service a headset exposes. The RFCOMM service UUID decides the protocol family:
/// WH-1000XM4 and older publish the legacy UUID (V1); XM5/XM6 and newer publish the V2 UUID.
enum ProtocolFamily: String, Sendable, Codable {
    case v1 = "V1"
    case v2 = "V2"

    var serviceUUID: String {
        switch self {
        case .v1: "96CC203E-5068-46AD-B32D-E316F5E069BA"
        case .v2: "956C7B26-D49A-4BA8-B03F-B17D393CB6E2"
        }
    }

    var sdpUUID: IOBluetoothSDPUUID {
        var bytes = [UInt8]()
        var hex = Substring(serviceUUID.replacingOccurrences(of: "-", with: ""))
        while hex.count >= 2 {
            bytes.append(UInt8(hex.prefix(2), radix: 16)!)
            hex = hex.dropFirst(2)
        }
        return IOBluetoothSDPUUID(bytes: bytes, length: bytes.count)
    }
}

enum TransportError: LocalizedError, Equatable {
    case bluetoothUnavailable
    case notConnected
    case serviceNotFound
    case sdpFailed(Int32)
    case openFailed(Int32)
    case writeFailed(Int32)
    case closedByRemote
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable: "Bluetooth is turned off or unavailable."
        case .notConnected: "The headphones are not connected to this Mac."
        case .serviceNotFound: "These headphones do not publish Sony's control service."
        case .sdpFailed(let code): String(format: "Service discovery failed (0x%08X).", UInt32(bitPattern: code))
        case .openFailed(let code): String(format: "Could not open the control channel (0x%08X).", UInt32(bitPattern: code))
        case .writeFailed(let code): String(format: "Bluetooth write failed (0x%08X).", UInt32(bitPattern: code))
        case .closedByRemote: "The headphones closed the control channel."
        case .timeout(let what): "Timed out waiting for \(what)."
        }
    }
}

@MainActor
protocol RFCOMMTransportDelegate: AnyObject {
    func transport(_ transport: RFCOMMTransport, didReceive bytes: [UInt8])
    /// Called once when an open channel ends for any reason other than a local `close()`.
    func transportDidClose(_ transport: RFCOMMTransport, error: TransportError)
}

/// IOBluetooth RFCOMM channel to one headset. The channel is opened from the main thread, but on macOS 26
/// IOBluetooth can still deliver delegate callbacks on its own queue, so every callback hops via `onMainActor`.
///
/// Lifecycle: `open` → (data…) → exactly one of {local `close()`, `transportDidClose`}. After either, the
/// object is dead; late IOBluetooth callbacks are ignored.
@MainActor
final class RFCOMMTransport: NSObject {
    let device: IOBluetoothDevice
    let family: ProtocolFamily
    let channelID: BluetoothRFCOMMChannelID
    weak var delegate: RFCOMMTransportDelegate?

    private var channel: IOBluetoothRFCOMMChannel?
    private var openShot: OneShot<Void>?
    private var pendingWrites: [UnsafeMutableRawPointer: Int] = [:]
    private(set) var isOpen = false
    private var finished = false

    static let openTimeout: TimeInterval = 12
    static let sdpTimeout: TimeInterval = 12

    private init(device: IOBluetoothDevice, family: ProtocolFamily, channelID: BluetoothRFCOMMChannelID) {
        self.device = device
        self.family = family
        self.channelID = channelID
    }

    /// Resolves the MDR service on a paired device (V2 preferred), running a bounded SDP query if the cached
    /// records do not include it, then opens the RFCOMM channel with a deadline.
    static func open(device: IOBluetoothDevice, allowBasebandConnect: Bool) async throws -> RFCOMMTransport {
        guard IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON else {
            throw TransportError.bluetoothUnavailable
        }
        if !device.isConnected() && !allowBasebandConnect { throw TransportError.notConnected }
        var resolved = resolveService(on: device)
        if resolved == nil {
            try await SDPQuery.run(on: device, timeout: sdpTimeout)
            resolved = resolveService(on: device)
        }
        guard let (family, channelID) = resolved else { throw TransportError.serviceNotFound }
        let transport = RFCOMMTransport(device: device, family: family, channelID: channelID)
        try await transport.openChannel()
        return transport
    }

    static func resolveService(on device: IOBluetoothDevice) -> (ProtocolFamily, BluetoothRFCOMMChannelID)? {
        for family in [ProtocolFamily.v2, .v1] {
            guard let record = device.getServiceRecord(for: family.sdpUUID) else { continue }
            var channel: BluetoothRFCOMMChannelID = 0
            if record.getRFCOMMChannelID(&channel) == kIOReturnSuccess { return (family, channel) }
        }
        return nil
    }

    static func publishesSonyService(_ device: IOBluetoothDevice) -> Bool {
        resolveService(on: device) != nil
    }

    private func openChannel() async throws {
        let shot = OneShot<Void>()
        openShot = shot
        try await withTaskCancellationHandler {
            var newChannel: IOBluetoothRFCOMMChannel?
            let status = device.openRFCOMMChannelAsync(&newChannel, withChannelID: channelID, delegate: self)
            if status != kIOReturnSuccess {
                shot.resolve(.failure(TransportError.openFailed(status)))
            } else {
                // Keep the channel regardless of whether the open callback already fired synchronously
                // (handleOpen may also have captured it from the callback argument).
                if channel == nil { channel = newChannel }
                if !shot.isResolved {
                    shot.deadline(Self.openTimeout, error: TransportError.timeout("the control channel to open")) { [weak self] in
                        self?.abandon()
                    }
                }
            }
            do {
                try await shot.value()
                openShot = nil
            } catch {
                openShot = nil
                abandon()
                throw error
            }
        } onCancel: {
            Task { @MainActor in shot.resolve(.failure(CancellationError())) }
        }
    }

    var mtu: Int {
        guard let channel else { return 127 }
        return max(16, Int(channel.getMTU()))
    }

    func write(_ bytes: [UInt8]) throws {
        guard let channel, isOpen, !finished else { throw TransportError.notConnected }
        var offset = 0
        let chunk = mtu
        while offset < bytes.count {
            let length = min(chunk, bytes.count - offset)
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: 1)
            bytes.withUnsafeBytes { raw in
                buffer.copyMemory(from: raw.baseAddress!.advanced(by: offset), byteCount: length)
            }
            pendingWrites[buffer] = length
            let status = channel.writeAsync(buffer, length: UInt16(length), refcon: buffer)
            if status != kIOReturnSuccess {
                pendingWrites.removeValue(forKey: buffer)
                buffer.deallocate()
                throw TransportError.writeFailed(status)
            }
            offset += length
        }
    }

    /// Local, final close. No delegate callback follows.
    func close() {
        guard !finished else { return }
        finished = true
        openShot?.resolve(.failure(TransportError.closedByRemote))
        tearDownChannel()
    }

    /// Drops a channel that never finished opening (timeout/cancel/error).
    private func abandon() {
        guard !finished else { return }
        finished = true
        tearDownChannel()
    }

    private func tearDownChannel() {
        isOpen = false
        if let channel {
            channel.setDelegate(nil)
            channel.close()
        }
        channel = nil
        // IOBluetooth stops calling back after setDelegate(nil); buffers still queued in the stack are
        // referenced by the kernel only until the channel is torn down, so release them now.
        for (pointer, _) in pendingWrites { pointer.deallocate() }
        pendingWrites.removeAll()
    }

    private func fail(_ error: TransportError) {
        guard !finished else { return }
        let wasOpen = isOpen
        finished = true
        tearDownChannel()
        if wasOpen { delegate?.transportDidClose(self, error: error) }
    }

    fileprivate func handleOpen(_ opened: IOBluetoothRFCOMMChannel?, status: IOReturn) {
        guard !finished, let shot = openShot else { return }
        if channel == nil { channel = opened }
        if status == kIOReturnSuccess {
            isOpen = true
            shot.resolve(.success(()))
        } else {
            shot.resolve(.failure(TransportError.openFailed(status)))
        }
    }

    fileprivate func handleData(_ bytes: [UInt8]) {
        guard !finished, isOpen else { return }
        delegate?.transport(self, didReceive: bytes)
    }

    fileprivate func handleClosed() {
        if let shot = openShot, !shot.isResolved {
            shot.resolve(.failure(TransportError.closedByRemote))
            return
        }
        fail(.closedByRemote)
    }

    fileprivate func handleWriteComplete(refcon: UnsafeMutableRawPointer?, status: IOReturn) {
        if let refcon, pendingWrites.removeValue(forKey: refcon) != nil {
            refcon.deallocate()
        }
        if status != kIOReturnSuccess { fail(.writeFailed(status)) }
    }
}

extension RFCOMMTransport: IOBluetoothRFCOMMChannelDelegate {
    nonisolated func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        onMainActor { [self] in handleOpen(rfcommChannel, status: error) }
    }

    nonisolated func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let bytes = Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        onMainActor { [self] in handleData(bytes) }
    }

    nonisolated func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        onMainActor { [self] in handleClosed() }
    }

    nonisolated func rfcommChannelWriteComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn) {
        onMainActor { [self] in handleWriteComplete(refcon: refcon, status: error) }
    }
}

/// One-shot, bounded SDP refresh for a device whose cached records lack the MDR service.
@MainActor
private final class SDPQuery: NSObject {
    private let shot = OneShot<Void>()
    private static var inFlight: [SDPQuery] = []

    static func run(on device: IOBluetoothDevice, timeout: TimeInterval) async throws {
        let query = SDPQuery()
        inFlight.append(query)
        defer { inFlight.removeAll { $0 === query } }
        let shot = query.shot
        try await withTaskCancellationHandler {
            let status = device.performSDPQuery(query, uuids: [ProtocolFamily.v2.sdpUUID, ProtocolFamily.v1.sdpUUID])
            if status != kIOReturnSuccess {
                shot.resolve(.failure(TransportError.sdpFailed(status)))
            } else {
                shot.deadline(timeout, error: TransportError.timeout("service discovery"))
            }
            try await shot.value()
        } onCancel: {
            Task { @MainActor in shot.resolve(.failure(CancellationError())) }
        }
    }

    @objc nonisolated func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        onMainActor { [self] in
            _ = shot.resolve(status == kIOReturnSuccess ? .success(()) : .failure(TransportError.sdpFailed(status)))
        }
    }
}
