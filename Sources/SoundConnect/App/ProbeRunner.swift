import AppKit
import Foundation

/// Headless hardware diagnostics: `Sound Connect.app/Contents/MacOS/Sound Connect --probe [--exercise] [--out FILE]`.
/// Launch it through LaunchServices (`open -n -W "Sound Connect.app" --args --probe …`) so the app, not the
/// terminal, is the Bluetooth-responsible process.
///
/// * `--probe` connects, initializes, and writes identity, capabilities, every reported value and the full
///   frame log. Read-only.
/// * `--exercise` additionally performs reversible write → read back → restore cycles. It never touches
///   power, the NC optimizer (plays tones), volume, playback, pairing mode, connection quality or
///   multipoint/button assignment (those reconnect the headset), and it restores each original value.
@MainActor
final class ProbeRunner {
    private let controller = HeadphoneController()
    private let exercise: Bool
    private let outputURL: URL
    private var lines: [String] = []
    private var passes = 0
    private var failures = 0

    init(arguments: [String]) {
        exercise = arguments.contains("--exercise")
        if let index = arguments.firstIndex(of: "--out"), index + 1 < arguments.count {
            outputURL = URL(fileURLWithPath: arguments[index + 1])
        } else {
            let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Sound Connect")
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            outputURL = logs.appendingPathComponent("probe-\(stamp).txt")
        }
    }

    func run() async -> Int32 {
        say("Sound Connect probe \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev") — \(Date())")
        say("Mode: \(exercise ? "read + reversible write/readback/restore" : "read-only")")
        controller.start()

        guard await waitUntil(seconds: 120, { self.controller.bluetooth.status == .ready || self.controller.bluetooth.status == .denied || self.controller.bluetooth.status == .poweredOff }) else {
            say("FAIL Bluetooth permission was not granted within 120 s (status \(controller.bluetooth.status)).")
            return finish(2)
        }
        guard controller.bluetooth.status == .ready else {
            say("FAIL Bluetooth status: \(controller.bluetooth.status)")
            return finish(2)
        }
        say("Bluetooth authorized and powered on.")
        controller.rescan()
        for known in controller.knownHeadphones {
            say("Paired: \(known.name) \(known.address) connected=\(known.isConnected) sonyService=\(known.publishesService)")
        }
        let initiate = CommandLine.arguments.contains("--initiate")
        guard let target = controller.knownHeadphones.first(where: { $0.isConnected && $0.publishesService })
                ?? (initiate ? controller.knownHeadphones.first(where: \.publishesService) : nil) else {
            say("FAIL No connected Sony headphones that publish the control service (use --initiate to connect paired ones).")
            return finish(3)
        }
        if !controller.isConnecting && !controller.isConnected {
            if !target.isConnected { say("Asking macOS to connect \(target.name) (normal paired-device connection)…") }
            controller.connect(address: target.address, initiate: !target.isConnected)
        }
        let connected = await waitUntil(seconds: 40) {
            if case .failed = self.controller.phase { return true }
            return self.controller.phase == .connected
        }
        guard connected, controller.phase == .connected else {
            say("FAIL Connection phase: \(controller.phase)")
            dumpTraffic()
            return finish(4)
        }
        say("Connected and initialized.")
        report()
        if let index = CommandLine.arguments.firstIndex(of: "--set-ambient-voice-focus"), index + 1 < CommandLine.arguments.count,
           let original = controller.state.noise {
            // Repair helper: set the stored ambient voice-focus preference, then return to the current mode.
            let wanted = CommandLine.arguments[index + 1] == "on"
            var ambient = original
            ambient.mode = .ambient
            ambient.focusOnVoice = wanted
            await step("Ambient voice focus \(wanted ? "on" : "off")", .noise(ambient, dragging: false))
            var back = original
            back.focusOnVoice = wanted
            await step("Return to \(original.mode.title)", .noise(back, dragging: false))
        }
        if exercise {
            await runExercises()
        }
        if CommandLine.arguments.contains("--exercise-scenes") {
            await runSceneExercise()
        }
        controller.refreshStatus()
        try? await Task.sleep(for: .seconds(2))
        say("\nFinal values after probe:")
        reportValues()
        dumpVerifications()
        dumpTraffic()
        say("\nSummary: \(passes) passed, \(failures) failed.")
        controller.disconnect()
        return finish(failures == 0 ? 0 : 1)
    }

    // MARK: Report

    private func report() {
        let s = controller.state
        say("\nIdentity")
        say("  Model: \(s.modelName ?? "?")  Firmware: \(s.firmware ?? "?")  Protocol: \(s.family?.rawValue ?? "?") v\(s.protocolVersion.map { String(format: "0x%04X", $0) } ?? "?")")
        say("  Series: \(s.seriesName ?? String(describing: s.seriesCode))  Color: \(s.colorName ?? String(describing: s.colorCode))")
        say("  Support functions (T1): \(s.supportFunctions.hex)")
        if !s.supportFunctionsTable2.isEmpty { say("  Support functions (T2): \(s.supportFunctionsTable2.hex)") }
        let c = s.capabilities
        say("\nCapabilities")
        if let noise = c.noise {
            say("  Noise control: modes \(noise.modes.map(\.title)), ambient \(noise.ambientRange), voice focus \(noise.supportsVoiceFocus), auto ambient \(noise.supportsAutoAmbient)")
        }
        if let eq = c.equalizer {
            say("  Equalizer: \(eq.bandCount) bands \(eq.bandRange), clear bass \(eq.hasClearBass), presets \(eq.presets.map { String(format: "%02X:%@", $0.id, $0.name) })")
        }
        if let listening = c.listeningMode { say("  Listening mode: BGM \(listening.backgroundMusic), cinema \(listening.cinema)") }
        say("  Upscaling: \(c.upscalingName ?? "no")  indicator \(c.upscalingIndicator)  codec indicator \(c.codecIndicator)")
        say("  Connection priority: \(c.connectionPriority)  Speak-to-Chat: \(c.speakToChat) options \(c.speakToChatOptions)")
        say("  Auto power off options: \(c.autoPowerOffOptions.map(\.title))")
        say("  Pause when taken off: \(c.autoPause)  Voice guidance: \(c.voiceGuidance)  Paired devices: \(c.pairedDevices)")
        say("  General settings: \(s.generalSettings.map { "\(String(format: "%02X", $0.slot))=\($0.key)\($0.isBoolean ? "" : "(list)")" })")
        say("  Assignable keys: \(c.assignableKeys.map { "\($0.title) options \($0.options.hex)" })")
        say("  Playback: \(c.playback)  NC optimizer: \(c.ncOptimizer)  Power off: \(c.powerOff)  Batteries: \(c.batteryKinds)")
        say("\nValues")
        reportValues()
    }

    private func reportValues() {
        let s = controller.state
        say("  Battery: \(s.battery.main.map { "\($0.level)% \($0.charging)" } ?? "-")  L/R: \(s.battery.left.map { "\($0.level)%" } ?? "-")/\(s.battery.right.map { "\($0.level)%" } ?? "-")")
        say("  Codec: \(s.codec?.title ?? "-")  DSEE: \(s.upscaling.map { "enabled=\($0.enabled) active=\(String(describing: $0.active))" } ?? "-")")
        say("  Noise: \(s.noise.map { "\($0.mode.title) level \($0.ambientLevel) voice \($0.focusOnVoice) last \($0.lastActiveMode.title)" } ?? "-")")
        say("  Equalizer: \(s.equalizer.map { "\(EqualizerPreset.displayName(for: $0.presetID)) bands \($0.bands) clearBass \(String(describing: $0.clearBass))" } ?? "-") available \(String(describing: s.equalizerAvailable))")
        say("  Connection priority: \(s.connectionPriority?.title ?? "-")")
        say("  Speak-to-Chat: \(s.speakToChat.map { "enabled=\($0.enabled) sensitivity=\($0.sensitivity?.title ?? "-") timeout=\($0.timeout?.title ?? "-") voiceFocus=\(String(describing: $0.voiceFocus))" } ?? "-")")
        say("  Auto power off: \(s.autoPowerOff.map { AutoPowerOffOption(id: $0).title } ?? "-")  Pause when taken off: \(s.autoPause.map(String.init) ?? "-")")
        say("  Voice guidance: \(s.voiceGuidance.map(String.init) ?? "-")  Pairing mode: \(s.pairingMode.map(String.init) ?? "-")")
        for setting in s.generalSettings { say("  \(setting.title): \(setting.value.map(String.init) ?? "-")") }
        say("  Button assignment: \(s.assignablePresets?.hex ?? "-")")
        say("  Paired devices: \(s.pairedDevices?.map { "\($0.name)\($0.connected ? " (connected)" : "")\($0.isPlaybackSource ? " [playback]" : "")" } ?? [])")
        say("  Now playing: \(s.nowPlaying.title ?? "-") — \(s.nowPlaying.artist ?? "-")  status \(String(describing: s.nowPlaying.status)) volume \(s.nowPlaying.volume.map(String.init) ?? "-")")
        say("  NC optimizer: \(s.optimizer) pressure \(String(describing: s.optimizerMeasuredPressure))")
    }

    // MARK: Exercises

    private func runExercises() async {
        say("\nExercises (write → read back → restore)")
        let s = controller.state

        if let original = s.noise, let cap = s.capabilities.noise {
            var ambient = original
            ambient.mode = .ambient
            ambient.ambientLevel = original.ambientLevel == 10 ? 12 : 10
            ambient.focusOnVoice = cap.supportsVoiceFocus ? !original.focusOnVoice : false
            await step("Ambient sound level \(ambient.ambientLevel), voice \(ambient.focusOnVoice)", .noise(ambient, dragging: false))
            for mode in cap.modes where mode != .ambient {
                var value = original
                value.mode = mode
                await step("Noise mode \(mode.title)", .noise(value, dragging: false))
            }
            // The XM4 keeps the ambient voice-focus preference while in NC/wind/off and ignores the ASM-ID byte
            // there (observed), so restore it through ambient mode before returning to the original mode.
            // The stored ambient *level* is not reported outside ambient mode, so it can only be restored when
            // the headset started in ambient mode.
            if original.mode != .ambient {
                var ambientRestore = original
                ambientRestore.mode = .ambient
                await step("Restore ambient voice focus (\(original.focusOnVoice ? "on" : "off")) at level \(original.ambientLevel)", .noise(ambientRestore, dragging: false))
                say("    note: the headset reports ambient level 0 outside ambient mode, so level \(original.ambientLevel) is the app's")
                say("          remembered/fallback value, not a value read from the headset before this run.")
            }
            await step("Restore noise control (\(original.mode.title))", .noise(original, dragging: false))
        } else {
            say("  SKIP noise control (not reported)")
        }

        if let eq = s.equalizer, let cap = s.capabilities.equalizer {
            let originalPreset = eq.presetID
            if let other = cap.presets.first(where: { $0.id != originalPreset && !$0.isEditable && $0.id != 0x00 }) {
                await step("EQ preset \(other.name)", .equalizerPreset(other.id))
            }
            if let manual = cap.presets.first(where: { $0.id == 0xA0 }) ?? cap.presets.first(where: \.isEditable) {
                if await step("EQ preset \(manual.name)", .equalizerPreset(manual.id)), let manualEQ = s.equalizer {
                    var bands = manualEQ.bands
                    if !bands.isEmpty { bands[0] = bands[0] >= cap.bandRange.upperBound ? bands[0] - 2 : bands[0] + 2 }
                    let clearBass = manualEQ.clearBass.map { $0 >= cap.bandRange.upperBound ? $0 - 1 : $0 + 1 }
                    await step("EQ bands \(bands) clear bass \(String(describing: clearBass))", .equalizerBands(bands: bands, clearBass: clearBass))
                    await step("Restore \(manual.name) bands", .equalizerBands(bands: manualEQ.bands, clearBass: manualEQ.clearBass))
                }
            }
            await step("Restore EQ preset \(EqualizerPreset.displayName(for: originalPreset))", .equalizerPreset(originalPreset))
        } else {
            say("  SKIP equalizer (not reported)")
        }

        if let upscaling = s.upscaling {
            await toggle("DSEE", upscaling.enabled) { .upscaling($0) }
        }
        if let stc = s.speakToChat {
            await toggle("Speak-to-Chat", stc.enabled) { .speakToChat($0) }
            if let sensitivity = stc.sensitivity, let timeout = stc.timeout {
                let newSensitivity: ChatSensitivity = sensitivity == .high ? .low : .high
                let newTimeout: ChatTimeout = timeout == .long ? .short : .long
                await step("Speak-to-Chat \(newSensitivity.title), \(newTimeout.title)", .speakToChatOptions(newSensitivity, newTimeout))
                await step("Restore Speak-to-Chat options", .speakToChatOptions(sensitivity, timeout))
            }
        }
        if let pause = s.autoPause {
            await toggle("Pause when taken off", pause) { .autoPause($0) }
        }
        if let autoOff = s.autoPowerOff, let other = s.capabilities.autoPowerOffOptions.first(where: { $0.id != autoOff && $0.id != 0x00 }) {
            await step("Auto power off: \(other.title)", .autoPowerOff(other.id))
            await step("Restore auto power off: \(AutoPowerOffOption(id: autoOff).title)", .autoPowerOff(autoOff))
        }
        for setting in s.generalSettings where setting.isBoolean {
            guard let value = setting.value else { continue }
            if setting.key.contains("MULTIPOINT") {
                say("  SKIP \(setting.title) (changing it reconnects the headset; verify manually)")
                continue
            }
            await toggle(setting.title, value) { .generalSetting(slot: setting.slot, value: $0) }
        }
        if let guidance = s.voiceGuidance {
            await toggle("Voice guidance", guidance) { .voiceGuidance($0) }
        }
        say("  SKIP connection quality, button assignment, multipoint (headset reconnects), NC optimizer (plays tones),")
        say("       power off, pairing mode, playback and volume (audible / user-facing) — verify these manually.")
    }

    /// Applies a temporary scene through the real SceneStore / performGroup path (incl. the atomic
    /// [select Manual, write bands] group), then restores every original value. Uses a throw-away scene file.
    private func runSceneExercise() async {
        say("\nScene exercise (temporary scene, never saved to the user's scenes)")
        let s = controller.state
        guard let originalEQ = s.equalizer, let cap = s.capabilities.equalizer,
              let manual = cap.presets.first(where: { $0.id == 0xA0 }) ?? cap.presets.first(where: \.isEditable),
              let originalNoise = s.noise else {
            say("  SKIP scene exercise: equalizer or noise control not reported")
            return
        }
        let original = SoundScene.capture(from: s, name: "Original")
        // Remember Manual's stored bands so the custom-EQ step can be undone exactly.
        let toManual = await controller.performGroup([.equalizerPreset(manual.id)], quiet: true)
        guard toManual.failed == nil, let manualEQ = controller.state.equalizer else {
            say("  FAIL could not read \(manual.name) bands")
            failures += 1
            return
        }
        say("  \(manual.name) stored bands \(manualEQ.bands) clear bass \(String(describing: manualEQ.clearBass))")
        _ = await controller.performGroup([.equalizerPreset(originalEQ.presetID)], quiet: true)

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("sound-connect-probe-scenes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let store = SceneStore(controller: controller, fileURL: tempURL)
        var test = SoundScene(name: "Probe Scene", symbol: "sparkles", tint: .lavender)
        // Ambient at the headset's currently stored level (20, restored by earlier runs) with voice focus off, so
        // the XM4's hidden ambient settings end unchanged after returning to the original mode.
        test.noise = SceneNoise(mode: .ambient, ambientLevel: 20, focusOnVoice: false)
        let curve = [1, 2, 3, 2, 1].map { min(cap.bandRange.upperBound, $0) }
        test.equalizer = .custom(bands: curve, clearBass: cap.hasClearBass ? 2 : nil)
        if let dsee = s.upscaling?.enabled { test.upscaling = !dsee }
        if let stc = s.speakToChat?.enabled { test.speakToChat = !stc }
        store.upsert(test)
        let applied = await store.apply(test.id)
        record("Apply test scene", applied)
        let reflected = controller.state.noise?.mode == .ambient && controller.state.equalizer?.presetID == manual.id
            && controller.state.equalizer?.bands == curve
        say("  \(reflected ? "PASS" : "FAIL") read-back shows ambient + \(manual.name) curve \(controller.state.equalizer?.bands ?? [])")
        if reflected { passes += 1 } else { failures += 1 }

        // Restore: Manual's bands, then the captured original (noise via ambient voice-focus first, see quirk).
        let restoreManual = await controller.performGroup([.equalizerBands(bands: manualEQ.bands, clearBass: manualEQ.clearBass)], quiet: true)
        say("  \(restoreManual.failed == nil ? "PASS" : "FAIL") restore \(manual.name) bands")
        if restoreManual.failed == nil { passes += 1 } else { failures += 1 }
        var restore = original
        restore.id = UUID()
        if originalNoise.mode != .ambient {
            var viaAmbient = originalNoise
            viaAmbient.mode = .ambient
            viaAmbient.ambientLevel = 20
            _ = await controller.perform(.noise(viaAmbient, dragging: false), quiet: true)
        }
        store.upsert(restore)
        let restored = await store.apply(restore.id)
        record("Restore original via scene", restored)
        if let noise = controller.state.noise {
            say("  Final noise: \(noise.mode.title) voice \(noise.focusOnVoice); EQ \(EqualizerPreset.displayName(for: controller.state.equalizer?.presetID ?? 0)) \(controller.state.equalizer?.bands ?? [])")
        }
    }

    private func record(_ name: String, _ result: SceneResult?) {
        guard let result else {
            say("  FAIL \(name): not applied")
            failures += 1
            return
        }
        let ok = result.isClean
        if ok { passes += 1 } else { failures += 1 }
        say("  \(ok ? "PASS" : "FAIL") \(name): \(result.confirmed)/\(result.total) confirmed\(result.problems.isEmpty ? "" : "; problems: \(result.problems.joined(separator: ", "))")\(result.skipped.isEmpty ? "" : "; skipped: \(result.skipped.joined(separator: ", "))")")
    }

    private func toggle(_ name: String, _ original: Bool, _ make: (Bool) -> DeviceChange) async {
        await step("\(name) → \(!original ? "on" : "off")", make(!original))
        await step("Restore \(name) (\(original ? "on" : "off"))", make(original))
    }

    @discardableResult
    private func step(_ name: String, _ change: DeviceChange) async -> Bool {
        let ok = await controller.perform(change, quiet: true)
        if let alert = controller.state.alert {
            say("    ! headset asked: \(alert.title) — answering No")
            controller.answerAlert(accept: false)
        }
        if ok { passes += 1 } else { failures += 1 }
        let outcome = controller.verifications.first.map { record -> String in
            switch record.outcome {
            case .confirmed: return "confirmed by read-back"
            case .mismatch: return "MISMATCH after read-back"
            case .adjusted(let detail): return "ADJUSTED: \(detail)"
            case .notCheckable: return "sent"
            case .failed(let error): return "ERROR \(error)"
            }
        } ?? "?"
        say("  \(ok ? "PASS" : "FAIL") \(name): \(outcome)")
        try? await Task.sleep(for: .milliseconds(250))
        return ok
    }

    private func dumpVerifications() {
        say("\nVerification records: \(controller.verifications.count)")
    }

    private func dumpTraffic() {
        say("\nFrame log (\(controller.traffic.count) entries)")
        say(controller.trafficLog)
    }

    // MARK: Plumbing

    private func waitUntil(seconds: Double, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return condition()
    }

    private func say(_ line: String) {
        lines.append(line)
        print(line)
    }

    private func finish(_ code: Int32) -> Int32 {
        try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").appending("\n").write(to: outputURL, atomically: true, encoding: .utf8)
        print("Report written to \(outputURL.path)")
        return code
    }
}

@MainActor
final class ProbeAppDelegate: NSObject, NSApplicationDelegate {
    private let runner = ProbeRunner(arguments: CommandLine.arguments)

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let code = await runner.run()
            exit(code)
        }
    }
}
