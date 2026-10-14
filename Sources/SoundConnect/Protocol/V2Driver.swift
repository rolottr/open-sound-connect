import Foundation

/// MDR protocol V2 (WH-1000XM5 / XM6 class; service 956C7B26-…).
/// NOT hardware-verified in this project (only a WH-1000XM4 was available). Layouts follow the MIT libmdr
/// V2 tables and its WF-1000XM5 capture; every feature is gated on the advertised function list.
/// Note V2's inverted on/off encoding: ON = 0x00, OFF = 0x01.
@MainActor
final class V2Driver: HeadphoneDriver {
    let link: MDRLink
    let state: DeviceState

    enum T1 {
        static let codecIndicator: UInt8 = 0x12
        static let upscalingIndicator: UInt8 = 0x13
        static let battery: UInt8 = 0x20, leftRightBattery: UInt8 = 0x21, cradleBattery: UInt8 = 0x22
        static let powerOff: UInt8 = 0x23, autoPowerOff: UInt8 = 0x24, autoPowerOffWearing: UInt8 = 0x25
        static let batteryThreshold: UInt8 = 0x28, lrBatteryThreshold: UInt8 = 0x29, cradleBatteryThreshold: UInt8 = 0x2A
        static let presetEQ: UInt8 = 0x50, presetEQFixed: UInt8 = 0x52, presetEQUlt: UInt8 = 0x53, presetEQError: UInt8 = 0x57
        static let ambientLevelOnly: UInt8 = 0x67
        static let ncAmbToggle: UInt8 = 0x69
        static let modeNcAsmDual: UInt8 = 0x6B
        static let modeNcAsmAdaptive: UInt8 = 0x6D
        static let fixedMessage: UInt8 = 0x90
        static let playback: [UInt8] = [0xA1, 0xA2, 0xA3, 0xA4]
        static let generalSettings: [UInt8] = [0xD1, 0xD2, 0xD3, 0xD4]
        static let connectionMode: UInt8 = 0xE1
        static let upscaling: UInt8 = 0xE2
        static let bgm: [UInt8] = [0xE4, 0xEB, 0x45]
        static let cinema: UInt8 = 0xE5
        static let listeningOption: UInt8 = 0xE6
        static let autoPause: UInt8 = 0xF1
        static let assignable: UInt8 = 0xF3
        static let assignableLimited: UInt8 = 0xFE
        static let wearingDetector: UInt8 = 0xF6
        static let speakToChat: UInt8 = 0xFC
        static let headGesture: UInt8 = 0xFF
    }

    enum T2 {
        static let pairingClassic: UInt8 = 0x30
        static let sourceSwitch: UInt8 = 0x31
        static let pairingCoD: [UInt8] = [0x32, 0x33]
        static let voiceGuidance: [UInt8] = [0x40, 0x41, 0x42, 0x43, 0x44, 0x45]
        static let voiceGuidanceVolume: [UInt8] = [0x42, 0x43]
        static let safeListening: [UInt8] = [0x50, 0x52, 0x51, 0x53]
        static let wearingChecker: UInt8 = 0xF0
    }

    private var hasTable2 = false
    private var eqInquiredType: UInt8 = 0x00
    private var ncInquiredType: UInt8?
    private var assignableType: UInt8?
    private var peripheralType: UInt8?
    private var safeListeningType: UInt8?

    init(link: MDRLink, state: DeviceState) {
        self.link = link
        self.state = state
    }

    private func t1(_ f: UInt8) -> Bool { state.supportFunctions.contains(f) }
    private func t1Any(_ fs: [UInt8]) -> Bool { fs.contains { t1($0) } }
    private func t2(_ f: UInt8) -> Bool { state.supportFunctionsTable2.contains(f) }
    private func t2Any(_ fs: [UInt8]) -> Bool { fs.contains { t2($0) } }

    // MARK: Initialization

    func initialize() async throws {
        let info = try await link.request([0x00, 0x00], expect: .init(.dataMdr, 0x01))
        hasTable2 = info.byte(7) == 0x00
        _ = try await ask([0x02, 0x00], expect: .init(.dataMdr, 0x03))
        for type: UInt8 in [0x02, 0x01, 0x03] {
            _ = try await ask([0x04, type], expect: .init(.dataMdr, 0x05, type))
        }
        guard try await ask([0x06, 0x00], expect: .init(.dataMdr, 0x07)) != nil else {
            throw DriverError.malformed("the headphones did not list their functions")
        }
        if hasTable2 {
            _ = try await ask([0x06, 0x00], table: .dataMdrNo2, expect: .init(.dataMdrNo2, 0x07))
        }

        var caps = Capabilities()
        caps.codecIndicator = t1(T1.codecIndicator)
        caps.powerOff = t1(T1.powerOff)
        caps.playback = t1Any(T1.playback)
        caps.connectionPriority = t1(T1.connectionMode)
        caps.autoPause = t1(T1.autoPause)
        caps.speakToChat = t1(T1.speakToChat)
        caps.speakToChatOptions = t1(T1.speakToChat)
        caps.headGesture = t1(T1.headGesture)
        caps.ncAmbButton = t1(T1.ncAmbToggle)
        caps.alerts = t1(T1.fixedMessage)
        caps.voiceGuidance = hasTable2 && t2Any(T2.voiceGuidance)
        caps.voiceGuidanceVolume = hasTable2 && t2Any(T2.voiceGuidanceVolume) ? -2...2 : nil
        caps.wearingStatus = hasTable2 && (t2(T2.wearingChecker) || t1(T1.wearingDetector) || t1(T1.autoPause))
        if t1(T1.battery) || t1(T1.batteryThreshold) { caps.batteryKinds.insert(.single) }
        if t1(T1.leftRightBattery) || t1(T1.lrBatteryThreshold) { caps.batteryKinds.insert(.leftRight) }
        if t1(T1.cradleBattery) || t1(T1.cradleBatteryThreshold) { caps.batteryKinds.insert(.chargingCase) }
        if t1(T1.listeningOption) && (t1Any(T1.bgm) || t1(T1.cinema)) {
            caps.listeningMode = ListeningModeCapability(backgroundMusic: t1Any(T1.bgm), cinema: t1(T1.cinema))
        }
        if t1(T1.autoPowerOff) {
            caps.autoPowerOffOptions = [0x00, 0x04, 0x01, 0x02, 0x03, 0x11].map(AutoPowerOffOption.init(id:))
        } else if t1(T1.autoPowerOffWearing) {
            caps.autoPowerOffOptions = [0x10, 0x00, 0x04, 0x01, 0x02, 0x03, 0x11].map(AutoPowerOffOption.init(id:))
        }
        if hasTable2 {
            if t2Any(T2.pairingCoD) { peripheralType = 0x02 } else if t2(T2.pairingClassic) { peripheralType = 0x00 }
            caps.pairedDevices = peripheralType != nil
            caps.sourceSwitch = t2(T2.sourceSwitch)
            safeListeningType = [(0x50, 0x00), (0x52, 0x02), (0x51, 0x01), (0x53, 0x03)].first { t2($0.0) }.map { UInt8($0.1) }
            caps.soundPressure = safeListeningType != nil
        }
        if t1(T1.modeNcAsmAdaptive) {
            ncInquiredType = 0x19
            caps.noise = NoiseControlCapability(modes: [.noiseCancelling, .ambient, .off], ambientRange: 0...20,
                                                supportsVoiceFocus: true, supportsAutoAmbient: true)
        } else if t1(T1.modeNcAsmDual) {
            ncInquiredType = 0x17
            caps.noise = NoiseControlCapability(modes: [.noiseCancelling, .ambient, .off], ambientRange: 0...20,
                                                supportsVoiceFocus: true, supportsAutoAmbient: false)
        } else if t1(T1.ambientLevelOnly) {
            ncInquiredType = 0x22
            caps.noise = NoiseControlCapability(modes: [.ambient, .off], ambientRange: 0...20,
                                                supportsVoiceFocus: true, supportsAutoAmbient: false)
        }
        state.capabilities = caps
        state.capabilitiesKnown = true


        for slot in T1.generalSettings where t1(slot) {
            _ = try await ask([0xD0, slot, 0x01], expect: .init(.dataMdr, 0xD1, slot))
            _ = try await ask([0xD6, slot], expect: .init(.dataMdr, 0xD7, slot))
        }
        if t1(T1.upscaling) {
            _ = try await ask([0xE0, 0x01], expect: .init(.dataMdr, 0xE1, 0x01))
        }
        if t1(T1.assignableLimited) { assignableType = 0x0E } else if t1(T1.assignable) { assignableType = 0x03 }
        if let assignableType {
            _ = try await ask([0xF0, assignableType], expect: .init(.dataMdr, 0xF1, assignableType))
        }
        if t1(T1.fixedMessage) {
            try await link.send([0x94, 0x00, 0x00])
        }
        if t1Any([T1.presetEQ, T1.presetEQFixed, T1.presetEQUlt, T1.presetEQError]) {
            let type: UInt8 = t1(T1.presetEQ) ? 0x00 : t1(T1.presetEQFixed) ? 0x02 : t1(T1.presetEQUlt) ? 0x03 : 0x04
            _ = try await ask([0x50, type, 0x01], expect: .init(.dataMdr, 0x51, type))
        }
        try await readAllValues()
    }

    private func readAllValues() async throws {
        if let ncInquiredType {
            _ = try await ask([0x66, ncInquiredType], expect: .init(.dataMdr, 0x67, ncInquiredType))
        }
        if t1(T1.ncAmbToggle) {
            _ = try await ask([0x66, 0x30], expect: .init(.dataMdr, 0x67, 0x30))
        }
        if state.capabilities.equalizer != nil {
            _ = try await ask([0x52, eqInquiredType], expect: .init(.dataMdr, 0x53, eqInquiredType))
            _ = try await ask([0x56, eqInquiredType], expect: .init(.dataMdr, 0x57, eqInquiredType))
        }
        if let listening = state.capabilities.listeningMode {
            if listening.backgroundMusic { _ = try await ask([0xE6, 0x09], expect: .init(.dataMdr, 0xE7, 0x09)) }
            if listening.cinema { _ = try await ask([0xE6, 0x04], expect: .init(.dataMdr, 0xE7, 0x04)) }
            resolveListeningMode()
        }
        if t1(T1.connectionMode) { _ = try await ask([0xE6, 0x00], expect: .init(.dataMdr, 0xE7, 0x00)) }
        if t1(T1.upscaling) { _ = try await ask([0xE6, 0x01], expect: .init(.dataMdr, 0xE7, 0x01)) }
        if let assignableType { _ = try await ask([0xF6, assignableType], expect: .init(.dataMdr, 0xF7, assignableType)) }
        if t1(T1.speakToChat) {
            _ = try await ask([0xF6, 0x0C], expect: .init(.dataMdr, 0xF7, 0x0C))
            _ = try await ask([0xFA, 0x0C], expect: .init(.dataMdr, 0xFB, 0x0C))
        }
        if t1(T1.headGesture) { _ = try await ask([0xF6, 0x0F], expect: .init(.dataMdr, 0xF7, 0x0F)) }
        if t1(T1.autoPowerOff) {
            _ = try await ask([0x26, 0x04], expect: .init(.dataMdr, 0x27, 0x04))
        } else if t1(T1.autoPowerOffWearing) {
            _ = try await ask([0x26, 0x05], expect: .init(.dataMdr, 0x27, 0x05))
        }
        if t1(T1.autoPause) { _ = try await ask([0xF6, 0x01], expect: .init(.dataMdr, 0xF7, 0x01)) }
        if hasTable2 {
            if let peripheralType {
                _ = try await ask([0x32, peripheralType], table: .dataMdrNo2, expect: .init(.dataMdrNo2, 0x33, peripheralType))
            }
            if state.capabilities.voiceGuidance {
                _ = try await ask([0x46, 0x01], table: .dataMdrNo2, expect: .init(.dataMdrNo2, 0x47, 0x01))
            }
            if state.capabilities.voiceGuidanceVolume != nil {
                _ = try await ask([0x46, 0x20], table: .dataMdrNo2, expect: .init(.dataMdrNo2, 0x47, 0x20))
            }
        }
        if t1(T1.codecIndicator) { _ = try await ask([0x12, 0x02], expect: .init(.dataMdr, 0x13, 0x02)) }
        try await refreshStatus()
    }

    func refreshStatus() async throws {
        if t1(T1.battery) { _ = try await ask([0x22, 0x00], expect: .init(.dataMdr, 0x23, 0x00)) }
        else if t1(T1.batteryThreshold) { _ = try await ask([0x22, 0x08], expect: .init(.dataMdr, 0x23, 0x08)) }
        if t1(T1.leftRightBattery) { _ = try await ask([0x22, 0x01], expect: .init(.dataMdr, 0x23, 0x01)) }
        else if t1(T1.lrBatteryThreshold) { _ = try await ask([0x22, 0x09], expect: .init(.dataMdr, 0x23, 0x09)) }
        if t1(T1.cradleBattery) { _ = try await ask([0x22, 0x02], expect: .init(.dataMdr, 0x23, 0x02)) }
        else if t1(T1.cradleBatteryThreshold) { _ = try await ask([0x22, 0x0A], expect: .init(.dataMdr, 0x23, 0x0A)) }
        if t1Any(T1.playback) {
            _ = try await ask([0xA2, 0x01], expect: .init(.dataMdr, 0xA3, 0x01))
            _ = try await ask([0xA6, 0x01], expect: .init(.dataMdr, 0xA7, 0x01))
            _ = try await ask([0xA6, 0x20], expect: .init(.dataMdr, 0xA7, 0x20))
        }
        if hasTable2 {
            if let peripheralType {
                _ = try await ask([0x36, peripheralType], table: .dataMdrNo2, expect: .init(.dataMdrNo2, 0x37, peripheralType))
            }
            if let safeListeningType {
                _ = try await ask([0x5A, safeListeningType], table: .dataMdrNo2, expect: .init(.dataMdrNo2, 0x5B, safeListeningType))
            }
            if state.capabilities.wearingStatus {
                _ = try await ask([0xF2, 0x00], table: .dataMdrNo2, expect: .init(.dataMdrNo2, 0xF3, 0x00))
            }
        }
    }

    // MARK: Writes

    private func onOff(_ on: Bool) -> UInt8 { on ? 0x00 : 0x01 }

    func apply(_ change: DeviceChange) async throws {
        switch change {
        case .noise(let value, let dragging):
            guard let ncInquiredType else { throw DriverError.unsupported("Ambient sound control") }
            let changing: UInt8 = dragging ? 0x00 : 0x01
            let total: UInt8 = value.mode == .off ? 0x00 : 0x01
            let mode: UInt8 = value.mode == .ambient ? 0x01 : 0x00
            let voice: UInt8 = value.focusOnVoice ? 0x01 : 0x00
            let level = UInt8(clamping: max(0, min(20, value.ambientLevel)))
            var payload: [UInt8]
            switch ncInquiredType {
            case 0x22: payload = [0x68, 0x22, changing, total, voice, level]
            case 0x19: payload = [0x68, 0x19, changing, total, mode, voice, level, value.autoAmbient ? 0x01 : 0x00, value.adaptiveSensitivity.rawValue]
            default: payload = [0x68, 0x17, changing, total, mode, voice, level]
            }
            try await link.send(payload)
            if !dragging { try await readBack([0x66, ncInquiredType], expect: .init(.dataMdr, 0x67, ncInquiredType)) }

        case .ncAmbButton(let cycle):
            guard t1(T1.ncAmbToggle) else { throw DriverError.unsupported("NC/AMB button") }
            try await link.send([0x68, 0x30, cycle.rawValue])
            try await readBack([0x66, 0x30], expect: .init(.dataMdr, 0x67, 0x30))

        case .equalizerPreset(let id):
            guard state.capabilities.equalizer != nil else { throw DriverError.unsupported("Equalizer") }
            try await link.send([0x58, eqInquiredType, id, 0x00])
            try await readBack([0x56, eqInquiredType], expect: .init(.dataMdr, 0x57, eqInquiredType))

        case .equalizerBands(let bands, let clearBass):
            guard let cap = state.capabilities.equalizer, bands.count == cap.bandCount else { throw DriverError.unsupported("Equalizer") }
            let preset = state.equalizer?.presetID ?? 0xA0
            var steps: [UInt8]
            if cap.bandCount == 10 {
                steps = bands.map { UInt8(clamping: $0 + 6) }
            } else {
                steps = [UInt8(clamping: (clearBass ?? 0) + 10)] + bands.map { UInt8(clamping: $0 + 10) }
            }
            try await link.send([0x58, eqInquiredType, preset, UInt8(steps.count)] + steps)
            try await readBack([0x56, eqInquiredType], expect: .init(.dataMdr, 0x57, eqInquiredType))

        case .listeningMode(let mode):
            guard let cap = state.capabilities.listeningMode else { throw DriverError.unsupported("Listening mode") }
            // Deactivate first, then activate (mirrors libmdr ordering; avoids a transient double mode).
            let wantsBackgroundMusic = Optional(mode).isBackgroundMusic
            if cap.backgroundMusic, !wantsBackgroundMusic, state.listeningMode.isBackgroundMusic {
                try await link.send([0xE8, 0x09, onOff(false), bgmRoom.rawValue])
            }
            if cap.cinema, mode != .cinema, state.listeningMode == .cinema {
                try await link.send([0xE8, 0x04, onOff(false)])
            }
            switch mode {
            case .backgroundMusic(let room) where cap.backgroundMusic:
                try await link.send([0xE8, 0x09, onOff(true), room.rawValue])
            case .cinema where cap.cinema:
                try await link.send([0xE8, 0x04, onOff(true)])
            case .standard:
                break
            default:
                throw DriverError.unsupported(mode.title)
            }
            if cap.backgroundMusic { try await readBack([0xE6, 0x09], expect: .init(.dataMdr, 0xE7, 0x09)) }
            if cap.cinema { try await readBack([0xE6, 0x04], expect: .init(.dataMdr, 0xE7, 0x04)) }
            resolveListeningMode()

        case .upscaling(let on):
            guard t1(T1.upscaling) else { throw DriverError.unsupported("DSEE") }
            try await link.send([0xE8, 0x01, on ? 0x01 : 0x00])
            try await readBack([0xE6, 0x01], expect: .init(.dataMdr, 0xE7, 0x01))

        case .connectionPriority(let value):
            guard t1(T1.connectionMode) else { throw DriverError.unsupported("Connection quality") }
            try await link.send([0xE8, 0x00, value.rawValue])
            try await readBack([0xE6, 0x00], expect: .init(.dataMdr, 0xE7, 0x00), timeout: V1Driver.confirmationTimeout)

        case .speakToChat(let on):
            guard t1(T1.speakToChat) else { throw DriverError.unsupported("Speak-to-Chat") }
            try await link.send([0xF8, 0x0C, onOff(on), onOff(false)])
            try await readBack([0xF6, 0x0C], expect: .init(.dataMdr, 0xF7, 0x0C))

        case .speakToChatOptions(let sensitivity, let timeout):
            guard t1(T1.speakToChat) else { throw DriverError.unsupported("Speak-to-Chat") }
            try await link.send([0xFC, 0x0C, sensitivity.rawValue, timeout.rawValue])
            try await readBack([0xFA, 0x0C], expect: .init(.dataMdr, 0xFB, 0x0C))

        case .autoPowerOff(let id):
            if t1(T1.autoPowerOff) {
                try await link.send([0x28, 0x04, id, 0x00])
                try await readBack([0x26, 0x04], expect: .init(.dataMdr, 0x27, 0x04))
            } else if t1(T1.autoPowerOffWearing) {
                try await link.send([0x28, 0x05, id, 0x00])
                try await readBack([0x26, 0x05], expect: .init(.dataMdr, 0x27, 0x05))
            } else {
                throw DriverError.unsupported("Automatic power off")
            }

        case .autoPause(let on):
            guard t1(T1.autoPause) else { throw DriverError.unsupported("Pause when taken off") }
            try await link.send([0xF8, 0x01, onOff(on)])
            try await readBack([0xF6, 0x01], expect: .init(.dataMdr, 0xF7, 0x01))

        case .headGesture(let on):
            guard t1(T1.headGesture) else { throw DriverError.unsupported("Head gestures") }
            try await link.send([0xF8, 0x0F, onOff(on)])
            try await readBack([0xF6, 0x0F], expect: .init(.dataMdr, 0xF7, 0x0F))

        case .generalSetting(let slot, let value):
            guard t1(slot), state.setting(slot: slot)?.isBoolean == true else { throw DriverError.unsupported("This setting") }
            try await link.send([0xD8, slot, 0x00, onOff(value)])
            let confirms = state.setting(slot: slot)?.key.contains("MULTIPOINT") == true
            try await readBack([0xD6, slot], expect: .init(.dataMdr, 0xD7, slot), timeout: confirms ? V1Driver.confirmationTimeout : 4)

        case .assignable(let presets):
            guard let assignableType else { throw DriverError.unsupported("Button assignment") }
            try await link.send([0xF8, assignableType, UInt8(presets.count)] + presets)
            try await readBack([0xF6, assignableType], expect: .init(.dataMdr, 0xF7, assignableType), timeout: V1Driver.confirmationTimeout)

        case .voiceGuidance(let on):
            guard hasTable2, state.capabilities.voiceGuidance else { throw DriverError.unsupported("Voice guidance") }
            try await link.send([0x48, 0x01, onOff(on)], table: .dataMdrNo2)
            try await readBack([0x46, 0x01], table: .dataMdrNo2, expect: .init(.dataMdrNo2, 0x47, 0x01))

        case .voiceGuidanceVolume(let value):
            guard hasTable2, let range = state.capabilities.voiceGuidanceVolume else { throw DriverError.unsupported("Voice guidance volume") }
            let clamped = Int8(max(range.lowerBound, min(range.upperBound, value)))
            try await link.send([0x48, 0x20, UInt8(bitPattern: clamped), onOff(true)], table: .dataMdrNo2)
            try await readBack([0x46, 0x20], table: .dataMdrNo2, expect: .init(.dataMdrNo2, 0x47, 0x20))

        case .pairingMode(let on):
            guard hasTable2, let peripheralType else { throw DriverError.unsupported("Pairing mode") }
            try await link.send([0x34, peripheralType, on ? 0x01 : 0x00, 0x00], table: .dataMdrNo2)
            try await readBack([0x32, peripheralType], table: .dataMdrNo2, expect: .init(.dataMdrNo2, 0x33, peripheralType))

        case .playback(let command):
            guard t1Any(T1.playback) else { throw DriverError.unsupported("Playback control") }
            try await link.send([0xA4, 0x01, 0x00, command.rawValue])
            try await readBack([0xA2, 0x01], expect: .init(.dataMdr, 0xA3, 0x01))

        case .volume(let value):
            guard t1Any(T1.playback) else { throw DriverError.unsupported("Volume") }
            try await link.send([0xA8, 0x20, UInt8(clamping: max(0, min(30, value)))])
            try await readVolumeBack(value, payload: [0xA6, 0x20], expect: .init(.dataMdr, 0xA7, 0x20))
        }
    }

    func answerAlert(_ alert: DeviceAlert, accept: Bool) async throws {
        try await link.send([0x98, 0x00, alert.messageType, accept ? 0x01 : 0x00])
    }

    func startNoiseOptimizer() async throws { throw DriverError.unsupported("NC Optimizer") }
    func cancelNoiseOptimizer() async throws { throw DriverError.unsupported("NC Optimizer") }

    func powerOff() async throws {
        guard t1(T1.powerOff) else { throw DriverError.unsupported("Power off") }
        try await link.send([0x24, 0x03, 0x01])
    }

    // MARK: Inbound

    private var bgmOn: Bool?
    private var bgmRoom: RoomSize = .small
    private var cinemaOn: Bool?

    private func resolveListeningMode() {
        if bgmOn == true { state.listeningMode = .backgroundMusic(bgmRoom) }
        else if cinemaOn == true { state.listeningMode = .cinema }
        else if bgmOn != nil || cinemaOn != nil { state.listeningMode = .standard }
    }

    func handle(_ frame: MDRFrame) {
        let p = frame.payload
        guard let command = p.first else { return }
        do {
            if frame.type == .dataMdr { try handleTable1(command, p) }
            else if frame.type == .dataMdrNo2 { try handleTable2(command, p) }
        } catch {
            link.note(String(format: "Could not parse reply %02X: %@", command, p.hex))
        }
    }

    private static func charging(_ raw: UInt8) -> ChargingState {
        switch raw {
        case 0x00: .notCharging
        case 0x01: .charging
        case 0x03: .charged
        default: .unknown
        }
    }

    private func handleTable1(_ command: UInt8, _ p: [UInt8]) throws {
        var r = ByteReader(p, offset: 1)
        switch command {
        case 0x01:
            _ = try r.u8()
            state.protocolVersion = try r.u16() << 16 | (try r.u16())
        case 0x03:
            _ = try r.u8(); _ = try r.u8()
            state.uniqueID = try r.string()
        case 0x05:
            switch try r.u8() {
            case 0x01: state.modelName = try r.string()
            case 0x02: state.firmware = try r.string()
            case 0x03: state.seriesCode = try r.u8(); state.colorCode = try r.u8()
            default: break
            }
        case 0x07:
            _ = try r.u8()
            let count = Int(try r.u8())
            state.supportFunctions = (0..<count).compactMap { _ in
                let f = try? r.u8(); _ = try? r.u8(); return f
            }
        case 0x13, 0x15:
            if try r.u8() == 0x02 { state.codec = AudioCodec(rawValue: try r.u8()) ?? .other }
        case 0x23, 0x25:
            let type = try r.u8()
            switch type {
            case 0x00, 0x08: state.battery.main = BatteryReading(level: Int(try r.u8()), charging: Self.charging(try r.u8()))
            case 0x01, 0x09:
                state.battery.left = BatteryReading(level: Int(try r.u8()), charging: Self.charging(try r.u8()))
                state.battery.right = BatteryReading(level: Int(try r.u8()), charging: Self.charging(try r.u8()))
            case 0x02, 0x0A: state.battery.chargingCase = BatteryReading(level: Int(try r.u8()), charging: Self.charging(try r.u8()))
            default: break
            }
        case 0x27, 0x29:
            let type = try r.u8()
            if type == 0x04 || type == 0x05 { state.autoPowerOff = try r.u8() }
        case 0x51:
            let type = try r.u8()
            eqInquiredType = type
            let bandCount = Int(try r.u8())
            let steps = Int(try r.u8())
            if type == 0x03 { _ = try r.u8() }
            let count = Int(try r.u8())
            var presets: [EqualizerPreset] = []
            for _ in 0..<count {
                let id = try r.u8()
                let name = try r.string()
                presets.append(EqualizerPreset(id: id, name: name.isEmpty ? EqualizerPreset.displayName(for: id) : name))
            }
            let five = bandCount == 6
            let center = five ? 10 : max(1, (steps - 1) / 2)
            state.capabilities.equalizer = EqualizerCapability(presets: presets, bandCount: five ? 5 : bandCount,
                                                               bandRange: -center...center, hasClearBass: five)
        case 0x53, 0x55:
            _ = try r.u8()
            state.equalizerAvailable = try r.u8() == 0x00
        case 0x57, 0x59:
            _ = try r.u8()
            let preset = try r.u8()
            let count = Int(try r.u8())
            let raw = try r.take(count).map(Int.init)
            var eq = state.equalizer ?? EqualizerState(presetID: preset, bands: [], clearBass: nil)
            eq.presetID = preset
            if count == 6 { eq.clearBass = raw[0] - 10; eq.bands = raw[1...].map { $0 - 10 } }
            else if count == 10 { eq.clearBass = nil; eq.bands = raw.map { $0 - 6 } }
            state.equalizer = eq
        case 0x67, 0x69:
            let type = try r.u8()
            switch type {
            case 0x17, 0x19:
                _ = try r.u8()
                let total = try r.u8()
                let mode = try r.u8()
                let voice = try r.u8()
                let level = Int(try r.u8())
                let configured: NoiseMode = mode == 0x01 ? .ambient : .noiseCancelling
                var value = NoiseControl(mode: total == 0x01 ? configured : .off, ambientLevel: level,
                                         focusOnVoice: voice == 0x01, lastActiveMode: configured)
                if type == 0x19 {
                    value.autoAmbient = try r.u8() == 0x01
                    value.adaptiveSensitivity = AdaptiveSensitivity(rawValue: try r.u8()) ?? .standard
                }
                state.noise = value
            case 0x22:
                _ = try r.u8()
                let total = try r.u8()
                let voice = try r.u8()
                let level = Int(try r.u8())
                state.noise = NoiseControl(mode: total == 0x01 ? .ambient : .off, ambientLevel: level,
                                           focusOnVoice: voice == 0x01, lastActiveMode: .ambient)
            case 0x30:
                state.ncAmbButton = NcAmbButtonCycle(rawValue: try r.u8())
            default:
                break
            }
        case 0xA3, 0xA5:
            _ = try r.u8(); _ = try r.u8()
            state.nowPlaying.status = PlaybackStatus(rawValue: try r.u8())
        case 0xA7, 0xA9:
            let type = try r.u8()
            if type == 0x20 {
                state.nowPlaying.volume = Int(try r.u8())
            } else if type == 0x01 {
                var names: [String?] = []
                for _ in 0..<3 {
                    let status = try r.u8()
                    let text = try r.string()
                    names.append(status == 0x02 && !text.isEmpty ? text : nil)
                }
                state.nowPlaying.title = names[0]
                state.nowPlaying.album = names[1]
                state.nowPlaying.artist = names[2]
            }
        case 0xD1:
            let slot = try r.u8()
            let settingType = try r.u8()
            _ = try r.u8()
            let key = try r.string()
            let summary = try r.string()
            var setting = state.setting(slot: slot) ?? GeneralSetting(slot: slot, key: key, summaryKey: summary, isBoolean: false, value: nil)
            setting.key = key
            setting.summaryKey = summary
            setting.isBoolean = settingType == 0x00
            state.upsertSetting(setting)
            if !state.capabilities.generalSettingSlots.contains(slot) { state.capabilities.generalSettingSlots.append(slot) }
        case 0xD7, 0xD9:
            let slot = try r.u8()
            let settingType = try r.u8()
            let value = try r.u8()
            var setting = state.setting(slot: slot) ?? GeneralSetting(slot: slot, key: "", summaryKey: "", isBoolean: settingType == 0x00, value: nil)
            if settingType == 0x00 { setting.value = value == 0x00 }
            state.upsertSetting(setting)
        case 0xE1:
            if try r.u8() == 0x01 { state.capabilities.upscalingName = V1Driver.upscalingName(try r.u8()) }
        case 0xE7, 0xE9:
            let type = try r.u8()
            switch type {
            case 0x00: state.connectionPriority = ConnectionPriority(rawValue: try r.u8())
            case 0x01:
                state.upscaling = UpscalingState(enabled: try r.u8() == 0x01, active: nil)
            case 0x03, 0x09:
                bgmOn = try r.u8() == 0x00
                bgmRoom = RoomSize(rawValue: try r.u8()) ?? .small
                resolveListeningMode()
            case 0x04:
                cinemaOn = try r.u8() == 0x00
                resolveListeningMode()
            default: break
            }
        case 0xF1:
            let type = try r.u8()
            guard type == assignableType else { break }
            if type == 0x0E { _ = try r.u8() }
            let keyCount = Int(try r.u8())
            var keys: [AssignableKey] = []
            for index in 0..<keyCount {
                let key = try r.u8(), keyType = try r.u8(), defaultPreset = try r.u8()
                let presetCount = Int(try r.u8())
                var options: [UInt8] = []
                for _ in 0..<presetCount {
                    options.append(try r.u8())
                    try r.skip(Int(try r.u8()) * 2)
                }
                keys.append(AssignableKey(index: index, key: key, keyType: keyType, defaultPreset: defaultPreset, options: options))
            }
            state.capabilities.assignableKeys = keys
        case 0xF7, 0xF9:
            let type = try r.u8()
            switch type {
            case 0x01: state.autoPause = try r.u8() == 0x00
            case 0x0C:
                var stc = state.speakToChat ?? SpeakToChat(enabled: false)
                stc.enabled = try r.u8() == 0x00
                state.speakToChat = stc
            case 0x0F: state.headGesture = try r.u8() == 0x00
            case 0x03, 0x0E:
                let count = Int(try r.u8())
                state.assignablePresets = try r.take(count)
            default: break
            }
        case 0xFB, 0xFD:
            guard try r.u8() == 0x0C else { break }
            var stc = state.speakToChat ?? SpeakToChat(enabled: false)
            stc.sensitivity = ChatSensitivity(rawValue: try r.u8())
            stc.timeout = ChatTimeout(rawValue: try r.u8())
            state.speakToChat = stc
        case 0x99:
            guard try r.u8() == 0x00 else { break }
            let message = try r.u8()
            let action = try r.u8()
            state.alert = DeviceAlert(messageType: message, requiresAnswer: action == 0x01)
        default:
            break
        }
    }

    private func handleTable2(_ command: UInt8, _ p: [UInt8]) throws {
        var r = ByteReader(p, offset: 1)
        switch command {
        case 0x07:
            _ = try r.u8()
            let count = Int(try r.u8())
            state.supportFunctionsTable2 = (0..<count).compactMap { _ in
                let f = try? r.u8(); _ = try? r.u8(); return f
            }
        case 0x33, 0x35:
            _ = try r.u8()
            state.pairingMode = try r.u8() == 0x01
        case 0x37, 0x39:
            let type = try r.u8()
            guard type == 0x00 || type == 0x02 else { break }
            let count = Int(try r.u8())
            var devices: [PairedDevice] = []
            for _ in 0..<count {
                let address = String(decoding: try r.take(17), as: UTF8.self)
                let connected = try r.u8()
                if type == 0x02 { try r.skip(3) }
                let name = try r.string()
                devices.append(PairedDevice(address: address, name: name, connected: connected != 0, isPlaybackSource: false))
            }
            if let playback = try? r.u8(), playback >= 1, Int(playback) <= devices.count {
                devices[Int(playback) - 1].isPlaybackSource = true
            }
            state.pairedDevices = devices
        case 0x47, 0x49:
            let type = try r.u8()
            if type == 0x20 { state.voiceGuidanceVolume = Int(try r.i8()) }
            else if type <= 0x03 { state.voiceGuidance = try r.u8() == 0x00 }
        case 0x5B, 0x59:
            _ = try r.u8()
            let level = Int(try r.u8())
            state.soundPressure = level == 0xFF ? nil : level
        case 0xF3, 0xF5:
            guard try r.u8() == 0x00 else { break }
            switch try r.u8() {
            case 0x00: state.wearing = .worn
            case 0x02, 0x03: state.wearing = .partially
            case 0x04: state.wearing = .notWorn
            default: state.wearing = .unknown
            }
        default:
            break
        }
    }

    func describe(_ frame: MDRFrame) -> String {
        guard let command = frame.payload.first else { return "" }
        if frame.type == .dataMdrNo2 { return V1Driver.table2Names[command] ?? String(format: "T2 0x%02X", command) }
        switch command {
        case 0x12: return "GET status"
        case 0x13: return "RET status"
        case 0x15: return "NTFY status"
        case 0x22: return "GET power status"
        case 0x23: return "RET power status"
        case 0x25: return "NTFY power status"
        case 0x26: return "GET power"
        case 0x27: return "RET power"
        case 0x28: return "SET power"
        default: return V1Driver.table1Names[command] ?? String(format: "0x%02X", command)
        }
    }
}

private extension Optional where Wrapped == ListeningMode {
    var isBackgroundMusic: Bool {
        if case .backgroundMusic? = self { return true }
        return false
    }
}
