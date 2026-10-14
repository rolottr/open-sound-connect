import Foundation

/// One entry in the protocol traffic log shown in Diagnostics and written by `--probe`.
struct TrafficEntry: Identifiable, Sendable {
    enum Direction: String, Sendable { case tx = "→", rx = "←", note = "•" }
    let id: Int
    let date: Date
    let direction: Direction
    let frameType: String
    let sequence: UInt8?
    let payload: [UInt8]
    let summary: String

    var line: String {
        let time = Self.formatter.string(from: date)
        let seq = sequence.map { " s\($0)" } ?? ""
        let bytes = payload.isEmpty ? "" : " [\(payload.hex)]"
        let text = summary.isEmpty ? "" : "  \(summary)"
        return "\(time) \(direction.rawValue) \(frameType)\(seq)\(bytes)\(text)"
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

/// Reliable request layer over the MDR framing.
///
/// Rules (Sound Connect tandem behaviour, confirmed on WH-1000XM3/XM4 captures):
/// * Exactly one host command is in flight. It carries the current sequence bit; the headset ACKs with the
///   other bit, which becomes the next command's sequence. A missing ACK is retried with the same bit.
///   If retries are exhausted the sequence state is unknowable, so the link is torn down (the controller
///   reconnects) instead of continuing with a possibly desynchronised bit.
/// * Every DATA frame from the headset is ACKed immediately with `1 - sequence`.
/// * Replies (RET/NTFY) arrive as separate DATA frames; `request` correlates them by command byte + selector.
///   Callers that need "write, then read back" atomicity wrap the pair in `exclusive`.
@MainActor
final class MDRLink: RFCOMMTransportDelegate {
    struct Matcher: Sendable {
        let table: MDRDataType
        let command: UInt8
        let selector: UInt8?
        let detail: UInt8?

        init(_ table: MDRDataType = .dataMdr, _ command: UInt8, _ selector: UInt8? = nil, detail: UInt8? = nil) {
            self.table = table
            self.command = command
            self.selector = selector
            self.detail = detail
        }

        func matches(_ frame: MDRFrame) -> Bool {
            guard frame.rawType == table.rawValue, let first = frame.payload.first, first == command else { return false }
            if let selector, !(frame.payload.count > 1 && frame.payload[1] == selector) { return false }
            if let detail, !(frame.payload.count > 2 && frame.payload[2] == detail) { return false }
            return true
        }
    }

    enum LinkError: LocalizedError {
        case closed
        case ackTimeout(command: UInt8)
        case replyTimeout(command: UInt8)

        var errorDescription: String? {
            switch self {
            case .closed: "The control channel is closed."
            case .ackTimeout(let c): String(format: "Headphones stopped acknowledging commands (0x%02X).", c)
            case .replyTimeout(let c): String(format: "Headphones did not answer command 0x%02X.", c)
            }
        }
    }

    @MainActor
    private final class Outgoing {
        let id: Int
        let type: MDRDataType
        let payload: [UInt8]
        var attempts = 0
        let ack = OneShot<Void>()
        /// Started when the frame is first put on the air, so queueing time never eats a reply deadline.
        var onFirstTransmit: (() -> Void)?

        init(id: Int, type: MDRDataType, payload: [UInt8]) {
            self.id = id
            self.type = type
            self.payload = payload
        }
    }

    private struct ReplyWaiter {
        let id: Int
        let matcher: Matcher
        let shot: OneShot<[UInt8]>
    }

    /// nil only for the read-only replay link, which is closed from birth so nothing can be written.
    let transport: RFCOMMTransport?
    /// Called for every inbound data frame, before any waiter is resumed.
    var onFrame: ((MDRFrame) -> Void)?
    /// Called once when the link dies (remote close, write error, ACK exhaustion). Not called for `close()`.
    var onClose: ((Error) -> Void)?
    var describe: ((MDRFrame) -> String)?
    var onTraffic: ((TrafficEntry) -> Void)?
    private(set) var traffic: [TrafficEntry] = []

    var ackTimeout: TimeInterval = 1.0
    var maxAttempts = 4
    private var sequence: UInt8 = 0
    private var queue: [Outgoing] = []
    private var inFlight: Outgoing?
    private var inFlightTimer: DispatchWorkItem?
    private var waiters: [ReplyWaiter] = []
    private var assembler = MDRFrameAssembler()
    private var nextID = 1
    private(set) var isClosed = false
    private let gate = AsyncSerialGate()

    init(transport: RFCOMMTransport?) {
        self.transport = transport
        transport?.delegate = self
        if transport == nil { isClosed = true }
    }

    // MARK: Public API

    /// Runs `body` with exclusive use of the link (FIFO). Do not nest.
    func exclusive<T>(_ body: () async throws -> T) async throws -> T {
        try await gate.run(body)
    }

    /// Sends a command and resolves when the headset acknowledges it.
    func send(_ payload: [UInt8], table: MDRDataType = .dataMdr) async throws {
        try Task.checkCancellation()
        let outgoing = Outgoing(id: makeID(), type: table, payload: payload)
        enqueue(outgoing)
        try await outgoing.ack.value()
    }

    /// Sends a command and resolves with the first matching reply payload. Throws `replyTimeout` if the
    /// headset acknowledges but never answers — callers that verify writes must not swallow that.
    func request(_ payload: [UInt8], table: MDRDataType = .dataMdr, expect matcher: Matcher, timeout: TimeInterval = 2.5) async throws -> [UInt8] {
        guard !isClosed else { throw LinkError.closed }
        try Task.checkCancellation()
        // Register before sending (replies can race the ACK) but only start the clock at transmission.
        // The hook must be installed before `enqueue`: with an idle link the frame is transmitted synchronously.
        let waiter = ReplyWaiter(id: makeID(), matcher: matcher, shot: OneShot())
        waiters.append(waiter)
        let waiterID = waiter.id
        let outgoing = Outgoing(id: makeID(), type: table, payload: payload)
        outgoing.onFirstTransmit = { [weak self] in
            waiter.shot.deadline(timeout, error: LinkError.replyTimeout(command: payload.first ?? 0)) {
                self?.removeWaiter(waiterID)
            }
        }
        enqueue(outgoing)
        do {
            try await withTaskCancellationHandler {
                try await outgoing.ack.value()
            } onCancel: {
                Task { @MainActor in outgoing.ack.resolve(.failure(CancellationError())) }
            }
        } catch {
            removeWaiter(waiterID)
            waiter.shot.resolve(.failure(error))
            throw error
        }
        return try await waiter.shot.value()
    }

    /// Waits for an unsolicited frame (e.g. NC optimizer progress) without sending anything.
    func waitFor(_ matcher: Matcher, timeout: TimeInterval) async throws -> [UInt8] {
        guard !isClosed else { throw LinkError.closed }
        let waiter = ReplyWaiter(id: makeID(), matcher: matcher, shot: OneShot())
        waiters.append(waiter)
        let id = waiter.id
        waiter.shot.deadline(timeout, error: LinkError.replyTimeout(command: matcher.command)) { [weak self] in
            self?.removeWaiter(id)
        }
        return try await waiter.shot.value()
    }

    /// Local shutdown: closes the transport and fails everything pending. `onClose` is not called.
    func close() {
        guard !isClosed else { return }
        transport?.close()
        finish(error: LinkError.closed, notify: false)
    }

    /// Replay only: run a frame recorded from real hardware through the normal handlers. Nothing is sent.
    func injectRecorded(_ frame: MDRFrame) {
        log(.rx, type: frame.type?.description ?? String(format: "0x%02X", frame.rawType), sequence: frame.sequence,
            payload: frame.payload, summary: "replay · " + (describe?(frame) ?? ""))
        onFrame?(frame)
    }

    func note(_ text: String) {
        log(.note, type: "", sequence: nil, payload: [], summary: text)
    }

    // MARK: Transport delegate

    func transport(_ transport: RFCOMMTransport, didReceive bytes: [UInt8]) {
        for output in assembler.append(bytes) {
            switch output {
            case .frame(let frame, _):
                handle(frame)
            case .malformed(let raw, let error):
                log(.rx, type: "BAD", sequence: nil, payload: raw, summary: "Malformed frame dropped: \(error)")
            }
            if isClosed { return }
        }
    }

    func transportDidClose(_ transport: RFCOMMTransport, error: TransportError) {
        note("Transport closed: \(error.localizedDescription)")
        finish(error: error, notify: true)
    }

    // MARK: Internals

    private func makeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    private func enqueue(_ outgoing: Outgoing) {
        if isClosed {
            outgoing.ack.resolve(.failure(LinkError.closed))
        } else {
            queue.append(outgoing)
            pump()
        }
    }

    private func handle(_ frame: MDRFrame) {
        if frame.type == .ack {
            log(.rx, type: "ACK", sequence: frame.sequence, payload: [], summary: "")
            handleAck(sequence: frame.sequence)
            return
        }
        // Acknowledge every data frame first, independently of the command queue.
        guard writeRaw(MDRFrame(type: .ack, sequence: 1 &- (frame.sequence & 1), payload: []), logAs: nil) else { return }
        log(.rx, type: frame.type?.description ?? String(format: "0x%02X", frame.rawType), sequence: frame.sequence,
            payload: frame.payload, summary: describe?(frame) ?? "")
        // State handlers run first so a resumed requester always observes the updated model.
        onFrame?(frame)
        if let index = waiters.firstIndex(where: { $0.matcher.matches(frame) }) {
            waiters.remove(at: index).shot.resolve(.success(frame.payload))
        }
    }

    private func handleAck(sequence ackSequence: UInt8) {
        guard let current = inFlight else { return }
        let expected = 1 &- (sequence & 1)
        guard ackSequence == expected else { return } // stale ACK for an earlier attempt
        sequence = expected
        inFlightTimer?.cancel()
        inFlightTimer = nil
        inFlight = nil
        current.ack.resolve(.success(()))
        pump()
    }

    private func pump() {
        guard inFlight == nil, !isClosed else { return }
        // Drop commands whose caller already gave up (cancelled) before they reached the air.
        while let next = queue.first, next.ack.isResolved { queue.removeFirst() }
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        inFlight = next
        transmit(next)
    }

    private func transmit(_ outgoing: Outgoing) {
        outgoing.attempts += 1
        let frame = MDRFrame(type: outgoing.type, sequence: sequence, payload: outgoing.payload)
        let retry = outgoing.attempts > 1 ? " (retry \(outgoing.attempts - 1))" : ""
        guard writeRaw(frame, logAs: (describe?(frame) ?? "") + retry) else { return }
        if outgoing.attempts == 1, let start = outgoing.onFirstTransmit {
            outgoing.onFirstTransmit = nil
            start()
        }
        let id = outgoing.id
        let timer = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.ackTimedOut(id: id) }
        }
        inFlightTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + ackTimeout, execute: timer)
    }

    private func ackTimedOut(id: Int) {
        guard let current = inFlight, current.id == id, !isClosed else { return }
        if current.attempts >= maxAttempts {
            // The headset may have executed the command with every ACK lost; the sequence bit is now
            // unknowable. Kill the link so the controller re-handshakes from a clean state.
            let error = LinkError.ackTimeout(command: current.payload.first ?? 0)
            note(error.localizedDescription + " Resetting the control channel.")
            transport?.close()
            finish(error: error, notify: true)
            return
        }
        transmit(current)
    }

    @discardableResult
    private func writeRaw(_ frame: MDRFrame, logAs summary: String?) -> Bool {
        guard !isClosed, let transport else { return false }
        do {
            try transport.write(frame.encoded())
            if let summary {
                log(.tx, type: frame.type?.description ?? "?", sequence: frame.sequence, payload: frame.payload, summary: summary)
            }
            return true
        } catch {
            note("Write failed: \(error.localizedDescription)")
            transport.close()
            finish(error: error, notify: true)
            return false
        }
    }

    private func removeWaiter(_ id: Int) {
        waiters.removeAll { $0.id == id }
    }

    private func finish(error: Error, notify: Bool) {
        guard !isClosed else { return }
        isClosed = true
        inFlightTimer?.cancel()
        inFlightTimer = nil
        let pending = (inFlight.map { [$0] } ?? []) + queue
        inFlight = nil
        queue.removeAll()
        for item in pending { item.ack.resolve(.failure(LinkError.closed)) }
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters { waiter.shot.resolve(.failure(LinkError.closed)) }
        if notify { onClose?(error) }
    }

    private func log(_ direction: TrafficEntry.Direction, type: String, sequence: UInt8?, payload: [UInt8], summary: String) {
        let entry = TrafficEntry(id: makeID(), date: Date(), direction: direction, frameType: type,
                                 sequence: sequence, payload: payload, summary: summary)
        traffic.append(entry)
        if traffic.count > 800 { traffic.removeFirst(traffic.count - 800) }
        onTraffic?(entry)
    }
}
