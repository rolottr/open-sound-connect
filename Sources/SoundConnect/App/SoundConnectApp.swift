import AppKit
import SwiftUI

struct SoundConnectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("showMenuBarExtra") private var showMenuBar = true

    var body: some Scene {
        Window("Sound Connect", id: "main") {
            RootView()
                .environment(appDelegate.controller)
                .environment(appDelegate.scenes)
                .environment(appDelegate.curves)
                .environment(appDelegate.navigation)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1160, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            SoundConnectCommands(controller: appDelegate.controller, scenes: appDelegate.scenes, navigation: appDelegate.navigation)
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarView()
                .background(MenuBarWindowSizing())
                .environment(appDelegate.controller)
                .environment(appDelegate.scenes)
                .environment(appDelegate.navigation)
        } label: {
            MenuBarIcon().environment(appDelegate.controller)
        }
        .menuBarExtraStyle(.window)

        Settings {
            AppPreferencesCard()
                .padding(20)
                .frame(width: 460)
                .background(Theme.canvasTop)
                .preferredColorScheme(.dark)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = HeadphoneController()
    let navigation = Navigation()
    let curves = CurveLibrary()
    lazy var scenes = SceneStore(controller: controller)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--replay"), index + 1 < arguments.count {
            // Developer replay of a recorded `--probe` report: no Bluetooth, no automations, read-only.
            controller.startReplay(from: URL(fileURLWithPath: arguments[index + 1]))
        } else {
            controller.systemNowPlaying.start()
            controller.start()
            scenes.startAutomation()
        }
        SnapshotRunner.runIfRequested(navigation: navigation, controller: controller, scenes: scenes, curves: curves)
        sizeMainWindowOnFirstLaunch()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller.refreshStatus() }
        }
    }

    /// SwiftUI's `defaultSize` is not always honoured for a `Window` without a saved frame (observed: the window
    /// opened at full screen size on a 3440-pt display), so size and centre it explicitly the first time.
    private func sizeMainWindowOnFirstLaunch() {
        guard UserDefaults.standard.string(forKey: "NSWindow Frame main") == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard let window = NSApp.windows.first(where: { $0.title == "Sound Connect" && $0.isVisible }),
                  let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
            let size = NSSize(width: min(1160, visible.width - 80), height: min(820, visible.height - 60))
            let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
            window.setFrame(NSRect(origin: origin, size: size), display: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running for the menu bar controls and scene automations.
        !UserDefaults.standard.bool(forKey: "showMenuBarExtra") && UserDefaults.standard.object(forKey: "showMenuBarExtra") != nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.systemNowPlaying.stop()
        controller.disconnect()
    }
}

struct SoundConnectCommands: Commands {
    let controller: HeadphoneController
    let scenes: SceneStore
    let navigation: Navigation

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}

        CommandGroup(after: .sidebar) {
            ForEach(AppPage.allCases) { page in
                Button(page.title) { navigation.page = page }
                    .keyboardShortcut(page.shortcut, modifiers: .command)
            }
            Divider()
        }

        CommandMenu("Headphones") {
            let noise = controller.state.noise
            let modes = controller.state.capabilities.noise?.modes ?? []
            ForEach(modes) { mode in
                Button(mode.title) {
                    let entering = mode == .ambient && controller.noiseBase?.mode != .ambient
                    let level = UserDefaults.standard.object(forKey: "lastAmbientLevel") as? Int ?? 12
                    controller.requestNoise { value in
                        value.mode = mode
                        if entering { value.ambientLevel = level }
                    }
                }
                .keyboardShortcut(Self.key(for: mode), modifiers: [.command, .option])
                .disabled(!controller.canWrite || noise?.mode == mode)
            }
            if controller.state.capabilities.noise?.supportsVoiceFocus == true {
                Button(noise?.focusOnVoice == true ? "Turn Off Focus on Voice" : "Turn On Focus on Voice") {
                    controller.requestNoise { $0.focusOnVoice.toggle() }
                }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(!controller.canWrite || noise?.mode != .ambient)
            }
            Divider()
            if let cap = controller.state.capabilities.equalizer {
                Menu("Equalizer") {
                    ForEach(cap.presets) { preset in
                        Button(preset.name) { controller.apply(.equalizerPreset(preset.id)) }
                            .disabled(controller.state.equalizer?.presetID == preset.id)
                    }
                }
                .disabled(!controller.canWrite)
            }
            if let name = controller.state.capabilities.upscalingName {
                Button(controller.state.upscaling?.enabled == true ? "Turn Off \(name)" : "Turn On \(name)") {
                    controller.apply(.upscaling(!(controller.state.upscaling?.enabled ?? false)))
                }
                .disabled(!controller.canWrite)
            }
            if controller.state.capabilities.speakToChat {
                Button(controller.state.speakToChat?.enabled == true ? "Turn Off Speak-to-Chat" : "Turn On Speak-to-Chat") {
                    controller.apply(.speakToChat(!(controller.state.speakToChat?.enabled ?? false)))
                }
                .disabled(!controller.canWrite)
            }
            Divider()
            Button("Refresh Status") { controller.refreshStatus() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!controller.canWrite)
            if controller.isConnected {
                Button("Disconnect Controls") { controller.disconnect() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
            } else {
                Button("Connect") {
                    if let address = controller.selectedAddress { controller.connect(address: address, initiate: true) }
                }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(controller.selectedAddress == nil || controller.phase.isBusy)
            }
        }

        CommandMenu("Scenes") {
            ForEach(Array(scenes.scenes.prefix(9).enumerated()), id: \.element.id) { index, scene in
                let applied = scenes.isApplied(scene)
                Button(applied ? "\(scene.name) — Applied" : "Apply \(scene.name)") { Task { await scenes.apply(scene.id) } }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .control])
                    .disabled(!scenes.canApply(scene))
            }
            if !scenes.scenes.isEmpty { Divider() }
            Button("Manage Scenes…") { navigation.page = .scenes }
        }
    }

    private static func key(for mode: NoiseMode) -> KeyEquivalent {
        switch mode {
        case .noiseCancelling: "n"
        case .windReduction: "w"
        case .ambient: "a"
        case .off: "o"
        }
    }
}
