import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Evidence view: what the headphones reported, every write and whether it was read back, and the raw frames.
struct ActivityView: View {
    @Environment(HeadphoneController.self) private var controller
    @State private var autoscroll = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                PageHeader(title: "Activity")
                AdaptiveColumns {
                    VerificationCard()
                    CapabilityCard()
                }
                TrafficCard()
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

struct VerificationCard: View {
    @Environment(HeadphoneController.self) private var controller

    var body: some View {
        Card("Changes", symbol: "checkmark.seal") {
            if controller.verifications.isEmpty {
                Text("Nothing changed yet in this session.").font(.caption11).foregroundStyle(Theme.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(controller.verifications.prefix(12)) { record in
                        HStack(spacing: 8) {
                            icon(record.outcome)
                            Text(record.label).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                            Spacer()
                            Text(record.date.formatted(date: .omitted, time: .standard))
                                .font(.caption11.monospacedDigit()).foregroundStyle(Theme.tertiary)
                        }
                        .help(detail(record.outcome))
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(detail(record.outcome))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func icon(_ outcome: VerificationRecord.Outcome) -> some View {
        switch outcome {
        case .confirmed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good)
        case .adjusted: Image(systemName: "equal.circle").foregroundStyle(Theme.secondary)
        case .mismatch: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
        case .notCheckable: Image(systemName: "arrow.up.circle").foregroundStyle(Theme.secondary)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.danger)
        }
    }

    private func detail(_ outcome: VerificationRecord.Outcome) -> String {
        switch outcome {
        case .confirmed: "Applied"
        case .adjusted(let detail): detail
        case .mismatch: "Not applied: the headphones kept another value"
        case .notCheckable: "Sent"
        case .failed(let error): "Failed: \(error)"
        }
    }
}

struct CapabilityCard: View {
    @Environment(HeadphoneController.self) private var controller

    var body: some View {
        let state = controller.state
        let caps = state.capabilities
        Card("Reported Features", symbol: "list.bullet.rectangle") {
            let rows: [(String, Bool, String)] = [
                ("Noise canceling & ambient", caps.noise != nil, caps.noise.map { "\($0.modes.count) modes, level \($0.ambientRange.lowerBound)–\($0.ambientRange.upperBound)" } ?? ""),
                ("Equalizer", caps.equalizer != nil, caps.equalizer.map { "\($0.presets.count) presets, \($0.bandCount) bands\($0.hasClearBass ? " + Clear Bass" : "")" } ?? ""),
                ("Listening mode", caps.listeningMode != nil, caps.listeningMode == nil ? "Not offered by this model" : ""),
                (caps.upscalingName ?? "DSEE", caps.upscalingName != nil, ""),
                ("Speak-to-Chat", caps.speakToChat, caps.speakToChatOptions ? "with sensitivity & timer" : ""),
                ("Connection quality", caps.connectionPriority, ""),
                ("Pause when taken off", caps.autoPause, ""),
                ("Automatic power off", !caps.autoPowerOffOptions.isEmpty, caps.autoPowerOffOptions.map(\.title).joined(separator: ", ")),
                ("Touch & general settings", !state.generalSettings.isEmpty, state.generalSettings.map(\.shortTitle).joined(separator: ", ")),
                ("Button assignment", !caps.assignableKeys.isEmpty, ""),
                ("Voice guidance", caps.voiceGuidance, ""),
                ("Paired device list", caps.pairedDevices, caps.pairedDevices ? "" : "Not shared by this model"),
                ("Playback & volume", caps.playback, ""),
                ("NC Optimizer", caps.ncOptimizer, ""),
            ]
            if state.capabilitiesKnown {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow {
                        Text("Bluetooth address").font(.caption11).foregroundStyle(Theme.secondary)
                        Text(state.uniqueID ?? controller.selectedAddress ?? "—").font(.mono11).foregroundStyle(Theme.text).textSelection(.enabled)
                    }
                    GridRow {
                        Text("Control protocol").font(.caption11).foregroundStyle(Theme.secondary)
                        Text(state.family.map { "MDR \($0.rawValue)" + (state.protocolVersion.map { String(format: " · 0x%04X", $0) } ?? "") } ?? "—")
                            .font(.mono11).foregroundStyle(Theme.text)
                    }
                    GridRow {
                        Text("Functions").font(.caption11).foregroundStyle(Theme.secondary)
                        Text(state.supportFunctions.hex).font(.mono11).foregroundStyle(Theme.text).lineLimit(2).textSelection(.enabled)
                    }
                }
                Divider().overlay(Theme.hairline)
            }
            if !state.capabilitiesKnown {
                Label("Not yet reported",
                      systemImage: "hourglass")
                    .font(.caption11).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(rows, id: \.0) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: row.1 ? "checkmark" : "minus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(row.1 ? Theme.good : Theme.tertiary)
                            .frame(width: 14)
                        Text(row.0).font(.system(size: 12.5, weight: .medium)).foregroundStyle(row.1 ? Theme.text : Theme.tertiary)
                        Spacer(minLength: 8)
                        Text(row.2).font(.caption11).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.tail)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            }
        }
    }
}

struct TrafficCard: View {
    @Environment(HeadphoneController.self) private var controller

    var body: some View {
        Card("Protocol Log", subtitle: "\(controller.traffic.count) frames this session", symbol: "waveform.path.ecg",
             trailing: AnyView(HStack(spacing: 10) {
                Button { copy() } label: { Label("Copy", systemImage: "doc.on.doc").font(.label) }
                Button { export() } label: { Label("Export…", systemImage: "square.and.arrow.up").font(.label) }
             }.buttonStyle(.borderless).foregroundStyle(Theme.accent))) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(controller.traffic.suffix(300)) { entry in
                            Text(entry.line)
                                .font(.mono11)
                                .foregroundStyle(color(entry))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(entry.id)
                        }
                    }
                    .padding(10)
                }
                .frame(height: 300)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.35)))
                .onChange(of: controller.traffic.count) { _, _ in
                    if let last = controller.traffic.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func color(_ entry: TrafficEntry) -> Color {
        switch entry.direction {
        case .tx: Theme.accentSoft
        case .rx: entry.frameType == "ACK" ? Theme.tertiary : Theme.text.opacity(0.85)
        case .note: Theme.secondary
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(controller.trafficLog, forType: .string)
        controller.showToast(.info, "Protocol log copied.")
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Sound Connect log \(Date().formatted(.iso8601.year().month().day())).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try controller.trafficLog.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            controller.showToast(.error, error.localizedDescription)
        }
    }
}

// MARK: - Connection states

/// Full-page states before the headphones are ready. Never shows controls for a device that isn't there.
struct ConnectionStateView: View {
    @Environment(HeadphoneController.self) private var controller

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 20)
            ZStack {
                if case .connecting = controller.phase { spinnerRing }
                else if case .initializing = controller.phase { spinnerRing }
                else if case .reconnecting = controller.phase { spinnerRing }
                ProductImage(modelName: controller.selectedName, colorCode: controller.state.colorCode)
                    .frame(width: 200, height: 200)
                    .saturation(controller.phase.isBusy ? 1 : 0.4)
                    .opacity(controller.phase.isBusy ? 1 : 0.75)
            }
            VStack(spacing: 8) {
                Text(title).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text)
                Text(message).font(.body15).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 440)
            }
            actions
            if controller.knownHeadphones.count > 1 && !controller.phase.isBusy {
                HeadphonePicker()
            }
            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.pagePadding)
    }

    private var spinnerRing: some View {
        Circle()
            .trim(from: 0, to: 0.25)
            .stroke(Theme.accent.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 236, height: 236)
            .modifier(Spin())
    }

    private var title: String {
        switch controller.phase {
        case .starting: "Starting Bluetooth"
        case .permissionNeeded: "Allow Bluetooth"
        case .permissionDenied: "Bluetooth Access Is Off"
        case .bluetoothOff: "Bluetooth Is Off"
        case .noHeadphones: "No Sony Headphones Paired"
        case .waiting(let name): "\(name) Isn't Connected"
        case .connecting(let name): "Connecting to \(name)"
        case .initializing(let name): "Reading \(name)"
        case .reconnecting(let name, _): "Reconnecting to \(name)"
        case .failed(let name, _): "Couldn't Reach \(name)"
        case .connected: ""
        }
    }

    private var message: String {
        switch controller.phase {
        case .starting: "One moment…"
        case .permissionNeeded: "Sound Connect needs Bluetooth access to talk to your headphones. Choose Allow in the system prompt."
        case .permissionDenied: "Turn on Bluetooth for Sound Connect in System Settings › Privacy & Security › Bluetooth."
        case .bluetoothOff: "Turn Bluetooth on to control your headphones."
        case .noHeadphones: "Pair your headphones in System Settings › Bluetooth, then come back."
        case .waiting: "Turn the headphones on, or connect them to this Mac. Sound Connect connects automatically."
        case .connecting: "Connecting to your headphones…"
        case .initializing: "Reading settings from your headphones…"
        case .reconnecting: "The connection dropped. Reconnecting…"
        case .failed: "Make sure they're turned on and nearby, then try again. Details are in Activity."
        case .connected: ""
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch controller.phase {
        case .permissionDenied:
            Button("Open Privacy Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent)
        case .bluetoothOff, .noHeadphones:
            Button("Open Bluetooth Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent)
        case .waiting, .failed:
            if let address = controller.selectedAddress, !controller.isReplay {
                Button {
                    controller.connect(address: address, initiate: true)
                } label: {
                    if case .failed = controller.phase {
                        Label("Try Again", systemImage: "arrow.clockwise")
                    } else {
                        Label("Connect", systemImage: "headphones")
                    }
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(Theme.onAccent)
                .keyboardShortcut("k", modifiers: [.command])
                .help("Connects the headphones to this Mac if needed")
            }
        default:
            EmptyView()
        }
    }
}

struct HeadphonePicker: View {
    @Environment(HeadphoneController.self) private var controller

    var body: some View {
        VStack(spacing: 6) {
            ForEach(controller.knownHeadphones) { known in
                Button {
                    controller.connect(address: known.address, initiate: true)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "headphones").foregroundStyle(known.isConnected ? Theme.accent : Theme.secondary)
                        Text(known.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                        Spacer()
                        Text(known.isConnected ? "Connected to this Mac" : "Paired").font(.caption11).foregroundStyle(Theme.secondary)
                    }
                    .padding(.horizontal, 14).frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(known.address == controller.selectedAddress ? Theme.cardRaised : Theme.card))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 380)
    }
}

private struct Spin: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle = 0.0

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(angle))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { angle = 360 }
            }
    }
}
