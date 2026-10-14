import Foundation
import SwiftUI

/// A saved, locally stored combination of headphone settings. Only fields that are set are applied.
struct SoundScene: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var symbol: String
    var tint: SceneTint
    var noise: SceneNoise?
    var equalizer: SceneEqualizer?
    var upscaling: Bool?
    var speakToChat: Bool?
    var autoPause: Bool?
    /// General settings by their stable key (e.g. TOUCH_PANEL_SETTING), not by firmware slot.
    var generalSettings: [String: Bool] = [:]
    var trigger: SceneTrigger = .manual
    var triggerEnabled = true
    var lastResult: SceneResult?

    var isEmpty: Bool {
        noise == nil && equalizer == nil && upscaling == nil && speakToChat == nil && autoPause == nil && generalSettings.isEmpty
    }

    /// Changes this scene would make on a headset with the given capabilities, in application order. Each inner
    /// array is applied as one transaction; a custom EQ is [select editable preset, write bands], so the bands
    /// are never written if the preset selection is not confirmed.
    @MainActor
    func changes(for state: DeviceState) -> (changes: [[DeviceChange]], skipped: [String]) {
        var changes: [[DeviceChange]] = []
        var skipped: [String] = []
        let caps = state.capabilities
        if let noise {
            if let cap = caps.noise, cap.modes.contains(noise.mode) {
                var value = state.noise ?? NoiseControl(mode: noise.mode, ambientLevel: noise.ambientLevel, focusOnVoice: noise.focusOnVoice)
                value.mode = noise.mode
                value.ambientLevel = max(cap.ambientRange.lowerBound, min(cap.ambientRange.upperBound, noise.ambientLevel))
                value.focusOnVoice = cap.supportsVoiceFocus && noise.focusOnVoice
                changes.append([.noise(value, dragging: false)])
            } else {
                skipped.append(noise.mode.title)
            }
        }
        switch equalizer {
        case .preset(let id)?:
            if caps.equalizer?.presets.contains(where: { $0.id == id }) == true {
                changes.append([.equalizerPreset(id)])
            } else {
                skipped.append("Equalizer preset")
            }
        case .custom(let bands, let clearBass)?:
            if let cap = caps.equalizer, cap.bandCount == bands.count, let manual = cap.presets.first(where: \.isEditable) {
                changes.append([.equalizerPreset(manual.id),
                                .equalizerBands(bands: bands, clearBass: cap.hasClearBass ? clearBass : nil)])
            } else {
                skipped.append("Custom equalizer")
            }
        case nil:
            break
        }
        if let upscaling {
            if caps.upscalingName != nil { changes.append([.upscaling(upscaling)]) } else { skipped.append("DSEE") }
        }
        if let speakToChat {
            if caps.speakToChat { changes.append([.speakToChat(speakToChat)]) } else { skipped.append("Speak-to-Chat") }
        }
        if let autoPause {
            if caps.autoPause { changes.append([.autoPause(autoPause)]) } else { skipped.append("Pause when taken off") }
        }
        for (key, value) in generalSettings.sorted(by: { $0.key < $1.key }) {
            if let setting = state.generalSettings.first(where: { $0.key == key && $0.isBoolean }) {
                changes.append([.generalSetting(slot: setting.slot, value: value)])
            } else {
                skipped.append(GeneralSetting(slot: 0, key: key, summaryKey: "", isBoolean: true).title)
            }
        }
        return (changes, skipped)
    }

    /// Short human summary for cards ("Noise Canceling · Bright · DSEE on").
    var summary: [String] {
        var parts: [String] = []
        if let noise {
            parts.append(noise.mode == .ambient ? "Ambient \(noise.ambientLevel)\(noise.focusOnVoice ? " · Voice" : "")" : noise.mode.title)
        }
        switch equalizer {
        case .preset(let id)?: parts.append(EqualizerPreset.displayName(for: id))
        case .custom?: parts.append("Custom EQ")
        case nil: break
        }
        if let upscaling { parts.append("DSEE \(upscaling ? "on" : "off")") }
        if let speakToChat { parts.append("Speak-to-Chat \(speakToChat ? "on" : "off")") }
        if let autoPause { parts.append("Auto-pause \(autoPause ? "on" : "off")") }
        for (key, value) in generalSettings.sorted(by: { $0.key < $1.key }) {
            let title = GeneralSetting(slot: 0, key: key, summaryKey: "", isBoolean: true).shortTitle
            parts.append("\(title) \(value ? "on" : "off")")
        }
        return parts
    }

    @MainActor
    static func capture(from state: DeviceState, name: String) -> SoundScene {
        var scene = SoundScene(name: name, symbol: "sparkles", tint: .lavender)
        if let noise = state.noise {
            scene.noise = SceneNoise(mode: noise.mode, ambientLevel: noise.ambientLevel, focusOnVoice: noise.focusOnVoice)
        }
        if let eq = state.equalizer {
            let editable = EqualizerPreset(id: eq.presetID, name: "").isEditable
            scene.equalizer = editable ? .custom(bands: eq.bands, clearBass: eq.clearBass) : .preset(eq.presetID)
        }
        scene.upscaling = state.upscaling?.enabled
        scene.speakToChat = state.speakToChat?.enabled
        scene.autoPause = state.autoPause
        for setting in state.generalSettings where setting.isBoolean && setting.key == "TOUCH_PANEL_SETTING" {
            if let value = setting.value { scene.generalSettings[setting.key] = value }
        }
        return scene
    }
}

struct SceneNoise: Codable, Equatable {
    var mode: NoiseMode
    var ambientLevel: Int
    var focusOnVoice: Bool
}

enum SceneEqualizer: Codable, Equatable {
    case preset(UInt8)
    case custom(bands: [Int], clearBass: Int?)
}

struct SceneSchedule: Codable, Equatable {
    var hour: Int
    var minute: Int
    /// Calendar weekday numbers, 1 = Sunday … 7 = Saturday.
    var weekdays: Set<Int>

    var timeText: String {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    var daysText: String {
        if weekdays.count == 7 { return "Every day" }
        if weekdays == [2, 3, 4, 5, 6] { return "Weekdays" }
        if weekdays == [1, 7] { return "Weekends" }
        let symbols = Calendar.current.shortWeekdaySymbols
        return weekdays.sorted().map { symbols[$0 - 1] }.joined(separator: " ")
    }
}

enum SceneTrigger: Codable, Equatable {
    case manual
    case onConnect
    case schedule(SceneSchedule)
    case appActivated(bundleID: String, appName: String)

    var title: String {
        switch self {
        case .manual: "Manual"
        case .onConnect: "When headphones connect"
        case .schedule(let schedule): "\(schedule.daysText) at \(schedule.timeText)"
        case .appActivated(_, let name): "When \(name) is active"
        }
    }

    var symbol: String {
        switch self {
        case .manual: "hand.tap"
        case .onConnect: "headphones"
        case .schedule: "clock"
        case .appActivated: "macwindow"
        }
    }

    var isAutomatic: Bool { self != .manual }
}

struct SceneResult: Codable, Equatable {
    var date: Date
    var confirmed: Int
    var total: Int
    var problems: [String]
    var skipped: [String]
    var automatic: Bool

    var isClean: Bool { total > 0 && problems.isEmpty && confirmed == total }
}

enum SceneTint: String, Codable, CaseIterable, Identifiable {
    case lavender, amber, ember, sage, ocean, plum, slate
    var id: String { rawValue }

    var color: Color {
        switch self {
        case .lavender: Theme.accent
        case .amber: Color(red: 0.91, green: 0.66, blue: 0.33)
        case .ember: Color(red: 0.89, green: 0.45, blue: 0.33)
        case .sage: Color(red: 0.55, green: 0.71, blue: 0.56)
        case .ocean: Color(red: 0.42, green: 0.62, blue: 0.80)
        case .plum: Color(red: 0.70, green: 0.50, blue: 0.75)
        case .slate: Color(red: 0.62, green: 0.63, blue: 0.66)
        }
    }
}

extension GeneralSetting {
    var shortTitle: String {
        switch key {
        case "TOUCH_PANEL_SETTING": "Touch controls"
        case "MULTIPOINT_SETTING": "Multipoint"
        case "SIDETONE_SETTING": "Call voice capture"
        default: title
        }
    }
}
