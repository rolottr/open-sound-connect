import AppKit
import Observation

/// Reads local macOS media metadata. The helper is bundled and never downloads artwork or sends data.
@MainActor
@Observable
final class SystemNowPlaying {
    struct Item: Decodable {
        let bundleIdentifier: String
        let title: String
        let artist: String?
        let album: String?
        let playing: Bool
        let artworkData: String?
    }

    private(set) var item: Item?
    private(set) var artwork: NSImage?
    private(set) var commandPending = false

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var commandProcess: Process?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var generation = 0

    func start() {
        enabled = true
        guard process == nil else { return }
        guard let child = makeProcess(["stream", "--no-diff", "--debounce=100"]) else { return }
        generation += 1
        let current = generation
        let pipe = Pipe()
        child.standardOutput = pipe
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.process = nil
                self.clear()
                self.retryTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    guard let self, self.enabled else { return }
                    self.start()
                }
            }
        }
        do {
            try child.run()
            process = child
            // A dedicated queue keeps pipe reads off the UI thread and preserves event order.
            DispatchQueue(label: "SoundConnect.NowPlaying").async { [weak self] in
                let handle = pipe.fileHandleForReading
                defer { try? handle.close() }
                while true {
                    // read(upToCount:) can wait to fill its buffer; media events must arrive immediately.
                    let data = handle.availableData
                    guard !data.isEmpty else { break }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == current, self.process != nil else { return }
                        self.receive(data)
                    }
                }
            }
        } catch {
            clear()
        }
    }

    func stop() {
        enabled = false
        generation += 1
        retryTask?.cancel()
        retryTask = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        if let commandProcess, commandProcess.isRunning { commandProcess.terminate() }
        clear()
    }

    /// Playback buttons follow the same player whose metadata is displayed.
    func send(_ command: PlaybackCommand) async -> Bool {
        guard item != nil, !commandPending else { return false }
        let code: String
        switch command {
        case .play: code = "0"
        case .pause: code = "1"
        case .next: code = "4"
        case .previous: code = "5"
        }
        guard let child = makeProcess(["send", code]) else { return false }
        commandPending = true
        commandProcess = child
        defer { commandPending = false; commandProcess = nil }
        return await withCheckedContinuation { continuation in
            child.terminationHandler = { child in
                continuation.resume(returning: child.terminationStatus == 0)
            }
            do {
                try child.run()
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    if child.isRunning { child.terminate() }
                }
            } catch {
                child.terminationHandler = nil
                continuation.resume(returning: false)
            }
        }
    }

    private func makeProcess(_ arguments: [String]) -> Process? {
        guard let resources = Bundle.main.resourceURL,
              let frameworks = Bundle.main.privateFrameworksURL else { return nil }
        let script = resources.appendingPathComponent("mediaremote-adapter.pl")
        let framework = frameworks.appendingPathComponent("MediaRemoteAdapter.framework")
        guard FileManager.default.fileExists(atPath: script.path),
              FileManager.default.fileExists(atPath: framework.path) else { return nil }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        child.arguments = [script.path, framework.path] + arguments
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        return child
    }

    private func clear() {
        item = nil
        artwork = nil
        buffer.removeAll(keepingCapacity: false)
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        // Bound buffering if a broken helper emits an incomplete or oversized artwork record.
        guard buffer.count <= 16 * 1024 * 1024 else {
            clear()
            process?.terminate()
            return
        }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            consume(line)
        }
    }

    /// Full snapshots deliberately replace metadata so a track change cannot retain old artwork.
    func consume(_ line: Data) {
        struct Event: Decodable {
            let type: String
            let diff: Bool?
            let payload: Item?
        }
        // An empty payload means playback disappeared. Unknown events leave the current track alone.
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "data" else { return }
        guard let event = try? JSONDecoder().decode(Event.self, from: line), event.diff != true,
              let value = event.payload, !value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            item = nil
            artwork = nil
            return
        }
        if item?.artworkData != value.artworkData {
            artwork = value.artworkData.flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:))
        }
        item = value
    }
}
