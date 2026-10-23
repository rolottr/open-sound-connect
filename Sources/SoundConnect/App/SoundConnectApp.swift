import AppKit
import SwiftUI

struct SoundConnectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("showMenuBarExtra") private var showMenuBar = true

    var body: some Scene {
        Window("Open Sound Connect", id: "main") {
            ReleasedWhenClosed { RootView() }
                .environment(appDelegate.controller)
                .environment(appDelegate.scenes)
                .environment(appDelegate.curves)
                .environment(appDelegate.navigation)
                .environment(appDelegate.loginItem)
                .environment(appDelegate.updates)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1160, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            SoundConnectCommands(controller: appDelegate.controller, scenes: appDelegate.scenes, navigation: appDelegate.navigation,
                                 updates: appDelegate.updates)
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            ReleasedWhenClosed { MenuBarView() }
                .background(MenuBarWindowSizing())
                .environment(appDelegate.controller)
                .environment(appDelegate.scenes)
                .environment(appDelegate.navigation)
                .environment(appDelegate.updates)
        } label: {
            MenuBarIcon().environment(appDelegate.controller)
        }
        .menuBarExtraStyle(.window)

        Settings {
            AppPreferencesCard()
                .environment(appDelegate.loginItem)
                .environment(appDelegate.updates)
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
    let loginItem = LoginItem()
    let updates = UpdateChecker()
    lazy var scenes = SceneStore(controller: controller)
    /// A login launch (or `--background`) starts in the menu bar only, without a window or Dock icon.
    private var startsInBackground = false

    /// Read live so the menu bar toggle takes effect without a relaunch; on by default.
    static var showsMenuBarExtra: Bool {
        UserDefaults.standard.object(forKey: "showMenuBarExtra") as? Bool ?? true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        startsInBackground = Self.showsMenuBarExtra && !LaunchContext.isDeveloperRun
            && (LaunchContext.wasLaunchedAtLogin() || LaunchContext.requestsBackground)
        if startsInBackground {
            NSApp.setActivationPolicy(.accessory)
            closeLaunchWindow()
        }
        observeAppWindows()
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--replay"), index + 1 < arguments.count {
            // Developer replay of a recorded `--probe` report: no Bluetooth, no automations, read-only.
            controller.startReplay(from: URL(fileURLWithPath: arguments[index + 1]))
        } else {
            controller.start()
            scenes.startAutomation()
        }
        updates.startAutomaticChecks()
        SnapshotRunner.runIfRequested(navigation: navigation, controller: controller, scenes: scenes, curves: curves)
        if !startsInBackground { sizeMainWindowOnFirstLaunch() }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.controller.refreshStatus()
                // The person may have approved or removed the login item in System Settings meanwhile.
                self?.loginItem.refresh()
            }
        }
    }

    /// SwiftUI always presents the `Window` scene at launch (it ignores `applicationShouldOpenUntitledFile`), so a
    /// background launch closes that window on the first update after it appears.
    private func closeLaunchWindow() {
        var observer: NSObjectProtocol?
        let giveUp = Date().addingTimeInterval(5)
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                let window = NSApp.windows.first { $0.isVisible && Self.isAppWindow($0) }
                guard window != nil || Date() > giveUp else { return }
                if let observer { NotificationCenter.default.removeObserver(observer) }
                self?.startsInBackground = false
                window?.close()
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    /// Like most menu bar apps: while a window is open the app has a Dock icon and menus; once the last one closes
    /// it steps back to the menu bar (no Dock icon, not in ⌘-Tab) and keeps running.
    private func observeAppWindows() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, !self.startsInBackground,
                      let window = note.object as? NSWindow, Self.isAppWindow(window) else { return }
                guard NSApp.activationPolicy() != .regular else { return }
                NSApp.setActivationPolicy(.regular)
                // Coming back from accessory, the app must be active again for its menus to show.
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let closing = note.object as? NSWindow, Self.isAppWindow(closing), Self.showsMenuBarExtra else { return }
                let othersOpen = NSApp.windows.contains { $0 !== closing && $0.isVisible && Self.isAppWindow($0) }
                if !othersOpen { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    /// The main and Settings windows; not the menu bar panel, sheets or alerts.
    private static func isAppWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && !window.isSheet && window.styleMask.contains(.titled) && window.canBecomeMain
    }

    /// SwiftUI's `defaultSize` is not always honoured for a `Window` without a saved frame (observed: the window
    /// opened at full screen size on a 3440-pt display), so size and centre it explicitly the first time.
    private func sizeMainWindowOnFirstLaunch() {
        guard UserDefaults.standard.string(forKey: "NSWindow Frame main") == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard let window = NSApp.windows.first(where: { $0.title == "Open Sound Connect" && $0.isVisible }),
                  let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
            let size = NSSize(width: min(1160, visible.width - 80), height: min(820, visible.height - 60))
            let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
            window.setFrame(NSRect(origin: origin, size: size), display: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running for the menu bar controls and scene automations.
        !Self.showsMenuBarExtra
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening the app again from Finder or Spotlight while it lives in the menu bar brings the window back.
        NSApp.setActivationPolicy(.regular)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.disconnect()
    }
}

struct SoundConnectCommands: Commands {
    let controller: HeadphoneController
    let scenes: SceneStore
    let navigation: Navigation
    let updates: UpdateChecker
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}

        // The app's own About page instead of the standard About panel.
        CommandGroup(replacing: .appInfo) {
            Button("About Open Sound Connect") { navigation.show(.about, using: openWindow) }
        }

        CommandGroup(after: .appInfo) {
            if UpdateChecker.isEnabled {
                Button("Check for Updates…") { Task { await updates.checkAndReport() } }
                    .disabled(updates.state == .checking)
            }
        }

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
