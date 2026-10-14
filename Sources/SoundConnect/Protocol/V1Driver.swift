import Foundation

/// MDR protocol V1 (WH-1000XM4 and older; service 96CC203E-…).
/// Protocol references: see the README credits. Where the MIT reference and Sony's own Android code disagreed
/// (SYSTEM writes), Sony's code was followed.
@MainActor
final class V1Driver: HeadphoneDriver {
    let link: MDRLink
    let state: DeviceState

    /// Support-function codes (table 1, V1).
    enum Function {
        static let battery: UInt8 = 0x11
        static let upscalingIndicator: UInt8 = 0x12
        static let codecIndicator: UInt8 = 0x13
        static let leftRightBattery: UInt8 = 0x15
        static let cradleBattery: UInt8 = 0x18
        static let powerOff: UInt8 = 0x21
        static let pairingManagement: UInt8 = 0x38
        static let voiceGuidance: UInt8 = 0x39
        static let presetEQ: UInt8 = 0x51
        static let presetEQFixed: UInt8 = 0x53
        static let noiseCancelling: UInt8 = 0x61
        static let noiseAndAmbient: UInt8 = 0x62
        static let ambientOnly: UInt8 = 0x63
        static let ncOptimizer: UInt8 = 0x81
        static let playback: UInt8 = 0xA1
        static let generalSettings: [UInt8] = [0xD1, 0xD2, 0xD3]
        static let connectionMode: UInt8 = 0xE1
        static let upscaling: UInt8 = 0xE2
        static let controlByWearing: UInt8 = 0xF3
        static let autoPowerOff: UInt8 = 0xF4
        static let speakToChat: UInt8 = 0xF5
        static let assignable: UInt8 = 0xF6
    }

    /// Read-back window for writes the headset first asks the user to confirm.
    static let confirmationTimeout: TimeInterval = 45

    private var hasTable2 = false
    private var ncInquiredType: UInt8 = 0x02
    private var eqInquiredType: UInt8 = 0x01
    private var eqStepCenter = 10
    private var stcModeOutValues: [UInt8] = []
    private var nameRefreshScheduled = false

    init(link: MDRLink, state: DeviceState) {
        self.link = link
        self.state = state
    }

    private func supports(_ function: UInt8) -> Bool { state.supportFunctions.contains(function) }

    /// Base capabilities straight from the advertised function list (refined by later capability replies).
    private func deriveBaseCapabilities() {
        hasTable2 = supports(Function.pairingManagement) || supports(Function.voiceGuidance)
        var caps = Capabilities()
        caps.codecIndicator = supports(Function.codecIndicator)
        caps.upscalingIndicator = supports(Function.upscalingIndicator)
        caps.powerOff = supports(Function.powerOff)
        caps.playback = supports(Function.playback)
        caps.ncOptimizer = supports(Function.ncOptimizer)
        caps.connectionPriority = supports(Function.connectionMode)
        caps.autoPause = supports(Function.controlByWearing)
        caps.speakToChat = supports(Function.speakToChat)
        caps.voiceGuidance = supports(Function.voiceGuidance)
        caps.pairedDevices = supports(Function.pairingManagement)
        caps.alerts = true
        if supports(Function.battery) { caps.batteryKinds.insert(.single) }
        if supports(Function.leftRightBattery) { caps.batteryKinds.insert(.leftRight) }
        if supports(Function.cradleBattery) { caps.batteryKinds.insert(.chargingCase) }
        state.capabilities = caps
        state.capabilitiesKnown = true
    }

    // MARK: Initialization

    func initialize() async throws {
        // Handshake: protocol info is mandatory; everything else degrades gracefully.
        _ = try await link.request([0x00, 0x00], expect: .init(.dataMdr, 0x01))
        _ = try await ask([0x02, 0x00], expect: .init(.dataMdr, 0x03))
        for type: UInt8 in [0x01, 0x02, 0x03] {
            _ = try await ask([0x04, type], expect: .init(.dataMdr, 0x05, type))
        }
        guard try await ask([0x06, 0x00], expect: .init(.dataMdr, 0x07)) != nil else {
            throw DriverError.malformed("the headphones did not list their functions")
        }

        // Capabilities.
        if supports(Function.presetEQ) || supports(Function.presetEQFixed) {
            eqInquiredType = supports(Function.presetEQ) ? 0x01 : 0x03
            _ = try await ask([0x50, eqInquiredType, 0x01], expect: .init(.dataMdr, 0x51, eqInquiredType))
        }
        if supports(Function.noiseAndAmbient) {
            ncInquiredType = 0x02
        } else if supports(Function.noiseCancelling) {
            ncInquiredType = 0x01
        } else if supports(Function.ambientOnly) {
            ncInquiredType = 0x03
        }
        if supports(Function.noiseAndAmbient) || supports(Function.noiseCancelling) || supports(Function.ambientOnly) {
            _ = try await ask([0x60, ncInquiredType], expect: .init(.dataMdr, 0x61, ncInquiredType))
        }
        if supports(Function.ncOptimizer) {
            _ = try await ask([0x80, 0x01], expect: .init(.dataMdr, 0x81, 0x01))
        }
        if supports(Function.playback) {
            _ = try await ask([0xA0, 0x01], expect: .init(.dataMdr, 0xA1, 0x01))
        }
        if supports(Function.connectionMode) {
            _ = try await ask([0xE0, 0x01], expect: .init(.dataMdr, 0xE1, 0x01))
        }
        if supports(Function.upscaling) {
            _ = try await ask([0xE0, 0x02], expect: .init(.dataMdr, 0xE1, 0x02))
        }
        if supports(Function.autoPowerOff) {
            _ = try await ask([0xF0, 0x04], expect: .init(.dataMdr, 0xF1, 0x04))
        }
        if supports(Function.speakToChat) {
            _ = try await ask([0xF0, 0x05], expect: .init(.dataMdr, 0xF1, 0x05))
        }
        if supports(Function.assignable) {
            _ = try await ask([0xF0, 0x06], expect: .init(.dataMdr, 0xF1, 0x06))
        }
        for slot in Function.generalSettings where supports(slot) {
            _ = try await ask([0xD0, slot, 0x01], expect: .init(.dataMdr, 0xD1, slot))
        }
        if hasTable2 && supports(Function.voiceGuidance) {
            _ = try await ask([0x40, 0x01], table: .dataMdrNo2, expect: .init(.dataMdrNo2, 0x41, 0x01))
        }

        // Ask the headset to send confirmation prompts (multipoint, connection quality) to us.
        try await link.send([0x94, 0x01, 0x00])

        try await readAllValues()
    }

    private func readAllValues() async throws {
        if supports(Function.presetEQ) || supports(Function.presetEQFixed) {
            _ = try await ask([0x52, eqInquiredType], expect: .init(.dataMdr, 0x53, eqInquiredType))
            _ = try await ask([0x56, eqInquiredType], expect: .init(.dataMdr, 0x57, eqInquiredType))
        }
        if state.capabilities.noise != nil {
            _ = try await ask([0x62, ncInquiredType], expect: .init(.dataMdr, 0x63, ncInquiredType))
            _ = try await ask([0x66, ncInquiredType], expect: .init(.dataMdr, 0x67, ncInquiredType))
        }
        if supports(Function.ncOptimizer) {
            _ = try await ask([0x82, 0x01], expect: .init(.dataMdr, 0x83, 0x01))
            _ = try await ask([0x86, 0x01], expect: .init(.dataMdr, 0x87, 0x01))
        }
        if supports(Function.connectionMode) {
            _ = try await ask([0xE6, 0x01], expect: .init(.dataMdr, 0xE7, 0x01))
        }
        if supports(Function.upscaling) {
            _ = try await ask([0xE6, 0x02], expect: .init(.dataMdr, 0xE7, 0x02))
        }
        if supports(Function.controlByWearing) {
            _ = try await ask([0xF6, 0x03], expect: .init(.dataMdr, 0xF7, 0x03))
        }
        if supports(Function.autoPowerOff) {
            _ = try await ask([0xF6, 0x04], expect: .init(.dataMdr, 0xF7, 0x04))
        }
        if supports(Function.speakToChat) {
            _ = try await ask([0xF6, 0x05], expect: .init(.dataMdr, 0xF7, 0x05))
            _ = try await ask([0xFA, 0x05], expect: .init(.dataMdr, 0xFB, 0x05))
        }
        if supports(Function.assignable) {
            _ = try await ask([0xF6, 0x06], expect: .init(.dataMdr, 0xF7, 0x06))
        }
        for slot in Function.generalSettings where supports(slot) {
            _ = try await ask([0xD6, slot], expect: .init(.dataMdr, 0xD7, slot))
        }
        if hasTable2 && supports(Function.pairingManagement) {
            _ = try await ask([0x32, 0x01], table: .dataMdrNo2, expect: .init(.dataMdrNo2, 0x33, 0x01))
            _ = try await ask([0x36, 0x01], table: .dataMdrNo2, expect: .init(.dataMdrNo2, 0x37, 0x01))
        }
        if hasTable2 && supports(Function.voiceGuidance) {
            _ = try await ask([0x46, 0x01, 0x01], table: .dataMdrNo2, expect: .init(.dataMdrNo2, 0x47, 0x01))
        }
        try await refreshStatus()
    }

    func refreshStatus() async throws {
        if supports(Function.battery) {
            _ = try await ask([0x10, 0x00], expect: .init(.dataMdr, 0x11, 0x00))
        }
        if supports(Function.leftRightBattery) {
            _ = try await ask([0x10, 0x01], expect: .init(.dataMdr, 0x11, 0x01))
        }
        if supports(Function.cradleBattery) {
            _ = try await ask([0x10, 0x02], expect: .init(.dataMdr, 0x11, 0x02))
        }
        if supports(Function.codecIndicator) {
            _ = try await ask([0x18, 0x00], expect: .init(.dataMdr, 0x19))
        }
        if supports(Function.upscalingIndicator) {
            _ = try await ask([0x14, 0x00], expect: .init(.dataMdr, 0x15))
        }
        if supports(Function.playback) {
            try await refreshPlayback()
        }
        if hasTable2 && supports(Function.pairingManagement) {
            _ = try await ask([0x36, 0x01], table: .dataMdrNo2, expect: .init(.dataMdrNo2, 0x37, 0x01))
        }
    }

    private func refreshPlayback() async throws {
        _ = try await ask([0xA2, 0x01], expect: .init(.dataMdr, 0xA3, 0x01))
        _ = try await ask([0xA6, 0x01, 0x20], expect: .init(.dataMdr, 0xA7, 0x01, detail: 0x20))
        for detail: UInt8 in [0x00, 0x01, 0x02] {
            _ = try await ask([0xA6, 0x01, detail], expect: .init(.dataMdr, 0xA7, 0x01, detail: detail))
        }
    }

    // MARK: Writes

    func apply(_ change: DeviceChange) async throws {
        switch change {
        case .noise(let value, let dragging):
            guard let cap = state.capabilities.noise else { throw DriverError.unsupported("Ambient sound control") }
            try await link.send(noisePayload(value, capability: cap, dragging: dragging))
            if !dragging {
                try await readBack([0x66, ncInquiredType], expect: .init(.dataMdr, 0x67, ncInquiredType))
            }

        case .equalizerPreset(let id):
            guard state.capabilities.equalizer != nil else { throw DriverError.unsupported("Equalizer") }
            try await link.send([0x58, eqInquiredType, id, 0x00])
            try await readBack([0x56, eqInquiredType], expect: .init(.dataMdr, 0x57, eqInquiredType))

        case .equalizerBands(let bands, let clearBass):
            guard let cap = state.capabilities.equalizer else { throw DriverError.unsupported("Equalizer") }
            guard bands.count == cap.bandCount else { throw DriverError.malformed("band count") }
            // Sound Connect sends band steps against "unspecified" (0xFF): they apply to the active
            // editable preset (Manual / Custom). Never combine a preset change and steps in one frame.
            var steps: [UInt8] = []
            if cap.hasClearBass { steps.append(UInt8(clamping: (clearBass ?? state.equalizer?.clearBass ?? 0) + eqStepCenter)) }
            steps += bands.map { UInt8(clamping: $0 + eqStepCenter) }
            try await link.send([0x58, eqInquiredType, 0xFF, UInt8(steps.count)] + steps)
            try await readBack([0x56, eqInquiredType], expect: .init(.dataMdr, 0x57, eqInquiredType))

        case .upscaling(let on):
            guard supports(Function.upscaling) else { throw DriverError.unsupported("DSEE") }
            try await link.send([0xE8, 0x02, 0x00, on ? 0x01 : 0x00])
            try await readBack([0xE6, 0x02], expect: .init(.dataMdr, 0xE7, 0x02))

        case .connectionPriority(let value):
            guard supports(Function.connectionMode) else { throw DriverError.unsupported("Connection quality") }
            try await link.send([0xE8, 0x01, 0x00, value.rawValue])
            // The headset asks the user to confirm (alert 0x01) before applying; allow time to answer.
            try await readBack([0xE6, 0x01], expect: .init(.dataMdr, 0xE7, 0x01), timeout: Self.confirmationTimeout)

        case .speakToChat(let on):
            guard supports(Function.speakToChat) else { throw DriverError.unsupported("Speak-to-Chat") }
            // Sony ym0/d: [F8, 05, parameterType MODE_ON_OFF(01), value].
            try await link.send([0xF8, 0x05, 0x01, on ? 0x01 : 0x00])
            try await readBack([0xF6, 0x05], expect: .init(.dataMdr, 0xF7, 0x05))

        case .speakToChatOptions(let sensitivity, let timeout):
            guard supports(Function.speakToChat) else { throw DriverError.unsupported("Speak-to-Chat") }
            let voiceFocus: UInt8 = (state.speakToChat?.voiceFocus ?? false) ? 0x01 : 0x00
            try await link.send([0xFC, 0x05, 0x00, sensitivity.rawValue, voiceFocus, timeout.rawValue])
            try await readBack([0xFA, 0x05], expect: .init(.dataMdr, 0xFB, 0x05))

        case .autoPowerOff(let id):
            guard supports(Function.autoPowerOff) else { throw DriverError.unsupported("Automatic power off") }
            // Sony tm0/r3 + vm0/g: SYSTEM_SET_PARAM [F8, 04, ACTIVE_AND_SELECTIME_ID(01), active, selected].
            try await link.send([0xF8, 0x04, 0x01, id, id])
            try await readBack([0xF6, 0x04], expect: .init(.dataMdr, 0xF7, 0x04))

        case .autoPause(let on):
            guard supports(Function.controlByWearing) else { throw DriverError.unsupported("Pause when taken off") }
            // Sony KMP V1ControlByWearingRepository: [F8, 03, ON_OFF(00), value].
            try await link.send([0xF8, 0x03, 0x00, on ? 0x01 : 0x00])
            try await readBack([0xF6, 0x03], expect: .init(.dataMdr, 0xF7, 0x03))

        case .assignable(let presets):
            guard supports(Function.assignable) else { throw DriverError.unsupported("Button assignment") }
            try await link.send([0xF8, 0x06, UInt8(presets.count)] + presets)
            try await readBack([0xF6, 0x06], expect: .init(.dataMdr, 0xF7, 0x06), timeout: Self.confirmationTimeout)

        case .generalSetting(let slot, let value):
            guard supports(slot), let setting = state.setting(slot: slot), setting.isBoolean else {
                throw DriverError.unsupported("This setting")
            }
            try await link.send([0xD8, slot, 0x01, value ? 0x01 : 0x00])
            // Multipoint asks for confirmation (alerts 0x06/0x07) before the headset restarts its link.
            try await readBack([0xD6, slot], expect: .init(.dataMdr, 0xD7, slot),
                               timeout: setting.key.contains("MULTIPOINT") ? Self.confirmationTimeout : 4)

        case .voiceGuidance(let on):
            guard hasTable2, supports(Function.voiceGuidance) else { throw DriverError.unsupported("Voice guidance") }
            try await link.send([0x48, 0x01, 0x01, on ? 0x01 : 0x00], table: .dataMdrNo2)
            try await readBack([0x46, 0x01, 0x01], table: .dataMdrNo2, expect: .init(.dataMdrNo2, 0x47, 0x01))

        case .pairingMode(let on):
            guard hasTable2, supports(Function.pairingManagement) else { throw DriverError.unsupported("Pairing mode") }
            try await link.send([0x34, 0x01, on ? 0x01 : 0x00, 0x00], table: .dataMdrNo2)
            try await readBack([0x32, 0x01], table: .dataMdrNo2, expect: .init(.dataMdrNo2, 0x33, 0x01))

        case .playback(let command):
            guard supports(Function.playback) else { throw DriverError.unsupported("Playback control") }
            try await link.send([0xA4, 0x01, 0x00, command.rawValue])
            try await readBack([0xA2, 0x01], expect: .init(.dataMdr, 0xA3, 0x01))

        case .volume(let value):
            guard supports(Function.playback) else { throw DriverError.unsupported("Volume") }
            try await link.send([0xA8, 0x01, 0x20, UInt8(clamping: max(0, min(30, value)))])
            try await readVolumeBack(value, payload: [0xA6, 0x01, 0x20], expect: .init(.dataMdr, 0xA7, 0x01, detail: 0x20))

        case .listeningMode, .voiceGuidanceVolume, .ncAmbButton, .headGesture:
            throw DriverError.unsupported(change.label)
        }
    }

    /// Sound Connect v30/c: slider 0 = NC (dual), 1 = wind (NC single), 2… = ambient level n-1 with NC off.
    /// The NC/ASM setting-type bytes echo the headset's own capability reply.
    private func noisePayload(_ value: NoiseControl, capability: NoiseControlCapability, dragging: Bool) -> [UInt8] {
        let ncType = state.v1NcSettingType
        let asmType = state.v1AsmSettingType
        let asmID: UInt8 = value.focusOnVoice && capability.supportsVoiceFocus ? 0x01 : 0x00
        let level = UInt8(clamping: max(capability.ambientRange.lowerBound, min(capability.ambientRange.upperBound, value.ambientLevel)))
        let wasOff = state.noise?.mode == .off
        let effect: UInt8
        switch (value.mode, dragging) {
        case (.off, _): effect = 0x00
        case (_, true): effect = 0x10            // ADJUSTMENT_IN_PROGRESS
        case (_, false) where wasOff: effect = 0x01 // ON
        default: effect = 0x11                     // ADJUSTMENT_COMPLETION
        }
        let lastOn = value.mode == .off ? (state.noise.map { NoiseMode.lastActive($0) } ?? .noiseCancelling) : value.mode
        switch lastOn {
        case .noiseCancelling, .off:
            return [0x68, ncInquiredType, effect, ncType, 0x02, asmType, asmID, 0x00]
        case .windReduction:
            return [0x68, ncInquiredType, effect, ncType, 0x01, asmType, asmID, 0x00]
        case .ambient:
            return [0x68, ncInquiredType, effect, ncType, 0x00, asmType, asmID, level]
        }
    }

    func answerAlert(_ alert: DeviceAlert, accept: Bool) async throws {
        try await link.send([0x98, 0x01, alert.messageType, accept ? 0x01 : 0x00])
    }

    func startNoiseOptimizer() async throws {
        guard supports(Function.ncOptimizer) else { throw DriverError.unsupported("NC Optimizer") }
        try await link.send([0x84, 0x01, 0x00, 0x01])
    }

    func cancelNoiseOptimizer() async throws {
        guard supports(Function.ncOptimizer) else { throw DriverError.unsupported("NC Optimizer") }
        try await link.send([0x84, 0x01, 0x00, 0x00])
    }

    func powerOff() async throws {
        guard supports(Function.powerOff) else { throw DriverError.unsupported("Power off") }
        try await link.send([0x22, 0x00, 0x01])
    }

    // MARK: Inbound

    func handle(_ frame: MDRFrame) {
        let p = frame.payload
        guard let command = p.first else { return }
        do {
            switch frame.type {
            case .dataMdr?: try handleTable1(command, p)
            case .dataMdrNo2?: try handleTable2(command, p)
            default: break
            }
        } catch {
            link.note(String(format: "Could not parse reply %02X: %@", command, p.hex))
        }
    }

    private func handleTable1(_ command: UInt8, _ p: [UInt8]) throws {
        var r = ByteReader(p, offset: 1)
        switch command {
        case 0x01: // protocol info
            _ = try r.u8()
            state.protocolVersion = try r.u16()
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
            state.supportFunctions = try r.take(count)
            deriveBaseCapabilities()
        case 0x11, 0x13:
            switch try r.u8() {
            case 0x00:
                state.battery.main = BatteryReading(level: Int(try r.u8()), charging: Self.charging(try r.u8()))
            case 0x01:
                state.battery.left = BatteryReading(level: Int(try r.u8()), charging: Self.charging(try r.u8()))
                state.battery.right = BatteryReading(level: Int(try r.u8()), charging: Self.charging(try r.u8()))
            case 0x02:
                state.battery.chargingCase = BatteryReading(level: Int(try r.u8()), charging: Self.charging(try r.u8()))
            default: break
            }
        case 0x15, 0x17:
            _ = try r.u8(); _ = try r.u8()
            let status = try r.u8()
            var upscaling = state.upscaling ?? UpscalingState(enabled: status != 0x00, active: nil)
            upscaling.active = status == 0x01
            state.upscaling = upscaling
        case 0x19, 0x1B:
            _ = try r.u8()
            state.codec = AudioCodec(rawValue: try r.u8()) ?? .other
        case 0x51:
            try parseEqualizerCapability(&r)
        case 0x53, 0x55:
            _ = try r.u8()
            state.equalizerAvailable = try r.u8() == 0x00
        case 0x57, 0x59:
            _ = try r.u8()
            let preset = try r.u8()
            let count = Int(try r.u8())
            let raw = try r.take(count).map { Int($0) - eqStepCenter }
            var eq = state.equalizer ?? EqualizerState(presetID: preset, bands: [], clearBass: nil)
            eq.presetID = preset
            if count == 6 {
                eq.clearBass = raw[0]
                eq.bands = Array(raw[1...])
            } else if count > 0 {
                eq.bands = raw
            }
            state.equalizer = eq
        case 0x61:
            try parseNoiseCapability(&r)
        case 0x63, 0x65:
            break // NC/ASM enabled status; the headset rejects writes itself when disabled.
        case 0x67, 0x69:
            try parseNoise(&r)
        case 0x81:
            state.capabilities.ncOptimizer = true
        case 0x83, 0x85:
            _ = try r.u8(); _ = try r.u8()
            switch try r.u8() {
            case 0x00: state.optimizer = state.optimizer == .running ? .finished : .idle
            case 0x11: state.optimizer = .finished
            default: state.optimizer = .running
            }
        case 0x87, 0x89:
            _ = try r.u8(); _ = try r.u8(); _ = try r.u8(); _ = try r.u8()
            let barometric = Int(try r.u8())
            state.optimizerMeasuredPressure = barometric == 0 ? nil : barometric
        case 0xA1:
            state.capabilities.playback = true
        case 0xA3, 0xA5:
            _ = try r.u8(); _ = try r.u8()
            state.nowPlaying.status = PlaybackStatus(rawValue: try r.u8())
        case 0xA7, 0xA9:
            _ = try r.u8()
            let detail = try r.u8()
            if detail == 0x20 {
                state.nowPlaying.volume = Int(try r.u8())
            } else if command == 0xA9 {
                scheduleNameRefresh() // V1 name notifications carry no text.
            } else {
                let status = try r.u8()
                let text = try r.string()
                let value = status == 0x02 && !text.isEmpty ? text : nil
                switch detail {
                case 0x00: state.nowPlaying.title = value
                case 0x01: state.nowPlaying.album = value
                case 0x02: state.nowPlaying.artist = value
                default: break
                }
            }
        case 0xD1:
            let slot = try r.u8()
            _ = try r.u8() // string format
            let key = try r.string()
            let summary = try r.string()
            let settingType = try r.u8()
            var setting = state.setting(slot: slot) ?? GeneralSetting(slot: slot, key: key, summaryKey: summary, isBoolean: false, value: nil)
            setting.key = key
            setting.summaryKey = summary
            setting.isBoolean = settingType == 0x01
            state.upsertSetting(setting)
            if !state.capabilities.generalSettingSlots.contains(slot) { state.capabilities.generalSettingSlots.append(slot) }
        case 0xD7, 0xD9:
            let slot = try r.u8()
            let settingType = try r.u8()
            let value = try r.u8()
            var setting = state.setting(slot: slot) ?? GeneralSetting(slot: slot, key: "", summaryKey: "", isBoolean: settingType == 0x01, value: nil)
            if settingType == 0x01 { setting.value = value == 0x01 }
            state.upsertSetting(setting)
        case 0xE1:
            switch try r.u8() {
            case 0x01: state.capabilities.connectionPriority = true
            case 0x02:
                let type = try r.u8()
                state.capabilities.upscalingName = Self.upscalingName(type)
            default: break
            }
        case 0xE7, 0xE9:
            let type = try r.u8()
            _ = try r.u8()
            let value = try r.u8()
            if type == 0x01 {
                state.connectionPriority = ConnectionPriority(rawValue: value)
            } else if type == 0x02 {
                var upscaling = state.upscaling ?? UpscalingState(enabled: false, active: nil)
                upscaling.enabled = value == 0x01
                if !upscaling.enabled { upscaling.active = false }
                state.upscaling = upscaling
            }
        case 0xF1:
            try parseSystemCapability(&r)
        case 0xF7, 0xF9:
            try parseSystemParam(&r)
        case 0xFB, 0xFD:
            guard try r.u8() == 0x05 else { break }
            _ = try r.u8()
            var stc = state.speakToChat ?? SpeakToChat(enabled: false)
            stc.sensitivity = ChatSensitivity(rawValue: try r.u8())
            stc.voiceFocus = try r.u8() == 0x01
            stc.timeout = ChatTimeout(rawValue: try r.u8())
            state.speakToChat = stc
        case 0x99:
            _ = try r.u8()
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
        case 0x33, 0x35:
            _ = try r.u8()
            state.pairingMode = try r.u8() == 0x01
        case 0x37, 0x39:
            _ = try r.u8()
            let count = Int(try r.u8())
            var devices: [PairedDevice] = []
            for _ in 0..<count {
                let address = String(decoding: try r.take(17), as: UTF8.self)
                let connected = try r.u8()
                let name = try r.string()
                devices.append(PairedDevice(address: address, name: name, connected: connected != 0, isPlaybackSource: false))
            }
            if let playback = try? r.u8(), playback >= 1, Int(playback) <= devices.count {
                devices[Int(playback) - 1].isPlaybackSource = true
            }
            state.pairedDevices = devices
        case 0x41:
            state.capabilities.voiceGuidance = true
        case 0x47, 0x49:
            _ = try r.u8()
            if try r.u8() == 0x01 { state.voiceGuidance = try r.u8() == 0x01 }
        default:
            break
        }
    }

    private func parseEqualizerCapability(_ r: inout ByteReader) throws {
        _ = try r.u8()
        let bandCount = Int(try r.u8())
        let steps = Int(try r.u8())
        let presetCount = Int(try r.u8())
        var presets: [EqualizerPreset] = []
        for _ in 0..<presetCount {
            let id = try r.u8()
            let name = try r.string()
            presets.append(EqualizerPreset(id: id, name: name.isEmpty ? EqualizerPreset.displayName(for: id) : name))
        }
        eqStepCenter = max(1, (steps - 1) / 2)
        let hasClearBass = bandCount == 6
        state.capabilities.equalizer = EqualizerCapability(
            presets: presets,
            bandCount: hasClearBass ? 5 : bandCount,
            bandRange: -eqStepCenter...eqStepCenter,
            hasClearBass: hasClearBass
        )
    }

    private func parseNoiseCapability(_ r: inout ByteReader) throws {
        let type = try r.u8()
        var modes: [NoiseMode] = []
        var range = 1...20
        var voice = false
        if type == 0x02 {
            let ncType = try r.u8()
            _ = try r.u8()
            let asmType = try r.u8()
            let count = Int(try r.u8())
            var maxLevel = 0
            for _ in 0..<count {
                let id = try r.u8()
                let levelSteps = Int(try r.u8())
                maxLevel = max(maxLevel, levelSteps)
                if id == 0x01 { voice = true }
            }
            state.v1NcSettingType = ncType
            state.v1AsmSettingType = asmType
            modes = [.noiseCancelling]
            if ncType == 0x02 { modes.append(.windReduction) }
            modes += [.ambient, .off]
            if asmType == 0x01 && maxLevel > 0 { range = 1...maxLevel } else { range = 1...1 }
        } else if type == 0x01 {
            modes = [.noiseCancelling, .off]
            range = 1...1
        } else if type == 0x03 {
            modes = [.ambient, .off]
        }
        state.capabilities.noise = NoiseControlCapability(modes: modes, ambientRange: range,
                                                          supportsVoiceFocus: voice, supportsAutoAmbient: false)
    }

    private func parseNoise(_ r: inout ByteReader) throws {
        let type = try r.u8()
        guard type == 0x02 else {
            // NC-only / ASM-only variants: [type, effect, …]
            let effect = try r.u8()
            let mode: NoiseMode = effect == 0x00 ? .off : (type == 0x01 ? .noiseCancelling : .ambient)
            state.noise = NoiseControl(mode: mode, ambientLevel: state.noise?.ambientLevel ?? 1, focusOnVoice: false)
            return
        }
        let effect = try r.u8()
        _ = try r.u8()
        let ncValue = try r.u8()
        _ = try r.u8()
        let asmID = try r.u8()
        let asmValue = Int(try r.u8())
        let previous = state.noise
        let level = asmValue > 0 ? asmValue : (previous?.ambientLevel ?? state.capabilities.noise?.ambientRange.upperBound ?? 20)
        let configured: NoiseMode = switch ncValue {
        case 0x02: .noiseCancelling
        case 0x01: .windReduction
        default: .ambient
        }
        var value = NoiseControl(mode: effect == 0x00 ? .off : configured, ambientLevel: level, focusOnVoice: asmID == 0x01)
        value.lastActiveMode = configured
        state.noise = value
    }

    private func parseSystemCapability(_ r: inout ByteReader) throws {
        switch try r.u8() {
        case 0x03:
            state.capabilities.autoPause = true
        case 0x04:
            let count = Int(try r.u8())
            state.capabilities.autoPowerOffOptions = try r.take(count).map { AutoPowerOffOption(id: $0) }
        case 0x05:
            state.capabilities.speakToChat = true
            // settingType, previewType, detailType, sensitivityType, voiceFocusType, modeOutType, then the
            // mode-out timer seconds per ModeOutTime index. WH-1000XM4 fw 2.6.0 sends them without a count
            // prefix: F1 05 00 01 00 00 00 00 | 0F 1E 3C 00 (15 s, 30 s, 60 s, never).
            _ = try r.take(6)
            var values = try r.take(r.remaining)
            if let first = values.first, Int(first) == values.count - 1 { values.removeFirst() }
            stcModeOutValues = values
            state.capabilities.speakToChatOptions = true
            state.capabilities.speakToChatTimeoutSeconds = values
        case 0x06:
            let keyCount = Int(try r.u8())
            var keys: [AssignableKey] = []
            for index in 0..<keyCount {
                let key = try r.u8()
                let keyType = try r.u8()
                let defaultPreset = try r.u8()
                let presetCount = Int(try r.u8())
                var options: [UInt8] = []
                for _ in 0..<presetCount {
                    options.append(try r.u8())
                    let actions = Int(try r.u8())
                    try r.skip(actions * 2)
                }
                keys.append(AssignableKey(index: index, key: key, keyType: keyType, defaultPreset: defaultPreset, options: options))
            }
            state.capabilities.assignableKeys = keys
        default:
            break
        }
    }

    private func parseSystemParam(_ r: inout ByteReader) throws {
        switch try r.u8() {
        case 0x03:
            _ = try r.u8()
            state.autoPause = try r.u8() == 0x01
        case 0x04:
            _ = try r.u8()
            state.autoPowerOff = try r.u8()
        case 0x05:
            _ = try r.u8()
            var stc = state.speakToChat ?? SpeakToChat(enabled: false)
            stc.enabled = try r.u8() == 0x01
            state.speakToChat = stc
        case 0x06:
            let count = Int(try r.u8())
            state.assignablePresets = try r.take(count)
        default:
            break
        }
    }

    private func scheduleNameRefresh() {
        guard !nameRefreshScheduled else { return }
        nameRefreshScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !self.link.isClosed else { return }
            self.nameRefreshScheduled = false
            try? await self.link.exclusive {
                for detail: UInt8 in [0x00, 0x01, 0x02] {
                    _ = try await self.ask([0xA6, 0x01, detail], expect: .init(.dataMdr, 0xA7, 0x01, detail: detail))
                }
            }
        }
    }

    static func charging(_ raw: UInt8) -> ChargingState {
        switch raw {
        case 0x00: .notCharging
        case 0x01: .charging
        default: .unknown
        }
    }

    static func upscalingName(_ type: UInt8) -> String {
        switch type {
        case 0x00: "DSEE HX"
        case 0x01: "DSEE"
        case 0x02: "DSEE Extreme"
        case 0x03: "DSEE Ultimate"
        default: "DSEE"
        }
    }

    // MARK: Traffic descriptions

    func describe(_ frame: MDRFrame) -> String {
        guard let command = frame.payload.first else { return "" }
        if frame.type == .dataMdrNo2 {
            return Self.table2Names[command] ?? String(format: "T2 0x%02X", command)
        }
        return Self.table1Names[command] ?? String(format: "0x%02X", command)
    }

    static let table1Names: [UInt8: String] = [
        0x00: "GET protocol", 0x01: "RET protocol", 0x02: "GET capability", 0x03: "RET capability",
        0x04: "GET device info", 0x05: "RET device info", 0x06: "GET functions", 0x07: "RET functions",
        0x10: "GET battery", 0x11: "RET battery", 0x13: "NTFY battery", 0x14: "GET DSEE effect",
        0x15: "RET DSEE effect", 0x17: "NTFY DSEE effect", 0x18: "GET codec", 0x19: "RET codec", 0x1B: "NTFY codec",
        0x22: "SET power off", 0x50: "GET EQ capability", 0x51: "RET EQ capability", 0x52: "GET EQ status",
        0x53: "RET EQ status", 0x55: "NTFY EQ status", 0x56: "GET EQ", 0x57: "RET EQ", 0x58: "SET EQ", 0x59: "NTFY EQ",
        0x60: "GET NC/ASM capability", 0x61: "RET NC/ASM capability", 0x62: "GET NC/ASM status", 0x63: "RET NC/ASM status",
        0x65: "NTFY NC/ASM status", 0x66: "GET NC/ASM", 0x67: "RET NC/ASM", 0x68: "SET NC/ASM", 0x69: "NTFY NC/ASM",
        0x80: "GET optimizer capability", 0x81: "RET optimizer capability", 0x82: "GET optimizer status",
        0x83: "RET optimizer status", 0x84: "SET optimizer", 0x85: "NTFY optimizer status", 0x86: "GET optimizer",
        0x87: "RET optimizer", 0x89: "NTFY optimizer", 0x94: "SET alerts", 0x98: "SET alert answer", 0x99: "NTFY alert",
        0xA0: "GET playback capability", 0xA1: "RET playback capability", 0xA2: "GET playback", 0xA3: "RET playback",
        0xA4: "SET playback", 0xA5: "NTFY playback", 0xA6: "GET playback param", 0xA7: "RET playback param",
        0xA8: "SET volume", 0xA9: "NTFY playback param", 0xD0: "GET setting capability", 0xD1: "RET setting capability",
        0xD6: "GET setting", 0xD7: "RET setting", 0xD8: "SET setting", 0xD9: "NTFY setting",
        0xE0: "GET audio capability", 0xE1: "RET audio capability", 0xE6: "GET audio", 0xE7: "RET audio",
        0xE8: "SET audio", 0xE9: "NTFY audio", 0xF0: "GET system capability", 0xF1: "RET system capability",
        0xF6: "GET system", 0xF7: "RET system", 0xF8: "SET system", 0xF9: "NTFY system",
        0xFA: "GET system ext", 0xFB: "RET system ext", 0xFC: "SET system ext", 0xFD: "NTFY system ext",
    ]

    static let table2Names: [UInt8: String] = [
        0x30: "GET pairing capability", 0x31: "RET pairing capability", 0x32: "GET pairing status",
        0x33: "RET pairing status", 0x34: "SET pairing mode", 0x35: "NTFY pairing status", 0x36: "GET devices",
        0x37: "RET devices", 0x39: "NTFY devices", 0x40: "GET voice guidance capability",
        0x41: "RET voice guidance capability", 0x46: "GET voice guidance", 0x47: "RET voice guidance",
        0x48: "SET voice guidance", 0x49: "NTFY voice guidance",
    ]
}

private extension NoiseMode {
    static func lastActive(_ value: NoiseControl) -> NoiseMode {
        value.mode == .off ? value.lastActiveMode : value.mode
    }
}
