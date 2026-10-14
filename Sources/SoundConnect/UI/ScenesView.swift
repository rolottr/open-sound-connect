import AppKit
import SwiftUI

struct ScenesView: View {
    @Environment(HeadphoneController.self) private var controller
    @Environment(SceneStore.self) private var store
    @State private var editing: SoundScene?
    @State private var deleting: SoundScene?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                PageHeader(title: "Scenes") {
                    Button {
                        editing = SoundScene.capture(from: controller.state, name: "My Scene")
                    } label: { Label("Capture Current", systemImage: "camera.metering.center.weighted") }
                        .disabled(!controller.canWrite)
                        .help("Create a scene from the headphones' current settings")
                    Button {
                        editing = SoundScene(name: "New Scene", symbol: "sparkles", tint: .lavender,
                                             noise: SceneNoise(mode: .noiseCancelling, ambientLevel: 12, focusOnVoice: false))
                    } label: { Label("New Scene", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .foregroundStyle(Theme.onAccent)
                        .keyboardShortcut("n", modifiers: [.command])
                }

                if let error = store.saveError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption11).foregroundStyle(Theme.warning)
                }

                if store.scenes.isEmpty {
                    Card {
                        VStack(spacing: 10) {
                            Image(systemName: "sparkles").font(.system(size: 28)).foregroundStyle(Theme.accent)
                            Text("No scenes yet").font(.cardTitle).foregroundStyle(Theme.text)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: Theme.cardSpacing)], spacing: Theme.cardSpacing) {
                        ForEach(store.scenes) { scene in
                            SceneCard(scene: scene, onEdit: { editing = scene }, onDelete: { deleting = scene })
                        }
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 9))
                    Text("Saved on this Mac")
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.storageLocation]) }
                        .buttonStyle(.link)
                        .disabled(!FileManager.default.fileExists(atPath: store.storageLocation.path))
                }
                .font(.caption11).foregroundStyle(Theme.tertiary)
                .padding(.top, 4)
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $editing) { scene in
            SceneEditor(scene: scene, isNew: store.scene(scene.id) == nil) { saved in
                store.upsert(saved)
            }
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Scene", role: .destructive) { if let id = deleting?.id { store.delete(id) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only removes the saved scene; the headphones keep their current settings.")
        }
    }
}

struct SceneCard: View {
    @Environment(HeadphoneController.self) private var controller
    @Environment(SceneStore.self) private var store
    let scene: SoundScene
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        let running = store.runningSceneID == scene.id
        // Live: true only while the connected headphones match every setting in the scene.
        let applied = !running && store.isApplied(scene)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: scene.symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(scene.tint.color)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(scene.tint.color.opacity(0.16)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(scene.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    HStack(spacing: 5) {
                        Image(systemName: scene.trigger.symbol).font(.system(size: 9.5, weight: .semibold))
                        Text(scene.trigger.title).lineLimit(1)
                        if scene.trigger.isAutomatic && !scene.triggerEnabled { Text("· paused") }
                    }
                    .font(.caption11)
                    .foregroundStyle(scene.trigger.isAutomatic && scene.triggerEnabled ? Theme.accentSoft : Theme.secondary)
                }
                Spacer(minLength: 6)
                Menu {
                    Button("Edit…", action: onEdit)
                    Button("Duplicate") { store.duplicate(scene.id) }
                    if scene.trigger.isAutomatic {
                        Button(scene.triggerEnabled ? "Pause Automation" : "Resume Automation") {
                            var copy = scene
                            copy.triggerEnabled.toggle()
                            store.upsert(copy)
                        }
                    }
                    Divider()
                    Button("Delete…", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Theme.control))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More actions for \(scene.name)")
            }

            FlowLayout(spacing: 6) {
                ForEach(scene.summary, id: \.self) { part in
                    Text(part)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.text.opacity(0.85))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Theme.control))
                }
            }

            HStack(spacing: 10) {
                ResultLine(result: scene.lastResult)
                Spacer()
                Button {
                    Task { await store.apply(scene.id) }
                } label: {
                    HStack(spacing: 6) {
                        if running {
                            ProgressView().controlSize(.mini).tint(Theme.onAccent)
                        } else if applied {
                            Image(systemName: "checkmark").font(.system(size: 10.5, weight: .bold))
                        }
                        Text(running ? "Applying" : applied ? "Applied" : "Apply").font(.system(size: 12.5, weight: .semibold))
                    }
                    .padding(.horizontal, 14).frame(height: 30)
                    .foregroundStyle(applied ? Theme.secondary : Theme.onAccent)
                    .background(Capsule().fill(applied ? Theme.control : scene.tint.color))
                }
                .buttonStyle(.plain)
                .disabled(!store.canApply(scene))
                .accessibilityLabel(applied ? "\(scene.name) applied" : "Apply \(scene.name)")
            }
        }
        .padding(18)
        .background(CardBackground())
        .overlay(alignment: .top) {
            Capsule().fill(scene.tint.color.opacity(0.8)).frame(width: 36, height: 3).padding(.top, 0.5)
        }
        .contextMenu {
            Button(applied ? "Applied" : "Apply") { Task { await store.apply(scene.id) } }.disabled(!store.canApply(scene))
            Button("Edit…", action: onEdit)
            Button("Duplicate") { store.duplicate(scene.id) }
            Button("Delete…", role: .destructive, action: onDelete)
        }
    }
}

struct ResultLine: View {
    let result: SceneResult?

    var body: some View {
        if let result {
            HStack(spacing: 5) {
                Image(systemName: result.isClean ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.isClean ? Theme.good : Theme.warning)
                Text("\(result.isClean ? "Applied" : "\(result.confirmed) of \(result.total) applied") · \(result.date.formatted(.relative(presentation: .named)))")
                    .foregroundStyle(Theme.secondary)
            }
            .font(.caption11)
            .help(result.problems.isEmpty ? (result.skipped.isEmpty ? "" : "Not supported here: \(result.skipped.joined(separator: ", "))")
                                          : "Not applied: \(result.problems.joined(separator: ", "))")
        } else {
            Text("Not applied yet").font(.caption11).foregroundStyle(Theme.tertiary)
        }
    }
}

// MARK: - Editor

struct SceneEditor: View {
    @Environment(HeadphoneController.self) private var controller
    @Environment(CurveLibrary.self) private var curves
    @Environment(\.dismiss) private var dismiss
    @State var scene: SoundScene
    let isNew: Bool
    let onSave: (SoundScene) -> Void

    static let symbolNames: [String: String] = [
        "sparkles": "Sparkles", "brain.head.profile": "Focus", "figure.walk": "Walking", "person.2.wave.2": "Conversation",
        "airplane": "Travel", "tram.fill": "Commute", "cup.and.saucer.fill": "Café", "moon.stars.fill": "Night",
        "book.fill": "Reading", "laptopcomputer": "Work", "headphones": "Headphones", "music.note": "Music",
        "film": "Movies", "gamecontroller.fill": "Gaming", "figure.run": "Workout", "leaf.fill": "Calm",
        "phone.fill": "Calls", "house.fill": "Home",
    ]

    static let symbols = ["sparkles", "brain.head.profile", "figure.walk", "person.2.wave.2", "airplane", "tram.fill",
                          "cup.and.saucer.fill", "moon.stars.fill", "book.fill", "laptopcomputer", "headphones",
                          "music.note", "film", "gamecontroller.fill", "figure.run", "leaf.fill", "phone.fill", "house.fill"]

    var body: some View {
        let caps = controller.state.capabilities
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "New Scene" : "Edit Scene").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    identitySection
                    editorSection("Noise Control", include: Binding(
                        get: { scene.noise != nil },
                        set: { scene.noise = $0 ? SceneNoise(mode: .noiseCancelling, ambientLevel: 12, focusOnVoice: false) : nil }
                    )) {
                        if let noise = scene.noise {
                            Picker("Mode", selection: Binding(get: { noise.mode }, set: { scene.noise?.mode = $0 })) {
                                ForEach(caps.noise?.modes ?? NoiseMode.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            if noise.mode == .ambient {
                                let range = caps.noise?.ambientRange ?? 1...20
                                HStack {
                                    Text("Level").font(.label).foregroundStyle(Theme.secondary)
                                    LevelSlider(value: noise.ambientLevel, range: range, accessibilityName: "Scene ambient level",
                                                onDrag: { scene.noise?.ambientLevel = $0 }, onCommit: { scene.noise?.ambientLevel = $0 })
                                    Text("\(noise.ambientLevel)").font(.system(size: 12, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(Theme.text).frame(width: 22)
                                }
                                Toggle("Focus on Voice", isOn: Binding(get: { noise.focusOnVoice }, set: { scene.noise?.focusOnVoice = $0 }))
                                    .toggleStyle(AccentToggleStyle())
                            }
                        }
                    }
                    editorSection("Equalizer", include: Binding(
                        get: { scene.equalizer != nil },
                        set: { scene.equalizer = $0 ? .preset(controller.state.equalizer?.presetID ?? 0x00) : nil }
                    )) {
                        if let equalizer = scene.equalizer {
                            Picker("Equalizer", selection: Binding(
                                get: { Self.tag(for: equalizer) },
                                set: { tag in scene.equalizer = equalizerValue(for: tag) ?? scene.equalizer }
                            )) {
                                ForEach(caps.equalizer?.presets.filter { !$0.isEditable } ?? []) { Text($0.name).tag("p\($0.id)") }
                                if case .custom = equalizer { Text("Custom curve (saved in scene)").tag("custom") }
                                ForEach(curves.curves) { Text("Curve: \($0.name)").tag("c\($0.id.uuidString)") }
                            }
                            .labelsHidden()
                            if case .custom(let bands, let clearBass) = equalizer, let cap = caps.equalizer {
                                EqualizerPreview(bands: (clearBass.map { [$0] } ?? []) + bands, range: cap.bandRange).frame(height: 34)
                            }
                        }
                    }
                    if caps.upscalingName != nil {
                        boolSection(caps.upscalingName ?? "DSEE", value: $scene.upscaling, current: controller.state.upscaling?.enabled)
                    }
                    if caps.speakToChat {
                        boolSection("Speak-to-Chat", value: $scene.speakToChat, current: controller.state.speakToChat?.enabled)
                    }
                    if caps.autoPause {
                        boolSection("Pause When Taken Off", value: $scene.autoPause, current: controller.state.autoPause)
                    }
                    if let touch = controller.state.generalSettings.first(where: { $0.key == "TOUCH_PANEL_SETTING" && $0.isBoolean }) {
                        boolSection(touch.title, value: Binding(
                            get: { scene.generalSettings[touch.key] },
                            set: { scene.generalSettings[touch.key] = $0 }
                        ), current: touch.value)
                    }
                    TriggerEditor(trigger: $scene.trigger, enabled: $scene.triggerEnabled)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }

            HStack {
                if scene.isEmpty {
                    Label("Include at least one setting.", systemImage: "info.circle").font(.caption11).foregroundStyle(Theme.warning)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Create Scene" : "Save") {
                    scene.name = scene.name.trimmingCharacters(in: .whitespaces).ifEmpty("Scene")
                    onSave(scene)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(scene.isEmpty)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            .background(Theme.sidebar)
        }
        .frame(width: 560, height: 680)
        .background(Theme.canvasTop)
        .preferredColorScheme(.dark)
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: scene.symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(scene.tint.color)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(scene.tint.color.opacity(0.16)))
                TextField("Scene name", text: $scene.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 9), alignment: .leading, spacing: 6) {
                ForEach(Self.symbols, id: \.self) { symbol in
                    Button { scene.symbol = symbol } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 13))
                            .foregroundStyle(scene.symbol == symbol ? Theme.onAccent : Theme.text)
                            .frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(scene.symbol == symbol ? scene.tint.color : Theme.control))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Self.symbolNames[symbol] ?? "Icon")
                }
            }
            HStack(spacing: 8) {
                ForEach(SceneTint.allCases) { tint in
                    Button { scene.tint = tint } label: {
                        Circle().fill(tint.color).frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(Theme.text, lineWidth: scene.tint == tint ? 2 : 0))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(tint.rawValue) color")
                }
            }
        }
    }

    private func editorSection<Content: View>(_ title: String, include: Binding<Bool>, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer(minLength: 12)
                Toggle("Include \(title)", isOn: include)
                    .labelsHidden()
                    .toggleStyle(AccentToggleStyle())
            }
            if include.wrappedValue { content() }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
    }

    private func boolSection(_ title: String, value: Binding<Bool?>, current: Bool?) -> some View {
        editorSection(title, include: Binding(get: { value.wrappedValue != nil }, set: { value.wrappedValue = $0 ? (current ?? true) : nil })) {
            Picker(title, selection: Binding(get: { value.wrappedValue ?? true }, set: { value.wrappedValue = $0 })) {
                Text("On").tag(true)
                Text("Off").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)
        }
    }

    private static func tag(for equalizer: SceneEqualizer) -> String {
        switch equalizer {
        case .preset(let id): "p\(id)"
        case .custom: "custom"
        }
    }

    private func equalizerValue(for tag: String) -> SceneEqualizer? {
        if tag.hasPrefix("p"), let id = UInt8(tag.dropFirst()) { return .preset(id) }
        if tag.hasPrefix("c"), let curve = curves.curves.first(where: { "c\($0.id.uuidString)" == tag }) {
            return .custom(bands: curve.bands, clearBass: curve.clearBass)
        }
        return nil
    }
}

struct TriggerEditor: View {
    @Binding var trigger: SceneTrigger
    @Binding var enabled: Bool

    private enum Kind: String, CaseIterable, Identifiable {
        case manual = "Manual", onConnect = "On Connect", schedule = "Schedule", app = "App"
        var id: String { rawValue }
    }

    private var kind: Kind {
        switch trigger {
        case .manual: .manual
        case .onConnect: .onConnect
        case .schedule: .schedule
        case .appActivated: .app
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Run Automatically").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                if trigger.isAutomatic {
                    Toggle("Enabled", isOn: $enabled).toggleStyle(AccentToggleStyle()).font(.label)
                }
            }
            Picker("Trigger", selection: Binding(get: { kind }, set: { setKind($0) })) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch trigger {
            case .manual, .onConnect:
                EmptyView()
            case .schedule(let schedule):
                HStack(spacing: 12) {
                    DatePicker("Time", selection: Binding(
                        get: { Calendar.current.date(from: DateComponents(hour: schedule.hour, minute: schedule.minute)) ?? Date() },
                        set: { date in
                            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                            trigger = .schedule(SceneSchedule(hour: parts.hour ?? 9, minute: parts.minute ?? 0, weekdays: schedule.weekdays))
                        }
                    ), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .fixedSize()
                    HStack(spacing: 4) {
                        ForEach(1...7, id: \.self) { day in
                            let on = schedule.weekdays.contains(day)
                            Button {
                                var days = schedule.weekdays
                                if on { days.remove(day) } else { days.insert(day) }
                                if !days.isEmpty { trigger = .schedule(SceneSchedule(hour: schedule.hour, minute: schedule.minute, weekdays: days)) }
                            } label: {
                                Text(Calendar.current.veryShortWeekdaySymbols[day - 1])
                                    .font(.system(size: 11, weight: .semibold))
                                    .frame(width: 24, height: 24)
                                    .foregroundStyle(on ? Theme.onAccent : Theme.secondary)
                                    .background(Circle().fill(on ? Theme.accent : Theme.control))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                }
                hint("Only runs if the headphones are connected.")
            case .appActivated(_, let name):
                HStack {
                    Text(name.isEmpty ? "No app chosen" : name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                    Spacer()
                    Button("Choose App…") { chooseApp() }
                }
                hint("At most once every 10 minutes.")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.caption11).foregroundStyle(Theme.secondary)
    }

    private func setKind(_ kind: Kind) {
        switch kind {
        case .manual: trigger = .manual
        case .onConnect: trigger = .onConnect
        case .schedule: trigger = .schedule(SceneSchedule(hour: 9, minute: 0, weekdays: [2, 3, 4, 5, 6]))
        case .app:
            trigger = .appActivated(bundleID: "", appName: "")
            chooseApp()
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        trigger = .appActivated(bundleID: id, appName: name)
    }
}
