import CoreBluetooth
import Foundation
import Observation

/// Tracks macOS Bluetooth privacy authorization and radio power. IOBluetooth is gated by the same TCC
/// service as CoreBluetooth, so nothing touches IOBluetooth until this reports `.ready`.
@MainActor
@Observable
final class BluetoothAccess: NSObject {
    enum Status: Equatable {
        case unknown
        case notDetermined
        case denied
        case poweredOff
        case unsupported
        case ready
    }

    private(set) var status: Status = .unknown
    private var manager: CBCentralManager?

    func start() {
        guard manager == nil else { return }
        switch CBManager.authorization {
        case .denied, .restricted:
            status = .denied
        case .notDetermined:
            status = .notDetermined
        default:
            break
        }
        // Creating the manager triggers the one-time system prompt when undetermined.
        manager = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    private func update(from state: CBManagerState) {
        switch state {
        case .poweredOn: status = .ready
        case .poweredOff, .resetting: status = .poweredOff
        case .unauthorized: status = CBManager.authorization == .notDetermined ? .notDetermined : .denied
        case .unsupported: status = .unsupported
        case .unknown: status = .unknown
        @unknown default: status = .unknown
        }
    }
}

extension BluetoothAccess: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        MainActor.assumeIsolated { update(from: state) }
    }
}
