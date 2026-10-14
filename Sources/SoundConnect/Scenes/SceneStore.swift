import AppKit
import Foundation
import Observation

/// Persists scenes to ~/Library/Application Support/Sound Connect/scenes.json and runs them.
@MainActor
@Observable
final class SceneStore {
    private(set) var scenes: [SoundScene] = []
    private(set) var runningSceneID: UUID?
    private(set) var lastAutomaticRun: (sceneID: UUID, date: Date)?
    var saveError: String?

    private let fileURL: URL
    private let controller: HeadphoneController
    private var scheduleTimer: Timer?
    private var firedToday: [UUID: String] = [:]
    private var activationObserver: NSObjectProtocol?
    private var lastAppTrigger: [UUID: Date] = [:]

    /// `fileURL` overrides the storage location (the hardware probe uses a throw-away file so it never touches the
    /// user's scenes or the seeding flag).
    init(controller: HeadphoneController, fileURL: URL? = nil) {
        self.controller = controller
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sound Connect", isDirectory: true)
        self.fileURL = fileURL ?? support.appendingPathComponent("scenes.json")
        if fileURL == nil { load() }
    }

    // MARK: Persistence

    private func load() {
        if let data = try? Data(contentsOf: fileURL) {
            do {
                scenes = try JSONDecoder().decode([SoundScene].self, from: data)
            } catch {
                saveError = "Could not read saved scenes: \(error.localizedDescription)"
                // Keep the unreadable file aside instead of overwriting the user's data.
                let backup = fileURL.deletingPathExtension().appendingPathExtension("unreadable.json")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.copyItem(at: fileURL, to: backup)
            }
        } else if !UserDefaults.standard.bool(forKey: "seededScenes") {
            scenes = Self.starterScenes
            UserDefaults.standard.set(true, forKey: "seededScenes")
            save()
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(scenes).write(to: fileURL, options: .atomic)
            saveError = nil
        } catch {
            saveError = "Could not save scenes: \(error.localizedDescription)"
        }
    }

    var storageLocation: URL { fileURL }

    static let starterScenes: [SoundScene] = [
        SoundScene(name: "Deep Focus", symbol: "brain.head.profile", tint: .lavender,
                   noise: SceneNoise(mode: .noiseCancelling, ambientLevel: 20, focusOnVoice: false),
                   speakToChat: false),
        SoundScene(name: "Out & About", symbol: "figure.walk", tint: .sage,
                   noise: SceneNoise(mode: .ambient, ambientLevel: 12, focusOnVoice: false)),
        SoundScene(name: "Conversation", symbol: "person.2.wave.2", tint: .ocean,
                   noise: SceneNoise(mode: .ambient, ambientLevel: 18, focusOnVoice: true)),
    ]

    // MARK: Editing

    func scene(_ id: UUID) -> SoundScene? { scenes.first { $0.id == id } }

    func upsert(_ scene: SoundScene) {
        if let index = scenes.firstIndex(where: { $0.id == scene.id }) {
            scenes[index] = scene
        } else {
            scenes.append(scene)
        }
        save()
        rescheduleTriggers()
    }

    func delete(_ id: UUID) {
        scenes.removeAll { $0.id == id }
        save()
        rescheduleTriggers()
    }

    func duplicate(_ id: UUID) {
        guard var copy = scene(id) else { return }
        copy.id = UUID()
        copy.name += " Copy"
        copy.lastResult = nil
        copy.trigger = .manual
        scenes.append(copy)
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        scenes.move(fromOffsets: source, toOffset: destination)
        save()
    }

    // MARK: Running

    /// Whether the connected headphones currently match every setting in `scene`, judged from live state (not from
    /// the scene's last result). False while disconnected or before capabilities are known, when the scene has no
    /// applicable settings, or when any of its settings is unsupported here (it can never be fully in effect).
    /// Uses the same per-change comparison as write verification, so hidden fields are ignored the same way
    /// (e.g. the stored ambient level while noise canceling is on) and a custom EQ needs both preset and bands.
    func isApplied(_ scene: SoundScene) -> Bool {
        let state = controller.state
        guard controller.isConnected, state.capabilitiesKnown else { return false }
        let (groups, skipped) = scene.changes(for: state)
        guard skipped.isEmpty, !groups.isEmpty else { return false }
        return groups.allSatisfy { group in group.allSatisfy { $0.isReflected(in: state) == true } }
    }

    /// Whether the user can apply `scene` right now (live connection, nothing running, not already in effect).
    func canApply(_ scene: SoundScene) -> Bool {
        controller.canWrite && runningSceneID == nil && !scene.isEmpty && !isApplied(scene)
    }

    /// Applies each setting in turn; every one is written and read back by the controller.
    @discardableResult
    func apply(_ id: UUID, automatic: Bool = false) async -> SceneResult? {
        guard let scene = scene(id), runningSceneID == nil else { return nil }
        // Already in effect on the headphones: nothing to write (manual paths are disabled; automations no-op).
        guard !isApplied(scene) else { return nil }
        guard controller.canWrite else {
            if !automatic {
                controller.showToast(.warning, controller.isReplay ? "This is a read-only replay. Scenes can't be applied."
                                                                  : "Connect your headphones to apply “\(scene.name)”.")
            }
            return nil
        }
        let (groups, skipped) = scene.changes(for: controller.state)
        guard !groups.isEmpty else {
            controller.showToast(.warning, "None of the settings in “\(scene.name)” are supported by these headphones.")
            return nil
        }
        runningSceneID = id
        defer { runningSceneID = nil }
        let total = groups.reduce(0) { $0 + $1.count }
        var confirmed = 0
        var problems: [String] = []
        for group in groups {
            let result = await controller.performGroup(group, quiet: true)
            confirmed += result.confirmed
            if let failed = result.failed {
                problems.append(failed)
                // Dependent steps after a failure (e.g. EQ bands after an unconfirmed preset) were not written.
                problems += group.dropFirst(result.confirmed + 1).map { "\($0.label) (not written)" }
            }
        }
        let result = SceneResult(date: Date(), confirmed: confirmed, total: total, problems: problems,
                                 skipped: skipped, automatic: automatic)
        if let index = scenes.firstIndex(where: { $0.id == id }) {
            scenes[index].lastResult = result
            save()
        }
        if automatic { lastAutomaticRun = (id, Date()) }
        if result.isClean {
            let skippedNote = skipped.isEmpty ? "" : " (\(skipped.count) not supported)"
            controller.showToast(.info, "\(automatic ? "Automatically applied" : "Applied") “\(scene.name)”\(skippedNote).")
        } else {
            controller.showToast(.warning, "“\(scene.name)”: \(confirmed) of \(total) applied. Not applied: \(problems.joined(separator: ", ")).")
        }
        return result
    }

    // MARK: Automation

    func startAutomation() {
        guard !controller.isReplay else { return }
        controller.onConnected = { [weak self] in
            self?.handleConnected()
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated { self?.handleActivation(bundleID: bundleID) }
        }
        rescheduleTriggers()
    }

    private func rescheduleTriggers() {
        scheduleTimer?.invalidate()
        guard scenes.contains(where: { if case .schedule = $0.trigger { return $0.triggerEnabled }; return false }) else { return }
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSchedules() }
        }
    }

    private func handleConnected() {
        guard let scene = scenes.first(where: { $0.trigger == .onConnect && $0.triggerEnabled }) else { return }
        Task { await apply(scene.id, automatic: true) }
    }

    private func handleActivation(bundleID: String?) {
        guard let bundleID, controller.isConnected else { return }
        for scene in scenes where scene.triggerEnabled {
            guard case .appActivated(let target, _) = scene.trigger, target == bundleID else { continue }
            // Don't re-apply on every app switch: once per 10 minutes per scene.
            if let last = lastAppTrigger[scene.id], Date().timeIntervalSince(last) < 600 { continue }
            lastAppTrigger[scene.id] = Date()
            Task { await apply(scene.id, automatic: true) }
            return
        }
    }

    private func checkSchedules() {
        let now = Date()
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: now)
        let dayKey = now.formatted(.iso8601.year().month().day())
        for scene in scenes where scene.triggerEnabled {
            guard case .schedule(let schedule) = scene.trigger,
                  schedule.weekdays.contains(parts.weekday ?? 0),
                  parts.hour == schedule.hour, parts.minute == schedule.minute,
                  firedToday[scene.id] != dayKey else { continue }
            firedToday[scene.id] = dayKey
            if controller.isConnected {
                Task { await apply(scene.id, automatic: true) }
            } else {
                controller.showToast(.info, "“\(scene.name)” was scheduled now, but the headphones aren't connected.")
            }
        }
    }
}
