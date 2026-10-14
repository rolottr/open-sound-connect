import Foundation

/// A single user-visible change. Scenes are lists of these; every change is written and then read back.
enum DeviceChange: Equatable, Sendable {
    case noise(NoiseControl, dragging: Bool)
    case equalizerPreset(UInt8)
    case equalizerBands(bands: [Int], clearBass: Int?)
    case listeningMode(ListeningMode)
    case upscaling(Bool)
    case connectionPriority(ConnectionPriority)
    case speakToChat(Bool)
    case speakToChatOptions(ChatSensitivity, ChatTimeout)
    case autoPowerOff(UInt8)
    case autoPause(Bool)
    case voiceGuidance(Bool)
    case voiceGuidanceVolume(Int)
    case generalSetting(slot: UInt8, value: Bool)
    case assignable([UInt8])
    case ncAmbButton(NcAmbButtonCycle)
    case headGesture(Bool)
    case pairingMode(Bool)
    case playback(PlaybackCommand)
    case volume(Int)

    var label: String {
        switch self {
        case .noise(let value, _): value.mode.title
        case .equalizerPreset(let id): "Equalizer: \(EqualizerPreset.displayName(for: id))"
        case .equalizerBands: "Equalizer bands"
        case .listeningMode(let mode): "Listening mode: \(mode.title)"
        case .upscaling(let on): "DSEE \(on ? "on" : "off")"
        case .connectionPriority(let value): value.title
        case .speakToChat(let on): "Speak-to-Chat \(on ? "on" : "off")"
        case .speakToChatOptions: "Speak-to-Chat options"
        case .autoPowerOff(let id): "Auto power off: \(AutoPowerOffOption(id: id).title)"
        case .autoPause(let on): "Pause when taken off \(on ? "on" : "off")"
        case .voiceGuidance(let on): "Voice guidance \(on ? "on" : "off")"
        case .voiceGuidanceVolume: "Voice guidance volume"
        case .generalSetting: "Headphone setting"
        case .assignable: "Button assignment"
        case .ncAmbButton: "NC/AMB button"
        case .headGesture(let on): "Head gestures \(on ? "on" : "off")"
        case .pairingMode(let on): on ? "Pairing mode" : "Leave pairing mode"
        case .playback: "Playback"
        case .volume: "Volume"
        }
    }

    /// XM4 volume can round to an adjacent step (observed: request 17, read back 16).
    /// Record the actual value as an adjustment, never claim an exact match or relax mute verification.
    @MainActor
    func adjustment(in state: DeviceState) -> String? {
        guard case .volume(let requested) = self, (1..<30).contains(requested),
              let actual = state.nowPlaying.volume, (0...30).contains(actual),
              abs(actual - requested) == 1 else { return nil }
        return "Requested volume \(requested); headphones reported \(actual)."
    }

    /// Whether the read-back state matches the request. `nil` = not checkable (momentary commands).
    @MainActor
    func isReflected(in state: DeviceState) -> Bool? {
        switch self {
        case .noise(let wanted, _):
            guard let actual = state.noise else { return false }
            if actual.mode != wanted.mode { return false }
            if wanted.mode == .ambient, state.capabilities.noise?.ambientRange != nil {
                if actual.ambientLevel != wanted.ambientLevel { return false }
                if state.capabilities.noise?.supportsVoiceFocus == true, actual.focusOnVoice != wanted.focusOnVoice { return false }
            }
            if state.capabilities.noise?.supportsAutoAmbient == true, actual.autoAmbient != wanted.autoAmbient { return false }
            return true
        case .equalizerPreset(let id): return state.equalizer?.presetID == id
        case .equalizerBands(let bands, let clearBass):
            guard let eq = state.equalizer else { return false }
            return eq.bands == bands && (clearBass == nil || eq.clearBass == clearBass)
        case .listeningMode(let mode): return state.listeningMode == mode
        case .upscaling(let on): return state.upscaling?.enabled == on
        case .connectionPriority(let value): return state.connectionPriority == value
        case .speakToChat(let on): return state.speakToChat?.enabled == on
        case .speakToChatOptions(let sensitivity, let timeout):
            return state.speakToChat?.sensitivity == sensitivity && state.speakToChat?.timeout == timeout
        case .autoPowerOff(let id): return state.autoPowerOff == id
        case .autoPause(let on): return state.autoPause == on
        case .voiceGuidance(let on): return state.voiceGuidance == on
        case .voiceGuidanceVolume(let value): return state.voiceGuidanceVolume == value
        case .generalSetting(let slot, let value): return state.setting(slot: slot)?.value == value
        case .assignable(let presets): return state.assignablePresets == presets
        case .ncAmbButton(let cycle): return state.ncAmbButton == cycle
        case .headGesture(let on): return state.headGesture == on
        case .pairingMode(let on): return state.pairingMode == on
        case .volume(let value): return state.nowPlaying.volume == value
        case .playback: return nil
        }
    }
}

enum DriverError: LocalizedError {
    case unsupported(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let what): "\(what) is not supported by these headphones."
        case .malformed(let what): "Unexpected reply: \(what)."
        }
    }
}

/// Protocol-family specific implementation. All mutating calls are expected to run inside `link.exclusive`.
@MainActor
protocol HeadphoneDriver: AnyObject {
    var link: MDRLink { get }
    var state: DeviceState { get }

    func handle(_ frame: MDRFrame)
    func describe(_ frame: MDRFrame) -> String

    /// Handshake, identity, capabilities and every current value.
    func initialize() async throws
    /// Volatile values that the headset does not always notify (battery, codec, playback).
    func refreshStatus() async throws
    /// Writes one change and reads the affected value back from the headset.
    func apply(_ change: DeviceChange) async throws
    func answerAlert(_ alert: DeviceAlert, accept: Bool) async throws
    func startNoiseOptimizer() async throws
    func cancelNoiseOptimizer() async throws
    func powerOff() async throws
}

extension HeadphoneDriver {
    /// Bluetooth volume synchronization may finish after the write ACK. Re-read, without sending the
    /// volume again, before deciding whether it matched, rounded, or failed.
    func readVolumeBack(_ requested: Int, payload: [UInt8], expect: MDRLink.Matcher) async throws {
        try await readBack(payload, expect: expect)
        for delay in [150, 350] where state.nowPlaying.volume != requested {
            try await Task.sleep(for: .milliseconds(delay))
            try await readBack(payload, expect: expect)
        }
        link.note("Volume requested \(requested), reported \(state.nowPlaying.volume.map(String.init) ?? "unavailable")")
    }

    /// Mandatory read-back after a write. A missing reply throws, so a write is never reported as confirmed on
    /// the strength of an older, already-equal value. Must run inside the same `link.exclusive` transaction as
    /// the write so no other operation can consume the reply.
    func readBack(_ payload: [UInt8], table: MDRDataType = .dataMdr, expect: MDRLink.Matcher, timeout: TimeInterval = 3.0) async throws {
        _ = try await link.request(payload, table: table, expect: expect, timeout: timeout)
    }

    /// A request whose reply is optional: missing replies degrade a feature instead of failing the connection.
    /// Discovery and status refresh only — never for verifying writes.
    func ask(_ payload: [UInt8], table: MDRDataType = .dataMdr, expect: MDRLink.Matcher, timeout: TimeInterval = 2.0) async throws -> [UInt8]? {
        do {
            return try await link.request(payload, table: table, expect: expect, timeout: timeout)
        } catch MDRLink.LinkError.replyTimeout {
            link.note(String(format: "No reply to %@ — feature treated as unavailable.", payload.hex))
            return nil
        }
    }
}
