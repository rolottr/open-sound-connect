import Foundation
import Observation

/// What the connected headset has *reported* it supports. Every UI control is gated on these values;
/// nothing is assumed from the model name.
struct Capabilities: Equatable, Sendable {
    var noise: NoiseControlCapability?
    var equalizer: EqualizerCapability?
    var listeningMode: ListeningModeCapability?
    /// Display name of the upscaler ("DSEE Extreme", …) when the headset supports toggling it.
    var upscalingName: String?
    var upscalingIndicator = false
    var connectionPriority = false
    var speakToChat = false
    var speakToChatOptions = false
    /// Seconds per ChatTimeout index as reported by the headset (0 = never). Empty = use generic labels.
    var speakToChatTimeoutSeconds: [UInt8] = []
    var autoPowerOffOptions: [AutoPowerOffOption] = []
    var autoPause = false
    var voiceGuidance = false
    var voiceGuidanceVolume: ClosedRange<Int>?
    var generalSettingSlots: [UInt8] = []
    var assignableKeys: [AssignableKey] = []
    var ncAmbButton = false
    var pairedDevices = false
    var sourceSwitch = false
    var playback = false
    var codecIndicator = false
    var batteryKinds: Set<BatteryKind> = []
    var soundPressure = false
    var wearingStatus = false
    var headGesture = false
    var ncOptimizer = false
    var powerOff = false
    var alerts = false

    enum BatteryKind: Sendable { case single, leftRight, chargingCase }

    var hasAnySoundFeature: Bool { equalizer != nil || upscalingName != nil || listeningMode != nil }
}

struct DeviceAlert: Identifiable, Equatable, Sendable {
    let id = UUID()
    let messageType: UInt8
    let requiresAnswer: Bool

    var title: String {
        switch messageType {
        case 0x01: "Change connection quality?"
        case 0x02: "Change button assignment?"
        case 0x04: "Google Assistant is now available"
        case 0x05: "Voice assistant can't be assigned twice"
        case 0x06: "Turn on connection to 2 devices?"
        case 0x07: "Turn off connection to 2 devices?"
        case 0x08: "Battery life will be shorter"
        default: "Headphones need confirmation"
        }
    }

    var message: String {
        switch messageType {
        case 0x01: "The headphones will disconnect briefly and reconnect to apply the new connection setting."
        case 0x02: "The headphones will disconnect briefly to apply the new button assignment."
        case 0x06, 0x07: "The headphones will disconnect briefly and reconnect to apply the change."
        case 0x08: "Using the equalizer together with DSEE uses more battery."
        default: String(format: "The headphones sent confirmation request 0x%02X.", messageType)
        }
    }
}

/// Live state of the connected headset. Optional values are "not reported (yet)", never guessed defaults.
@MainActor
@Observable
final class DeviceState {
    var family: ProtocolFamily?
    var protocolVersion: Int?
    var modelName: String?
    var firmware: String?
    var seriesCode: UInt8?
    var colorCode: UInt8?
    var uniqueID: String?
    var supportFunctions: [UInt8] = []
    var supportFunctionsTable2: [UInt8] = []
    var capabilities = Capabilities()
    /// True once the headset has listed its functions. Until then nothing may be called "unsupported".
    var capabilitiesKnown = false

    var battery = BatteryState()
    var codec: AudioCodec?
    var noise: NoiseControl?
    var equalizer: EqualizerState?
    /// V2 reports the EQ as unavailable while e.g. Background Music is active.
    var equalizerAvailable: Bool?
    var listeningMode: ListeningMode?
    var upscaling: UpscalingState?
    var connectionPriority: ConnectionPriority?
    var speakToChat: SpeakToChat?
    var autoPowerOff: UInt8?
    var autoPause: Bool?
    var voiceGuidance: Bool?
    var voiceGuidanceVolume: Int?
    var generalSettings: [GeneralSetting] = []
    var assignablePresets: [UInt8]?
    var ncAmbButton: NcAmbButtonCycle?
    var pairedDevices: [PairedDevice]?
    var pairingMode: Bool?
    var nowPlaying = NowPlaying()
    var soundPressure: Int?
    var wearing: WearingState?
    var headGesture: Bool?
    var optimizer: OptimizerPhase = .idle
    var optimizerMeasuredPressure: Int?
    var alert: DeviceAlert?

    /// V1 NC/ASM wire fields echoed back on writes (Sound Connect does the same: tm0/i3 + v30/c).
    var v1NcSettingType: UInt8 = 0x02
    var v1AsmSettingType: UInt8 = 0x01

    func reset() {
        family = nil; protocolVersion = nil; modelName = nil; firmware = nil; seriesCode = nil; colorCode = nil
        uniqueID = nil; supportFunctions = []; supportFunctionsTable2 = []; capabilities = Capabilities(); capabilitiesKnown = false
        battery = BatteryState(); codec = nil; noise = nil; equalizer = nil; equalizerAvailable = nil
        listeningMode = nil; upscaling = nil; connectionPriority = nil; speakToChat = nil; autoPowerOff = nil
        autoPause = nil; voiceGuidance = nil; voiceGuidanceVolume = nil; generalSettings = []; assignablePresets = nil
        ncAmbButton = nil; pairedDevices = nil; pairingMode = nil; nowPlaying = NowPlaying(); soundPressure = nil
        wearing = nil; headGesture = nil; optimizer = .idle; optimizerMeasuredPressure = nil; alert = nil
        v1NcSettingType = 0x02; v1AsmSettingType = 0x01
    }

    var colorName: String? {
        guard let colorCode else { return nil }
        switch colorCode & 0x0F {
        case 0x01: return "Black"
        case 0x02: return "White"
        case 0x03: return "Silver"
        case 0x04: return "Red"
        case 0x05: return "Midnight Blue"
        case 0x06: return "Pink"
        case 0x07: return "Yellow"
        case 0x08: return "Green"
        case 0x09: return "Gray"
        case 0x0A: return "Gold"
        case 0x0B: return "Cream"
        case 0x0C: return "Orange"
        case 0x0D: return "Brown"
        case 0x0E: return "Violet"
        default: return nil
        }
    }

    var seriesName: String? {
        switch seriesCode {
        case 0x10?: "EXTRA BASS"
        case 0x11?: "ULT POWER SOUND"
        case 0x20?: "h.ear"
        case 0x30?: "1000X Premium"
        case 0x40?: "Sports"
        case 0x50?: "Casual"
        case 0x60?: "LinkBuds"
        default: nil
        }
    }

    func setting(slot: UInt8) -> GeneralSetting? { generalSettings.first { $0.slot == slot } }

    func upsertSetting(_ setting: GeneralSetting) {
        if let index = generalSettings.firstIndex(where: { $0.slot == setting.slot }) {
            generalSettings[index] = setting
        } else {
            generalSettings.append(setting)
            generalSettings.sort { $0.slot < $1.slot }
        }
    }
}
