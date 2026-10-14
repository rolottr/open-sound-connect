import SwiftUI

struct MyDeviceView: View {
    @Environment(HeadphoneController.self) private var controller
    @Binding var page: AppPage

    var body: some View {
        let caps = controller.state.capabilities
        ScrollView {
            VStack(spacing: Theme.cardSpacing) {
                HeroView()
                    .padding(.top, 12)
                    .padding(.bottom, 10)

                TwoColumnLayout(spacing: Theme.cardSpacing) {
                    VStack(spacing: Theme.cardSpacing) {
                        if caps.noise != nil { NoiseControlCard() }
                        if caps.listeningMode != nil { ListeningModeCard() }
                        QuickSettingsCard(page: $page)
                    }
                    VStack(spacing: Theme.cardSpacing) {
                        if caps.equalizer != nil { EqualizerSummaryCard(page: $page) }
                        if caps.playback { NowPlayingCard() }
                        if caps.speakToChat { SpeakToChatCard() }
                    }
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.bottom, Theme.pagePadding)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
    }
}

/// Two columns when there is room, one otherwise; cards keep their natural height.
struct AdaptiveColumns<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            TwoColumnLayout(spacing: Theme.cardSpacing) { content }
                .frame(minWidth: 760)
            VStack(spacing: Theme.cardSpacing) { content }
        }
    }
}

/// Masonry-style two-column layout: each subview goes to the currently shorter column, in order.
struct TwoColumnLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 800
        let column = (width - spacing) / 2
        var heights: [CGFloat] = [0, 0]
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: column, height: nil))
            let index = heights[0] <= heights[1] ? 0 : 1
            heights[index] += (heights[index] > 0 ? spacing : 0) + size.height
        }
        return CGSize(width: width, height: heights.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let column = (bounds.width - spacing) / 2
        var heights: [CGFloat] = [0, 0]
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: column, height: nil))
            let index = heights[0] <= heights[1] ? 0 : 1
            let x = bounds.minX + CGFloat(index) * (column + spacing)
            let y = bounds.minY + heights[index] + (heights[index] > 0 ? spacing : 0)
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: column, height: size.height))
            heights[index] = y - bounds.minY + size.height
        }
    }
}

// MARK: - Ambient sound control

struct NoiseControlCard: View {
    @Environment(HeadphoneController.self) private var controller
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("lastAmbientLevel") private var rememberedLevel = 12

    var body: some View {
        let state = controller.state
        let cap = state.capabilities.noise
        let current = state.noise
        // Pending selection comes from the controller's serialized intent, so quick successive actions build on
        // each other instead of on stale confirmed state.
        let intent = controller.noiseIntent
        Card("Ambient Sound Control", subtitle: subtitle(current)) {
            if let cap {
                ZStack(alignment: .top) {
                    ModeRail(count: cap.modes.count).frame(height: 58)
                    HStack(spacing: 0) {
                        ForEach(cap.modes) { mode in
                            ModeButton(title: mode.title, symbol: mode.symbol,
                                       selected: current?.mode == mode,
                                       pending: intent?.mode == mode && current?.mode != mode,
                                       enabled: controller.canWrite) {
                                select(mode)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(.horizontal, -4)

                if let current, current.mode == .ambient, cap.ambientRange.count > 1 {
                    let shown = intent?.mode == .ambient ? (intent ?? current) : current
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Ambient level").font(.label).foregroundStyle(Theme.secondary)
                            Spacer()
                            Text("\(shown.ambientLevel)")
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Theme.text)
                                .contentTransition(reduceMotion ? .identity : .numericText())
                        }
                        LevelSlider(value: shown.ambientLevel, range: cap.ambientRange,
                                    enabled: controller.canWrite, accessibilityName: "Ambient sound level",
                                    onDrag: { controller.dragAmbientLevel($0) },
                                    onCommit: { level in
                                        if !controller.isReplay { rememberedLevel = level }
                                        controller.requestNoise { $0.ambientLevel = level }
                                    })
                        if cap.supportsVoiceFocus {
                            Divider().overlay(Theme.hairline)
                            Toggle(isOn: Binding(
                                get: { shown.focusOnVoice },
                                set: { on in controller.requestNoise { $0.focusOnVoice = on } }
                            )) {
                                Text("Focus on Voice").font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.text)
                            }
                            .toggleStyle(AccentToggleStyle())
                            .disabled(!controller.canWrite)
                            .accessibilityLabel("Focus on Voice")
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.cardRaised.opacity(0.6)))
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .onChange(of: current) { _, value in
            if let value, value.mode == .ambient, !controller.isReplay { rememberedLevel = value.ambientLevel }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: current?.mode)
    }

    private func subtitle(_ current: NoiseControl?) -> String {
        guard let current else { return "Waiting for the headphones…" }
        switch current.mode {
        case .ambient: return "Ambient Sound · level \(current.ambientLevel)\(current.focusOnVoice ? " · Focus on Voice" : "")"
        default: return current.mode.title
        }
    }

    private func select(_ mode: NoiseMode) {
        guard let base = controller.noiseBase, base.mode != mode else { return }
        let enteringAmbient = mode == .ambient && controller.state.noise?.mode != .ambient && base.mode != .ambient
        let level = rememberedLevel
        controller.requestNoise { value in
            value.mode = mode
            // The headset does not report its stored ambient level outside ambient mode; use ours.
            if enteringAmbient { value.ambientLevel = level }
        }
    }
}

// MARK: - Listening mode (V2 models only; capability-gated)

struct ListeningModeCard: View {
    @Environment(HeadphoneController.self) private var controller

    var body: some View {
        let cap = controller.state.capabilities.listeningMode
        let current = controller.state.listeningMode
        Card("Listening Mode", subtitle: current?.title) {
            HStack(spacing: 0) {
                ModeButton(title: "Standard", symbol: "music.note", selected: current == .standard,
                           enabled: controller.canWrite) { controller.apply(.listeningMode(.standard)) }
                    .frame(maxWidth: .infinity)
                if cap?.backgroundMusic == true {
                    ModeButton(title: "Background Music", symbol: "cup.and.saucer",
                               selected: { if case .backgroundMusic = current { return true }; return false }(),
                               enabled: controller.canWrite) { controller.apply(.listeningMode(.backgroundMusic(.middle))) }
                        .frame(maxWidth: .infinity)
                }
                if cap?.cinema == true {
                    ModeButton(title: "Cinema", symbol: "film", selected: current == .cinema,
                               enabled: controller.canWrite) { controller.apply(.listeningMode(.cinema)) }
                        .frame(maxWidth: .infinity)
                }
            }
            if case .backgroundMusic(let room)? = current {
                Picker("Room", selection: Binding(get: { room }, set: { controller.apply(.listeningMode(.backgroundMusic($0))) })) {
                    ForEach(RoomSize.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }
}

// MARK: - Equalizer summary

struct EqualizerSummaryCard: View {
    @Environment(HeadphoneController.self) private var controller
    @Binding var page: AppPage

    var body: some View {
        let state = controller.state
        let cap = state.capabilities.equalizer
        let eq = state.equalizer
        Card("Equalizer", subtitle: eq.map { EqualizerPreset.displayName(for: $0.presetID) } ?? "—",
             trailing: AnyView(
                Button { page = .sound } label: {
                    Label("Edit", systemImage: "slider.vertical.3").font(.label)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.accent)
                .accessibilityLabel("Edit equalizer")
             )) {
            if let cap, let eq {
                EqualizerPreview(bands: (eq.clearBass.map { [$0] } ?? []) + eq.bands, range: cap.bandRange)
                    .frame(height: 58)
                    .padding(.vertical, 4)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(cap.presets) { preset in
                            Chip(title: preset.name, selected: eq.presetID == preset.id,
                                 pending: controller.isPending(.equalizerPreset(preset.id))) {
                                controller.apply(.equalizerPreset(preset.id))
                            }
                            .disabled(!controller.canWrite)
                        }
                    }
                    .padding(.vertical, 2)
                    .padding(.trailing, 24)
                }
                .scrollIndicators(.never)
                // Fade the trailing edge so it's clear the preset row scrolls.
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.88),
                                             .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
                if state.equalizerAvailable == false {
                    Label("The equalizer is unavailable in the current mode.", systemImage: "info.circle")
                        .font(.caption11).foregroundStyle(Theme.warning)
                }
            }
        }
    }
}

// MARK: - Speak-to-Chat

struct SpeakToChatCard: View {
    @Environment(HeadphoneController.self) private var controller

    var body: some View {
        let stc = controller.state.speakToChat
        let caps = controller.state.capabilities
        Card {
            SettingRow(symbol: "bubble.left.and.text.bubble.right", title: "Speak-to-Chat",
                       detail: nil) {
                Toggle("Speak-to-Chat", isOn: Binding(
                    get: { stc?.enabled ?? false },
                    set: { controller.apply(.speakToChat($0)) }
                ))
                .labelsHidden()
                .toggleStyle(AccentToggleStyle())
                .disabled(!controller.canWrite || stc == nil)
            }
            if caps.speakToChatOptions, let stc, let sensitivity = stc.sensitivity, let timeout = stc.timeout {
                HStack(alignment: .top, spacing: 22) {
                    CaptionedPicker(caption: "Voice detection") {
                        Picker("Voice detection sensitivity", selection: Binding(
                            get: { sensitivity },
                            set: { controller.apply(.speakToChatOptions($0, timeout)) }
                        )) {
                            ForEach(ChatSensitivity.allCases) { Text($0.title).tag($0) }
                        }
                    }
                    CaptionedPicker(caption: "Ends after") {
                        Picker("Speak-to-Chat ends after", selection: Binding(
                            get: { timeout },
                            set: { controller.apply(.speakToChatOptions(sensitivity, $0)) }
                        )) {
                            ForEach(ChatTimeout.allCases) { Text($0.title(reportedSeconds: caps.speakToChatTimeoutSeconds)).tag($0) }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 44)
                .disabled(!controller.canWrite)
            }
        }
    }
}

/// Small uppercase caption above a native menu picker.
struct CaptionedPicker<Content: View>: View {
    let caption: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(caption.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.tertiary)
                .accessibilityHidden(true)
            content
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
        }
    }
}

// MARK: - Now playing

struct NowPlayingCard: View {
    @Environment(HeadphoneController.self) private var controller

    var body: some View {
        let playing = controller.state.nowPlaying
        let system = controller.systemNowPlaying
        let track = system.item
        let isPlaying = track?.playing ?? (playing.status == .playing)
        let title = track?.title ?? playing.title
        let artist = track != nil ? track?.artist : playing.artist
        let album = track != nil ? track?.album : playing.album
        Card("Now Playing", symbol: "music.note") {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.accent.opacity(0.35), Theme.control], startPoint: .topLeading, endPoint: .bottomTrailing))
                    if let artwork = system.artwork, track != nil {
                        Image(nsImage: artwork).resizable().scaledToFill()
                    } else {
                        Image(systemName: isPlaying ? "waveform" : "music.note").foregroundStyle(Theme.text.opacity(0.85))
                    }
                }
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title ?? (isPlaying ? "Playing" : "Not playing"))
                        .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text([artist, album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ").ifEmpty(title == nil ? "Track information unavailable" : ""))
                        .font(.caption11).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    TransportButton(symbol: "backward.fill", label: "Previous track") { playback(.previous) }
                    TransportButton(symbol: isPlaying ? "pause.fill" : "play.fill", label: isPlaying ? "Pause" : "Play", prominent: true) {
                        playback(isPlaying ? .pause : .play)
                    }
                    TransportButton(symbol: "forward.fill", label: "Next track") { playback(.next) }
                }
                .disabled(controller.isReplay || (track == nil ? !controller.canWrite : system.commandPending))
            }
            if let volume = playing.volume {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    LevelSlider(value: volume, range: 0...30, enabled: controller.canWrite, accessibilityName: "Headphone volume",
                                onDrag: { _ in }, onCommit: { controller.apply(.volume($0)) })
                    Image(systemName: "speaker.wave.3.fill").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    Text("\(volume)").font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.secondary).frame(width: 20, alignment: .trailing)
                }
            }
        }
    }

    private func playback(_ command: PlaybackCommand) {
        guard !controller.isReplay else { return }
        if controller.systemNowPlaying.item != nil {
            Task {
                if await controller.systemNowPlaying.send(command) == false {
                    controller.showToast(.warning, "The player did not accept the playback command.")
                }
            }
        } else {
            controller.apply(.playback(command))
        }
    }
}

struct TransportButton: View {
    let symbol: String
    let label: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 14 : 12, weight: .semibold))
                .foregroundStyle(prominent ? Theme.onAccent : Theme.text)
                .frame(width: prominent ? 38 : 32, height: prominent ? 38 : 32)
                .background(Circle().fill(prominent ? Theme.accent : Theme.control))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Quick settings

struct QuickSettingsCard: View {
    @Environment(HeadphoneController.self) private var controller
    @Binding var page: AppPage

    var body: some View {
        let state = controller.state
        let caps = state.capabilities
        Card("Quick Settings", trailing: AnyView(
            Button { page = .settings } label: {
                Label("All Settings", systemImage: "chevron.right").labelStyle(.titleOnly).font(.label)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.accent)
        )) {
            VStack(spacing: 12) {
                if let name = caps.upscalingName {
                    SettingRow(symbol: "sparkles", title: name,
                               detail: state.upscaling?.active == true ? "Upscaling now" : nil) {
                        toggle(name, state.upscaling?.enabled) { controller.apply(.upscaling($0)) }
                    }
                }
                if caps.autoPause {
                    RowDivider()
                    SettingRow(symbol: "pause.circle", title: "Pause When Taken Off") {
                        toggle("Pause When Taken Off", state.autoPause) { controller.apply(.autoPause($0)) }
                    }
                }
                ForEach(state.generalSettings.filter { $0.isBoolean && $0.key == "TOUCH_PANEL_SETTING" }) { setting in
                    RowDivider()
                    SettingRow(symbol: setting.symbol, title: setting.title) {
                        toggle(setting.title, setting.value) { controller.apply(.generalSetting(slot: setting.slot, value: $0)) }
                    }
                }
            }
        }
    }

    private func toggle(_ title: String, _ value: Bool?, _ set: @escaping (Bool) -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { value ?? false }, set: set))
            .labelsHidden()
            .toggleStyle(AccentToggleStyle())
            .disabled(!controller.canWrite || value == nil)
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
