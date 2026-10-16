import AppKit
import SwiftUI
import Foundation
import IOBluetooth
import Observation

/// A paired headset that this Mac knows about.
struct KnownHeadphones: Identifiable, Equatable {
    let address: String
    var name: String
    var isConnected: Bool
    var publishesService: Bool
    var id: String { address }
}

enum ConnectionPhase: Equatable {
    case starting
    case permissionNeeded
    case permissionDenied
    case bluetoothOff
    case noHeadphones
    case waiting(String)
    case connecting(String)
    case initializing(String)
    case connected
    case reconnecting(String, attempt: Int)
    case failed(String, message: String)

    var isConnected: Bool { self == .connected }

    var isBusy: Bool {
        switch self {
        case .connecting, .initializing, .reconnecting, .starting: true
        default: false
        }
    }
}

/// Outcome of one write + read-back, kept for the Diagnostics "verification" list and scene reports.
struct VerificationRecord: Identifiable, Sendable {
    enum Outcome: Sendable { case confirmed, adjusted(String), mismatch, notCheckable, failed(String) }
    let id = UUID()
    let date: Date
    let label: String
    let outcome: Outcome
}

struct Toast: Identifiable, Equatable {
    enum Style { case info, warning, error }
    let id = UUID()
    let style: Style
    let message: String
}

@MainActor
@Observable
final class HeadphoneController {
    let bluetooth = BluetoothAccess()
    let state = DeviceState()
    let systemNowPlaying = SystemNowPlaying()

    private(set) var phase: ConnectionPhase = .starting
    private(set) var knownHeadphones: [KnownHeadphones] = []
    private(set) var traffic: [TrafficEntry] = []
    private(set) var verifications: [VerificationRecord] = []
    private(set) var pendingLabels: Set<String> = []
    private(set) var lastRefresh: Date?
    var toast: Toast?

    var selectedAddress: String? {
        didSet { UserDefaults.standard.set(selectedAddress, forKey: "selectedAddress") }
    }

    private var transport: RFCOMMTransport?
    private var link: MDRLink?
    private var driver: HeadphoneDriver?
    private var connectTask: Task<Void, Never>?
    private var generation = 0
    private var refreshTimer: Timer?
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var userDisconnected = false
    private var reconnectAttempt = 0
    private var observerStarted = false
    private var dragTask: Task<Void, Never>?
    private var latestDrag: NoiseControl?

    /// Fired after a successful (re)connection; scenes use it for "when headphones connect" triggers.
    var onConnected: (() -> Void)?

    /// Non-nil while showing a recorded session (developer replay, `--replay FILE`). Never live: Bluetooth is not
    /// started, the link has no transport, and every write is refused here and again at the link.
    private(set) var replaySource: String?
    var isReplay: Bool { replaySource != nil }
    /// Writes are possible only on a live, initialized connection.
    var canWrite: Bool { phase.isConnected && !isReplay }

    /// The latest noise-control request not yet confirmed. Quick successive edits (mode, voice focus, level) build
    /// on it, so one request never overwrites another's fields with stale state.
    private(set) var noiseIntent: NoiseControl?
    /// Set when the user accepts a headset prompt that makes it restart its Bluetooth link (multipoint,
    /// connection quality, button assignment): the following link drop is expected, not an error.
    private var reconnectExpectedUntil: Date?
    private var reconnectExpected: Bool { (reconnectExpectedUntil.map { $0 > Date() }) ?? false }
    /// Set when the user declines a headset prompt: the unchanged read-back is a cancellation, not a failure.
    private var alertDeclinedAt: Date?
    var noiseBase: NoiseControl? { noiseIntent ?? state.noise }

    init() {
        selectedAddress = UserDefaults.standard.string(forKey: "selectedAddress")
    }

    var selectedName: String {
        knownHeadphones.first { $0.address == selectedAddress }?.name ?? state.modelName ?? "Headphones"
    }

    var isConnected: Bool { phase.isConnected }

    // MARK: Startup

    func start() {
        guard !isReplay else { return }
        bluetooth.start()
        observeBluetoothStatus()
    }

    /// Loads a `--probe` report recorded from real hardware and runs its received frames through the normal V1
    /// parser. Read-only: nothing is persisted and nothing can be sent.
    func startReplay(from url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            replaySource = url.lastPathComponent
            phase = .failed("Replay", message: "Cannot read \(url.path).")
            return
        }
        replaySource = url.lastPathComponent
        let link = MDRLink(transport: nil)
        state.reset()
        state.family = .v1
        let driver = V1Driver(link: link, state: state)
        link.describe = { [weak driver] frame in driver?.describe(frame) ?? "" }
        link.onFrame = { [weak driver] frame in driver?.handle(frame) }
        link.onTraffic = { [weak self] entry in self?.appendTraffic(entry) }
        self.link = link
        self.driver = driver
        let pattern = #/← (MDR2|MDR) s([01]) \[([0-9A-F ]+)\]/#
        var count = 0
        for line in text.split(separator: "\n") {
            guard let match = line.firstMatch(of: pattern) else { continue }
            let payload = match.3.split(separator: " ").compactMap { UInt8($0, radix: 16) }
            let frame = MDRFrame(type: match.1 == "MDR2" ? .dataMdrNo2 : .dataMdr, sequence: UInt8(match.2) ?? 0, payload: payload)
            link.injectRecorded(frame)
            count += 1
        }
        let recorded = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        link.note("Replayed \(count) frames recorded \(recorded?.formatted() ?? "earlier") — read-only, not live")
        lastRefresh = recorded
        phase = count > 0 && state.modelName != nil ? .connected : .failed("Replay", message: "No recorded frames found in \(url.lastPathComponent).")
    }

    private func observeBluetoothStatus() {
        withObservationTracking {
            _ = bluetooth.status
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.bluetoothStatusChanged()
                self?.observeBluetoothStatus()
            }
        }
        bluetoothStatusChanged()
    }

    private func bluetoothStatusChanged() {
        switch bluetooth.status {
        case .unknown:
            if !phase.isConnected { phase = .starting }
        case .notDetermined:
            phase = .permissionNeeded
        case .denied:
            dropConnection()
            phase = .permissionDenied
        case .poweredOff, .unsupported:
            dropConnection()
            phase = .bluetoothOff
        case .ready:
            if !observerStarted {
                observerStarted = true
                BluetoothObserverBridge.shared.controller = self
                connectNotification = IOBluetoothDevice.register(forConnectNotifications: BluetoothObserverBridge.shared,
                                                                 selector: #selector(BluetoothObserverBridge.deviceConnected(_:device:)))
            }
            rescan()
            autoConnectIfPossible()
            if phase == .starting {
                phase = knownHeadphones.isEmpty ? .noHeadphones : .waiting(selectedName)
            }
        }
    }

    // MARK: Discovery

    func rescan() {
        guard bluetooth.status == .ready else { return }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        knownHeadphones = paired.compactMap { device in
            guard let address = device.addressString?.uppercased().replacingOccurrences(of: "-", with: ":") else { return nil }
            let name = device.name ?? address
            let publishes = RFCOMMTransport.publishesSonyService(device)
            let looksSony = Self.sonyNamePrefixes.contains { name.uppercased().hasPrefix($0) }
            guard publishes || looksSony else { return nil }
            watchDisconnect(device, address: address)
            return KnownHeadphones(address: address, name: name, isConnected: device.isConnected(), publishesService: publishes)
        }
        .sorted { ($0.isConnected ? 0 : 1, $0.name) < ($1.isConnected ? 0 : 1, $1.name) }
        if selectedAddress == nil || !knownHeadphones.contains(where: { $0.address == selectedAddress }) {
            selectedAddress = knownHeadphones.first(where: \.isConnected)?.address ?? knownHeadphones.first?.address
        }
        let idle = phase == .starting || (!phase.isConnected && !phase.isBusy)
        if idle && connectTask == nil {
            if knownHeadphones.isEmpty {
                phase = .noHeadphones
            } else if let target = knownHeadphones.first(where: { $0.address == selectedAddress }), !target.isConnected {
                phase = .waiting(target.name)
            }
        }
    }

    static let sonyNamePrefixes = ["WH-", "WF-", "WI-", "LINKBUDS", "ULT WEAR", "INZONE", "MDR-"]

    private func device(for address: String) -> IOBluetoothDevice? {
        IOBluetoothDevice(addressString: address.replacingOccurrences(of: ":", with: "-"))
    }

    private func watchDisconnect(_ device: IOBluetoothDevice, address: String) {
        guard disconnectNotifications[address] == nil else { return }
        disconnectNotifications[address] = device.register(forDisconnectNotification: BluetoothObserverBridge.shared,
                                                           selector: #selector(BluetoothObserverBridge.deviceDisconnected(_:device:)))
    }

    fileprivate func basebandConnected(_ device: IOBluetoothDevice) {
        rescan()
        guard let address = device.addressString?.uppercased().replacingOccurrences(of: "-", with: ":") else { return }
        if address == selectedAddress {
            userDisconnected = false
            autoConnectIfPossible()
        } else if !phase.isConnected && !phase.isBusy, knownHeadphones.contains(where: { $0.address == address && $0.publishesService }) {
            // Prefer whatever Sony headset just connected when nothing is active.
            selectedAddress = address
            autoConnectIfPossible()
        }
    }

    fileprivate func basebandDisconnected(_ device: IOBluetoothDevice) {
        let address = device.addressString?.uppercased().replacingOccurrences(of: "-", with: ":")
        disconnectNotifications[address ?? ""] = nil
        if address == selectedAddress, link != nil {
            dropConnection()
            phase = .waiting(selectedName)
        }
        rescan()
    }

    // MARK: Connection

    func autoConnectIfPossible() {
        guard bluetooth.status == .ready, !userDisconnected, link == nil, connectTask == nil,
              let address = selectedAddress,
              let known = knownHeadphones.first(where: { $0.address == address }), known.isConnected else { return }
        connect(address: address, initiate: false)
    }

    /// Opens the control channel. `initiate` also asks macOS to bring up the Bluetooth link if needed
    /// (user-requested only, as it can take the headphones from another source).
    ///
    /// Every attempt gets a generation number. After each suspension point an attempt re-checks that it is
    /// still current; a superseded attempt only closes what it opened itself and never touches shared state.
    /// IOBluetooth hands out one channel object per (device, channel ID), so a new attempt also waits for
    /// the previous one to unwind before opening.
    func connect(address: String, initiate: Bool) {
        guard bluetooth.status == .ready, !isReplay else { return }
        let previous = connectTask
        previous?.cancel()
        generation += 1
        let myGeneration = generation
        dropConnection()
        userDisconnected = false
        selectedAddress = address
        let name = knownHeadphones.first { $0.address == address }?.name ?? "Headphones"
        phase = .connecting(name)
        connectTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            if self.generation == myGeneration && !Task.isCancelled {
                await self.runConnect(address: address, name: name, initiate: initiate, generation: myGeneration)
            }
            if self.generation == myGeneration { self.connectTask = nil }
        }
    }

    /// True while a connection attempt is opening or initializing.
    var isConnecting: Bool { connectTask != nil }

    private func isCurrent(_ attempt: Int) -> Bool { generation == attempt && !Task.isCancelled }

    private func runConnect(address: String, name: String, initiate: Bool, generation attempt: Int) async {
        guard let device = device(for: address) else {
            phase = .failed(name, message: "This Mac no longer knows these headphones.")
            return
        }
        var ownedTransport: RFCOMMTransport?
        var ownedLink: MDRLink?
        do {
            let transport = try await RFCOMMTransport.open(device: device, allowBasebandConnect: initiate)
            ownedTransport = transport
            guard isCurrent(attempt) else { throw CancellationError() }
            let link = MDRLink(transport: transport)
            ownedLink = link
            state.reset()
            state.family = transport.family
            let driver: HeadphoneDriver = transport.family == .v1
                ? V1Driver(link: link, state: state)
                : V2Driver(link: link, state: state)
            link.describe = { [weak driver] frame in driver?.describe(frame) ?? "" }
            link.onFrame = { [weak driver] frame in driver?.handle(frame) }
            link.onTraffic = { [weak self, weak link] entry in
                guard let self, let link, self.link === link else { return }
                self.appendTraffic(entry)
            }
            link.onClose = { [weak self, weak link] error in
                guard let self, let link, self.link === link else { return }
                self.linkClosed(error)
            }
            self.transport = transport
            self.link = link
            self.driver = driver
            traffic.removeAll()
            appendNote("Opened \(transport.family.rawValue) control channel \(transport.channelID) to \(name)")
            phase = .initializing(name)
            // WH-1000XM4 ignores a frame sent in the first instant after the channel opens (observed: the first
            // GET protocol always needed a retry). A short settle avoids a one-second stall.
            try await Task.sleep(for: .milliseconds(350))
            guard isCurrent(attempt) else { throw CancellationError() }
            try await link.exclusive { try await driver.initialize() }
            guard isCurrent(attempt) else { throw CancellationError() }
            phase = .connected
            reconnectAttempt = 0
            lastRefresh = Date()
            startRefreshTimer()
            onConnected?()
        } catch {
            // Close what this attempt opened; shared state only belongs to the current generation.
            ownedLink?.close()
            ownedTransport?.close()
            guard generation == attempt else { return }
            dropConnection()
            if error is CancellationError { return }
            // The main window shows friendly copy; the technical reason is kept for Activity.
            appendNote("Connection to \(name) failed: \(error.localizedDescription)")
            if case TransportError.notConnected = error {
                phase = .waiting(name)
            } else {
                phase = .failed(name, message: error.localizedDescription)
                scheduleReconnect(name: name)
            }
        }
    }

    func disconnect() {
        guard !isReplay else { return }
        userDisconnected = true
        generation += 1
        connectTask?.cancel()
        connectTask = nil
        dropConnection()
        phase = .waiting(selectedName)
    }

    private func dropConnection() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        dragTask?.cancel()
        dragTask = nil
        latestDrag = nil
        noiseIntent = nil
        let oldLink = link
        link = nil
        driver = nil
        transport = nil
        oldLink?.close()
        pendingLabels.removeAll()
    }

    private func linkClosed(_ error: Error) {
        let name = selectedName
        generation += 1
        dropConnection()
        state.alert = nil
        if userDisconnected { return }
        let stillConnected = selectedAddress.flatMap { device(for: $0) }?.isConnected() ?? false
        if stillConnected || reconnectExpected {
            // After an accepted multipoint/quality change the headset drops and comes back on its own.
            reconnectAttempt = 0
            scheduleReconnect(name: name)
        } else {
            phase = .waiting(name)
        }
        if case MDRLink.LinkError.ackTimeout = error {
            showToast(.warning, "Lost sync with the headphones. Reconnecting…")
        }
    }

    private func scheduleReconnect(name: String) {
        guard !userDisconnected, reconnectAttempt < 6 else { return }
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        let scheduledGeneration = generation
        let delay = [1.0, 2.0, 4.0, 8.0, 15.0, 30.0][min(attempt - 1, 5)]
        if case .failed = phase {} else { phase = .reconnecting(name, attempt: attempt) }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                // Anything that happened meanwhile (manual connect, disconnect, success) supersedes this timer.
                guard let self, self.generation == scheduledGeneration, self.link == nil, self.connectTask == nil,
                      !self.userDisconnected else { return }
                self.rescan()
                guard let address = self.selectedAddress,
                      self.knownHeadphones.first(where: { $0.address == address })?.isConnected == true else {
                    self.phase = .waiting(name)
                    return
                }
                self.connect(address: address, initiate: false)
                self.reconnectAttempt = attempt
            }
        }
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
    }

    func refreshStatus() {
        guard let link, let driver, canWrite else { return }
        Task { @MainActor in
            do {
                try await link.exclusive { try await driver.refreshStatus() }
                if self.link === link { lastRefresh = Date() }
            } catch {
                link.note("Refresh failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Writes

    /// Writes a change, reads it back (mandatory reply) and compares — all inside one exclusive transaction —
    /// then records whether the headset kept it.
    @discardableResult
    func perform(_ change: DeviceChange, quiet: Bool = false) async -> Bool {
        if isReplay {
            if !quiet { showToast(.warning, "This is a read-only replay. Nothing is sent to headphones.") }
            return false
        }
        guard let link, let driver, phase.isConnected else {
            if !quiet { showToast(.warning, "Connect your headphones to change settings.") }
            return false
        }
        let label = change.label
        pendingLabels.insert(label)
        defer { pendingLabels.remove(label) }
        do {
            let result: (reflected: Bool?, adjustment: String?) = try await link.exclusive {
                try await driver.apply(change)
                return (change.isReflected(in: state), change.adjustment(in: state))
            }
            switch result.reflected {
            case true?:
                record(label, .confirmed)
                return true
            case false?:
                if let adjustment = result.adjustment {
                    record(label, .adjusted(adjustment))
                    return true
                }
                if let declined = alertDeclinedAt, Date().timeIntervalSince(declined) < 60 {
                    alertDeclinedAt = nil
                    record(label, .failed("Cancelled on the headphones' prompt"))
                    if !quiet { showToast(.info, "Change cancelled. The headphones kept their current setting.") }
                    return false
                }
                record(label, .mismatch)
                if !quiet { showToast(.warning, "The headphones did not keep “\(label)”.") }
                return false
            case nil:
                record(label, .notCheckable)
                return true
            }
        } catch {
            if reconnectExpected, case MDRLink.LinkError.closed = error {
                record(label, .notCheckable)
                if !quiet { showToast(.info, "The headphones are restarting their connection to apply “\(label)”. Reconnecting…") }
                return true
            }
            record(label, .failed(error.localizedDescription))
            if !quiet && !(error is CancellationError) { showToast(.error, error.localizedDescription) }
            return false
        }
    }

    /// Applies dependent changes as ONE transaction (e.g. select an editable EQ preset, then write its bands) and
    /// stops at the first change the headset does not confirm, so a later step never lands on the wrong target and
    /// nothing else can interleave between the steps.
    @discardableResult
    func performGroup(_ changes: [DeviceChange], quiet: Bool = false) async -> (confirmed: Int, failed: String?) {
        guard !changes.isEmpty else { return (0, nil) }
        if isReplay {
            if !quiet { showToast(.warning, "This is a read-only replay. Nothing is sent to headphones.") }
            return (0, changes[0].label)
        }
        guard let link, let driver, phase.isConnected else {
            if !quiet { showToast(.warning, "Connect your headphones to change settings.") }
            return (0, changes[0].label)
        }
        let labels = Set(changes.map(\.label))
        pendingLabels.formUnion(labels)
        defer { pendingLabels.subtract(labels) }
        var confirmed = 0
        var current = changes[0]
        do {
            let failed: String? = try await link.exclusive {
                for change in changes {
                    current = change
                    try await driver.apply(change)
                    switch change.isReflected(in: state) {
                    case false?:
                        if let adjustment = change.adjustment(in: state) {
                            record(change.label, .adjusted(adjustment))
                            break
                        }
                        record(change.label, .mismatch)
                        return change.label
                    case true?:
                        record(change.label, .confirmed)
                    case nil:
                        record(change.label, .notCheckable)
                    }
                    confirmed += 1
                }
                return nil
            }
            if let failed, !quiet { showToast(.warning, "The headphones did not keep “\(failed)”.") }
            return (confirmed, failed)
        } catch {
            record(current.label, .failed(error.localizedDescription))
            if !quiet && !(error is CancellationError) { showToast(.error, error.localizedDescription) }
            return (confirmed, current.label)
        }
    }

    /// Noise control from the UI: builds on the latest pending request (see `noiseIntent`).
    func requestNoise(_ mutate: (inout NoiseControl) -> Void) {
        guard canWrite, var value = noiseBase else { return }
        mutate(&value)
        noiseIntent = value
        latestDrag = nil
        Task {
            _ = await perform(.noise(value, dragging: false))
            if noiseIntent == value { noiseIntent = nil }
        }
    }

    /// Live ambient-level drag, based on the latest intent.
    func dragAmbientLevel(_ level: Int) {
        guard var value = noiseBase else { return }
        value.ambientLevel = level
        dragNoise(value)
    }

    func isPending(_ change: DeviceChange) -> Bool { pendingLabels.contains(change.label) }
    var hasPendingWrites: Bool { !pendingLabels.isEmpty }

    func apply(_ change: DeviceChange) {
        Task { await perform(change) }
    }

    /// Live slider drags: coalesced "in progress" writes without read-back (the release commits with one).
    /// Bound to the link that was current when the drag began; stops on cancellation or reconnection.
    func dragNoise(_ value: NoiseControl) {
        guard canWrite else { return }
        latestDrag = value
        guard dragTask == nil, let link, let driver else { return }
        dragTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.link === link, let next = self.latestDrag {
                self.latestDrag = nil
                do {
                    try await link.exclusive { try await driver.apply(.noise(next, dragging: true)) }
                    try await Task.sleep(for: .milliseconds(120))
                } catch {
                    break
                }
            }
            if let self, self.link === link { self.dragTask = nil }
        }
    }

    /// Ends a drag: drops any un-sent intermediate value so it cannot land after the committing write.
    func endNoiseDrag() {
        latestDrag = nil
    }

    func answerAlert(accept: Bool) {
        guard let alert = state.alert else { return }
        state.alert = nil
        guard alert.requiresAnswer, canWrite, let driver else { return }
        Task { @MainActor in
            do {
                // Not inside `exclusive`: the transaction that triggered the alert is still holding the gate while
                // it waits for its read-back, which the headset only sends after this answer. The link itself
                // still keeps one frame in flight.
                try await driver.answerAlert(alert, accept: accept)
                if accept, alert.messageType != 0x08 { reconnectExpectedUntil = Date().addingTimeInterval(60) }
                if !accept { alertDeclinedAt = Date() }
            } catch {
                showToast(.error, error.localizedDescription)
            }
        }
    }

    func startNoiseOptimizer() {
        guard canWrite, let link, let driver else { return }
        Task { @MainActor in
            do {
                try await link.exclusive { try await driver.startNoiseOptimizer() }
                state.optimizer = .running
            } catch {
                showToast(.error, error.localizedDescription)
            }
        }
    }

    func cancelNoiseOptimizer() {
        guard canWrite, let link, let driver else { return }
        Task { @MainActor in try? await link.exclusive { try await driver.cancelNoiseOptimizer() } }
    }

    func powerOff() {
        guard canWrite, let link, let driver else { return }
        Task { @MainActor in
            do {
                try await link.exclusive { try await driver.powerOff() }
                showToast(.info, "Turning the headphones off.")
            } catch {
                showToast(.error, error.localizedDescription)
            }
        }
    }

    // MARK: Bookkeeping

    private func record(_ label: String, _ outcome: VerificationRecord.Outcome) {
        verifications.insert(VerificationRecord(date: Date(), label: label, outcome: outcome), at: 0)
        if verifications.count > 200 { verifications.removeLast(verifications.count - 200) }
    }

    /// Controller-level notes for Activity; negative ids never collide with link entries.
    private var nextNoteID = -1
    private func appendNote(_ text: String) {
        appendTraffic(TrafficEntry(id: nextNoteID, date: Date(), direction: .note, frameType: "", sequence: nil, payload: [], summary: text))
        nextNoteID -= 1
    }

    private func appendTraffic(_ entry: TrafficEntry) {
        traffic.append(entry)
        if traffic.count > 500 { traffic.removeFirst(traffic.count - 500) }
    }

    func showToast(_ style: Toast.Style, _ message: String) {
        let toast = Toast(style: style, message: message)
        self.toast = toast
        AccessibilityNotification.Announcement(message).post()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            MainActor.assumeIsolated {
                if self?.toast?.id == toast.id { self?.toast = nil }
            }
        }
    }

    var trafficLog: String { traffic.map(\.line).joined(separator: "\n") }
}

/// Objective-C target for IOBluetooth notifications (they require an NSObject receiver).
@MainActor
final class BluetoothObserverBridge: NSObject {
    static let shared = BluetoothObserverBridge()
    weak var controller: HeadphoneController?

    @objc nonisolated func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        onMainActor { [self] in controller?.basebandConnected(device) }
    }

    @objc nonisolated func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        onMainActor { [self] in controller?.basebandDisconnected(device) }
    }
}
