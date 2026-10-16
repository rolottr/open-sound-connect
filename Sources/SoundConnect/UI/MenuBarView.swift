import SwiftUI

/// Menu bar quick controls. Everything here goes through the same verified write path as the main window.
struct MenuBarView: View {
    @Environment(HeadphoneController.self) private var controller
    @Environment(SceneStore.self) private var scenes
    @Environment(Navigation.self) private var navigation
    @Environment(UpdateChecker.self) private var updates
    @Environment(\.openWindow) private var openWindow
    @AppStorage("lastAmbientLevel") private var rememberedLevel = 12

    var body: some View {
        let state = controller.state
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ProductImage(modelName: state.modelName ?? controller.selectedName, colorCode: state.colorCode, glow: false)
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.modelName ?? controller.selectedName)
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    if controller.isConnected {
                        HStack(spacing: 8) {
                            BatteryLabel(battery: state.battery)
                            if let codec = state.codec, codec != .unsettled { Badge(text: codec.title, tint: Theme.secondary) }
                        }
                    } else {
                        Text(statusText).font(.caption11).foregroundStyle(Theme.secondary)
                    }
                }
                Spacer()
            }

            if controller.isReplay {
                ReplayNotice(compact: true)
            }

            if controller.isConnected {
                if let cap = state.capabilities.noise, let noise = state.noise {
                    HStack(spacing: 0) {
                        ForEach(cap.modes) { mode in
                            CompactModeButton(mode: mode, selected: noise.mode == mode,
                                              pending: controller.noiseIntent?.mode == mode && noise.mode != mode) {
                                let level = rememberedLevel
                                let entering = mode == .ambient && noise.mode != .ambient
                                controller.requestNoise { value in
                                    value.mode = mode
                                    if entering { value.ambientLevel = level }
                                }
                            }
                            .disabled(!controller.canWrite)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    if noise.mode == .ambient, cap.ambientRange.count > 1 {
                        HStack(spacing: 10) {
                            Image(systemName: "ear").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                            LevelSlider(value: noise.ambientLevel, range: cap.ambientRange, enabled: controller.canWrite,
                                        accessibilityName: "Ambient sound level",
                                        onDrag: { controller.dragAmbientLevel($0) },
                                        onCommit: { level in controller.requestNoise { $0.ambientLevel = level } })
                            Text("\(noise.ambientLevel)").font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Theme.secondary).frame(width: 18)
                        }
                        if cap.supportsVoiceFocus {
                            MenuToggleRow(title: "Focus on Voice", symbol: "person.wave.2",
                                          isOn: Binding(get: { noise.focusOnVoice }, set: { on in
                                              controller.requestNoise { $0.focusOnVoice = on }
                                          }))
                                .disabled(!controller.canWrite)
                        }
                    }
                }

                Divider().overlay(Theme.hairline)

                VStack(spacing: 10) {
                    if let cap = state.capabilities.equalizer, let eq = state.equalizer {
                        HStack {
                            Image(systemName: "slider.vertical.3").font(.system(size: 12)).foregroundStyle(Theme.secondary).frame(width: 18)
                            Text("Equalizer").font(.system(size: 12.5)).foregroundStyle(Theme.text)
                            Spacer()
                            Picker("Equalizer", selection: Binding(get: { eq.presetID }, set: { controller.apply(.equalizerPreset($0)) })) {
                                ForEach(cap.presets) { Text($0.name).tag($0.id) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            .disabled(!controller.canWrite)
                        }
                    }
                    if let name = state.capabilities.upscalingName {
                        MenuToggleRow(title: name, symbol: "sparkles",
                                      isOn: Binding(get: { state.upscaling?.enabled ?? false }, set: { controller.apply(.upscaling($0)) }))
                            .disabled(!controller.canWrite)
                    }
                    if state.capabilities.speakToChat {
                        MenuToggleRow(title: "Speak-to-Chat", symbol: "bubble.left.and.text.bubble.right",
                                      isOn: Binding(get: { state.speakToChat?.enabled ?? false }, set: { controller.apply(.speakToChat($0)) }))
                            .disabled(!controller.canWrite)
                    }
                }
                .foregroundStyle(Theme.text)

                if !scenes.scenes.isEmpty {
                    Divider().overlay(Theme.hairline)
                    Text("SCENES").font(.system(size: 9.5, weight: .semibold)).tracking(0.8).foregroundStyle(Theme.tertiary)
                    FlowLayout(spacing: 6) {
                        ForEach(scenes.scenes) { scene in
                            let applied = scenes.isApplied(scene)
                            Button {
                                Task { await scenes.apply(scene.id) }
                            } label: {
                                HStack(spacing: 5) {
                                    if scenes.runningSceneID == scene.id { ProgressView().controlSize(.mini) }
                                    else if applied { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.secondary) }
                                    else { Image(systemName: scene.symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(scene.tint.color) }
                                    Text(scene.name).font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(applied ? Theme.secondary : Theme.text)
                                }
                                .padding(.horizontal, 10).frame(height: 26)
                                .background(Capsule().fill(Theme.control))
                            }
                            .buttonStyle(.plain)
                            .disabled(!scenes.canApply(scene))
                            .accessibilityLabel(applied ? "Scene \(scene.name), applied" : "Apply scene \(scene.name)")
                        }
                    }
                }
            } else if let address = controller.selectedAddress, !controller.phase.isBusy,
                      controller.bluetooth.status == .ready {
                Button {
                    controller.connect(address: address, initiate: true)
                } label: {
                    Label("Connect", systemImage: "headphones").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(Theme.onAccent)
            }

            Divider().overlay(Theme.hairline)
            if let release = updates.available {
                Button {
                    updates.download(release)
                } label: {
                    Label("Download Sound Connect \(release.version)", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.accent)
            }
            HStack {
                Button("Open Sound Connect") {
                    // The app drops its Dock icon while only the menu bar item is open; bring it back with the window.
                    NSApp.setActivationPolicy(.regular)
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondary)
        }
        .padding(16)
        .frame(width: 320)
        // Let the menu bar host shrink with the controls when the headset disconnects.
        .fixedSize(horizontal: false, vertical: true)
        // The MenuBarExtra host window adds insets above and below the content and paints its own translucent
        // material there; give the window container itself the opaque charcoal so the whole panel is one surface.
        .background(Theme.canvasTop.ignoresSafeArea())
        .containerBackground(Theme.canvasTop, for: .window)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }

    private var statusText: String {
        switch controller.phase {
        case .connecting, .initializing: "Connecting…"
        case .reconnecting: "Reconnecting…"
        case .waiting: "Not connected"
        case .failed(_, let message): message
        case .permissionNeeded, .permissionDenied: "Needs Bluetooth access"
        case .bluetoothOff: "Bluetooth is off"
        case .noHeadphones: "No Sony headphones paired"
        default: ""
        }
    }
}

struct CompactModeButton: View {
    let mode: NoiseMode
    let selected: Bool
    var pending = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    Circle().fill(selected ? Theme.accent : Theme.control)
                    if pending {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: mode.symbol)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(selected ? Theme.onAccent : Theme.text)
                    }
                }
                .frame(width: 40, height: 40)
                Text(mode.title).font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.text : Theme.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(width: 72, height: 26, alignment: .top)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// A full-size headphone glyph; the circled variants make the headphones too small in the menu bar.
struct MenuBarIcon: View {
    @Environment(HeadphoneController.self) private var controller

    var body: some View {
        Image(systemName: "headphones")
            .font(.system(size: 18, weight: .medium))
            .imageScale(.large)
            .opacity(controller.isConnected ? 1 : 0.6)
            .accessibilityLabel(controller.isConnected ? "Sound Connect, \(controller.state.noise?.mode.title ?? "connected")" : "Sound Connect, not connected")
    }
}

/// Label on the left, switch aligned on the right (menu bar panel rows).
struct MenuToggleRow: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Theme.secondary).frame(width: 18)
            Text(title).font(.system(size: 12.5)).foregroundStyle(Theme.text)
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(AccentToggleStyle()).controlSize(.small)
        }
    }
}
