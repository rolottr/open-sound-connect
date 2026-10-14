import SwiftUI

/// Named EQ curves saved on this Mac (applied through the headset's Manual preset).
struct SavedCurve: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var bands: [Int]
    var clearBass: Int?
}

@MainActor
@Observable
final class CurveLibrary {
    private(set) var curves: [SavedCurve] = []
    private let key = "savedEqualizerCurves"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([SavedCurve].self, from: data) {
            curves = decoded
        }
    }

    func add(_ curve: SavedCurve) {
        curves.append(curve)
        persist()
    }

    func remove(_ id: UUID) {
        curves.removeAll { $0.id == id }
        persist()
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = curves.firstIndex(where: { $0.id == id }) else { return }
        curves[index].name = name
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(curves) { UserDefaults.standard.set(data, forKey: key) }
    }
}

struct SoundView: View {
    @Environment(HeadphoneController.self) private var controller

    var body: some View {
        let caps = controller.state.capabilities
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                PageHeader(title: "Sound")
                if caps.equalizer != nil {
                    EqualizerEditorCard()
                    SavedCurvesCard()
                }
                if caps.upscalingName != nil || caps.connectionPriority {
                    SoundQualityCard()
                }
                if !caps.hasAnySoundFeature && !caps.connectionPriority {
                    Card { Text("These headphones don't report adjustable sound settings.").foregroundStyle(Theme.secondary) }
                }
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 10) {
                Text(title).font(.pageTitle).foregroundStyle(Theme.text).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                trailing
            }
            if let subtitle {
                Text(subtitle).font(.body15).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 6)
        .padding(.top, 8)
    }
}

struct EqualizerEditorCard: View {
    @Environment(HeadphoneController.self) private var controller
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draftBands: [Int]?
    @State private var draftClearBass: Int?
    @State private var busy = false

    var body: some View {
        let state = controller.state
        if let cap = state.capabilities.equalizer {
            let eq = state.equalizer ?? EqualizerState(presetID: 0, bands: Array(repeating: 0, count: cap.bandCount), clearBass: cap.hasClearBass ? 0 : nil)
            let current = EqualizerPreset(id: eq.presetID, name: EqualizerPreset.displayName(for: eq.presetID))
            let bands = draftBands ?? eq.bands
            let clearBass = draftClearBass ?? eq.clearBass ?? 0
            let manual = cap.presets.first { $0.id == 0xA0 } ?? cap.presets.first(where: \.isEditable)
            // Current preset; for fixed presets, the one consequence worth stating: editing switches to Manual.
            Card("Equalizer", subtitle: current.isEditable ? current.name : "\(current.name) · editing switches to \(manual?.name ?? "Manual")",
                 trailing: AnyView(trailing(eq: eq, cap: cap, editable: current.isEditable))) {
                FlowLayout(spacing: 8) {
                    ForEach(cap.presets) { preset in
                        Chip(title: preset.name, selected: eq.presetID == preset.id,
                             pending: controller.isPending(.equalizerPreset(preset.id))) {
                            draftBands = nil
                            draftClearBass = nil
                            controller.apply(.equalizerPreset(preset.id))
                        }
                        .disabled(!controller.canWrite || busy)
                    }
                }

                HStack(alignment: .bottom, spacing: 0) {
                    if cap.hasClearBass {
                        BandSlider(label: "Clear Bass", value: clearBass, range: cap.bandRange,
                                   enabled: controller.canWrite && !busy, highlight: true,
                                   onDrag: { draftClearBass = $0; draftBands = draftBands ?? eq.bands },
                                   onCommit: { commit(bands: draftBands ?? eq.bands, clearBass: $0, current: current, manual: manual) })
                            .frame(width: 76)
                        Rectangle().fill(Theme.hairline).frame(width: 1).padding(.vertical, 22).padding(.horizontal, 10)
                    }
                    ZStack {
                        // Thumb travel: value label 14 + spacing 8 + thumb radius 9 on top; label 13 + 8 + 9 below.
                        EqualizerPreview(bands: bands, range: cap.bandRange, centered: true)
                            .padding(.top, 31)
                            .padding(.bottom, 30)
                            .opacity(0.9)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: bands)
                        HStack(spacing: 0) {
                            ForEach(Array(cap.bandLabels.enumerated()), id: \.offset) { index, label in
                                BandSlider(label: label, value: index < bands.count ? bands[index] : 0, range: cap.bandRange,
                                           enabled: controller.canWrite && !busy,
                                           onDrag: { value in
                                               var next = draftBands ?? eq.bands
                                               if index < next.count { next[index] = value }
                                               draftBands = next
                                           },
                                           onCommit: { value in
                                               var next = draftBands ?? eq.bands
                                               if index < next.count { next[index] = value }
                                               commit(bands: next, clearBass: draftClearBass ?? eq.clearBass, current: current, manual: manual)
                                           })
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
                .frame(height: 230)
                .padding(.top, 4)

                if busy {
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .onChange(of: eq) { _, _ in
                if !busy { draftBands = nil; draftClearBass = nil }
            }
        }
    }

    private func trailing(eq: EqualizerState, cap: EqualizerCapability, editable: Bool) -> some View {
        Button {
            commit(bands: Array(repeating: 0, count: cap.bandCount), clearBass: cap.hasClearBass ? 0 : nil,
                   current: EqualizerPreset(id: eq.presetID, name: ""), manual: cap.presets.first(where: \.isEditable))
        } label: {
            Label("Flatten", systemImage: "arrow.counterclockwise").font(.label)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.accent)
        .disabled(!controller.canWrite || busy || (eq.bands.allSatisfy { $0 == 0 } && (eq.clearBass ?? 0) == 0 && editable))
        .help("Set every band to 0 on the Manual preset")
    }

    private func commit(bands: [Int], clearBass: Int?, current: EqualizerPreset, manual: EqualizerPreset?) {
        draftBands = bands
        draftClearBass = clearBass
        busy = true
        // Selecting the editable preset and writing its bands is one transaction: if the selection isn't
        // confirmed, the bands are not written (they would land on whatever preset is active).
        var steps: [DeviceChange] = []
        if !current.isEditable, let manual { steps.append(.equalizerPreset(manual.id)) }
        steps.append(.equalizerBands(bands: bands, clearBass: clearBass))
        Task {
            await controller.performGroup(steps)
            busy = false
            draftBands = nil
            draftClearBass = nil
        }
    }
}

struct SavedCurvesCard: View {
    @Environment(HeadphoneController.self) private var controller
    @Environment(CurveLibrary.self) private var library
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        let state = controller.state
        let cap = state.capabilities.equalizer
        Card("My Curves",
             trailing: AnyView(
                Button {
                    newName = "Curve \(library.curves.count + 1)"
                    naming = true
                } label: { Label("Save Current", systemImage: "plus").font(.label) }
                .buttonStyle(.borderless)
                .foregroundStyle(state.equalizer == nil || controller.isReplay ? Theme.tertiary : Theme.accent)
                .disabled(state.equalizer == nil || controller.isReplay)
                .help(controller.isReplay ? "Not available in a read-only replay" : "Save the headphones' current curve on this Mac")
             )) {
            if library.curves.isEmpty {
                Text("No saved curves")
                    .font(.caption11).foregroundStyle(Theme.secondary)
            } else if let cap {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    ForEach(library.curves) { curve in
                        Button { apply(curve, cap: cap) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                EqualizerPreview(bands: (curve.clearBass.map { [$0] } ?? []) + curve.bands, range: cap.bandRange)
                                    .frame(height: 36)
                                Text(curve.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardRaised))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!controller.canWrite)
                        .contextMenu {
                            Button("Delete “\(curve.name)”", role: .destructive) { library.remove(curve.id) }
                        }
                        .accessibilityLabel("Apply curve \(curve.name)")
                    }
                }
            }
        }
        .alert("Save Curve", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Save") {
                if let eq = state.equalizer {
                    library.add(SavedCurve(name: newName.trimmingCharacters(in: .whitespaces).ifEmpty("Curve"),
                                           bands: eq.bands, clearBass: eq.clearBass))
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the headphones' current equalizer curve on this Mac.")
        }
    }

    private func apply(_ curve: SavedCurve, cap: EqualizerCapability) {
        guard curve.bands.count == cap.bandCount, let manual = cap.presets.first(where: \.isEditable) else {
            controller.showToast(.warning, "That curve doesn't match these headphones' bands.")
            return
        }
        var steps: [DeviceChange] = []
        if controller.state.equalizer?.presetID != manual.id { steps.append(.equalizerPreset(manual.id)) }
        steps.append(.equalizerBands(bands: curve.bands, clearBass: cap.hasClearBass ? curve.clearBass : nil))
        Task {
            let result = await controller.performGroup(steps)
            if result.failed == nil {
                controller.showToast(.info, "Applied “\(curve.name)”.")
            }
        }
    }
}

struct SoundQualityCard: View {
    @Environment(HeadphoneController.self) private var controller
    @State private var confirmPriority: ConnectionPriority?

    var body: some View {
        let state = controller.state
        let caps = state.capabilities
        Card("Sound Quality", symbol: "waveform") {
            VStack(spacing: 14) {
                if let name = caps.upscalingName {
                    SettingRow(symbol: "sparkles", title: name,
                               detail: upscalingDetail(state)) {
                        Toggle(name, isOn: Binding(get: { state.upscaling?.enabled ?? false }, set: { controller.apply(.upscaling($0)) }))
                            .labelsHidden().toggleStyle(AccentToggleStyle())
                            .disabled(!controller.canWrite || state.upscaling == nil)
                    }
                }
                if caps.connectionPriority {
                    if caps.upscalingName != nil { RowDivider() }
                    SettingRow(symbol: "antenna.radiowaves.left.and.right", title: "Bluetooth Connection Quality",
                               detail: "Changing this reconnects the headphones.") {
                        Picker("Bluetooth Connection Quality", selection: Binding(
                            get: { state.connectionPriority ?? .soundQuality },
                            set: { if $0 != state.connectionPriority { confirmPriority = $0 } }
                        )) {
                            ForEach(ConnectionPriority.allCases) { Text($0 == .soundQuality ? "Sound Quality" : "Stable Connection").tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .disabled(!controller.canWrite || state.connectionPriority == nil)
                    }
                }
            }
        }
        .confirmationDialog("Change connection quality?", isPresented: Binding(get: { confirmPriority != nil }, set: { if !$0 { confirmPriority = nil } }),
                            presenting: confirmPriority) { value in
            Button(value.title) { controller.apply(.connectionPriority(value)) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The headphones will disconnect briefly and reconnect. Sound Connect reconnects automatically.")
        }
    }

    private func upscalingDetail(_ state: DeviceState) -> String {
        guard let upscaling = state.upscaling else { return "" }
        return upscaling.active == true ? "Upscaling now" : ""
    }
}

/// Simple wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
