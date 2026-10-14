import SwiftUI

enum AppPage: String, CaseIterable, Identifiable {
    case myDevice, sound, scenes, settings, activity
    var id: String { rawValue }

    var title: String {
        switch self {
        case .myDevice: "My Device"
        case .sound: "Sound"
        case .scenes: "Scenes"
        case .settings: "Settings"
        case .activity: "Activity"
        }
    }

    var symbol: String {
        switch self {
        case .myDevice: "headphones"
        case .sound: "slider.vertical.3"
        case .scenes: "figure.walk"
        case .settings: "gearshape"
        case .activity: "waveform.path.ecg.rectangle"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .myDevice: "1"
        case .sound: "2"
        case .scenes: "3"
        case .settings: "4"
        case .activity: "5"
        }
    }

    var needsConnection: Bool { self == .myDevice || self == .sound || self == .settings }
}

@MainActor
@Observable
final class Navigation {
    var page: AppPage = .myDevice
}

struct RootView: View {
    @Environment(HeadphoneController.self) private var controller
    @Environment(Navigation.self) private var navigation

    var body: some View {
        @Bindable var navigation = navigation
        HStack(spacing: 0) {
            Sidebar(page: $navigation.page)
                .frame(width: 228)
            Rectangle().fill(Color.black.opacity(0.45)).frame(width: 1)
            VStack(spacing: 0) {
                if controller.isReplay {
                    ReplayNotice()
                }
                // The canvas is a background, not a ZStack sibling: an ignoresSafeArea sibling would enlarge the
                // stack and shift centered content up under the title bar / replay banner.
                content(for: navigation.page)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.canvas.ignoresSafeArea())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 920, minHeight: 640)
        .background(Theme.canvasBottom)
        .overlay(alignment: .bottom) { ToastView() }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .alert(controller.state.alert?.title ?? "",
               isPresented: Binding(get: { controller.state.alert != nil }, set: { if !$0 { controller.answerAlert(accept: false) } }),
               presenting: controller.state.alert) { alert in
            if alert.requiresAnswer {
                Button("Continue") { controller.answerAlert(accept: true) }
                Button("Cancel", role: .cancel) { controller.answerAlert(accept: false) }
            } else {
                Button("OK") { controller.answerAlert(accept: true) }
            }
        } message: { alert in
            Text(alert.message)
        }
    }

    @ViewBuilder
    private func content(for page: AppPage) -> some View {
        if page.needsConnection && !controller.isConnected {
            ConnectionStateView()
        } else {
            switch page {
            case .myDevice: MyDeviceView(page: Binding(get: { navigation.page }, set: { navigation.page = $0 }))
            case .sound: SoundView()
            case .scenes: ScenesView()
            case .settings: DeviceSettingsView()
            case .activity: ActivityView()
            }
        }
    }
}

struct Sidebar: View {
    @Environment(HeadphoneController.self) private var controller
    @Environment(SceneStore.self) private var scenes
    @Binding var page: AppPage

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the traffic lights (hidden title bar).
            Color.clear.frame(height: 40)

            DeviceMiniCard()
                .padding(.horizontal, 14)
                .padding(.bottom, 18)

            VStack(spacing: 3) {
                ForEach(AppPage.allCases) { item in
                    SidebarItem(page: item, selected: page == item) { page = item }
                }
            }
            .padding(.horizontal, 10)

            if !scenes.scenes.isEmpty {
                Text("QUICK SCENES")
                    .font(.system(size: 10, weight: .semibold)).tracking(0.9)
                    .foregroundStyle(Theme.tertiary)
                    .padding(.horizontal, 22).padding(.top, 26).padding(.bottom, 8)
                VStack(spacing: 2) {
                    ForEach(scenes.scenes.prefix(5)) { scene in
                        let applied = scenes.isApplied(scene)
                        Button {
                            Task { await scenes.apply(scene.id) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: scene.symbol).font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(scene.tint.color).frame(width: 18)
                                Text(scene.name).font(.system(size: 12.5)).foregroundStyle(Theme.text.opacity(0.9)).lineLimit(1)
                                Spacer()
                                if scenes.runningSceneID == scene.id {
                                    ProgressView().controlSize(.mini)
                                } else if applied {
                                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.secondary)
                                }
                            }
                            .padding(.horizontal, 12).frame(height: 28)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!scenes.canApply(scene))
                        .opacity(controller.canWrite ? 1 : 0.5)
                        .help(applied ? "Applied" : "Apply “\(scene.name)”")
                        .accessibilityLabel(applied ? "Scene \(scene.name), applied" : "Apply scene \(scene.name)")
                    }
                }
                .padding(.horizontal, 10)
            }

            Spacer()
            ConnectionFooter()
                .padding(14)
        }
        .background(Theme.sidebar.ignoresSafeArea())
    }
}

struct SidebarItem: View {
    let page: AppPage
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: page.symbol)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(selected ? Theme.accent : Theme.secondary)
                    .frame(width: 20)
                Text(page.title)
                    .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.text : Theme.text.opacity(0.78))
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Theme.accent.opacity(0.13) : (hovering ? Color.white.opacity(0.04) : .clear))
            )
            .overlay(alignment: .leading) {
                if selected {
                    Capsule().fill(Theme.accent).frame(width: 3, height: 16).offset(x: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(page.title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

struct DeviceMiniCard: View {
    @Environment(HeadphoneController.self) private var controller

    var body: some View {
        let state = controller.state
        HStack(spacing: 11) {
            ProductImage(modelName: state.modelName ?? controller.selectedName, colorCode: state.colorCode, glow: false)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.modelName ?? controller.selectedName)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                HStack(spacing: 6) {
                    StatusDot(color: statusColor, pulsing: controller.phase.isBusy)
                    Text(statusText).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        if controller.isReplay { return Theme.warning }
        return switch controller.phase {
        case .connected: Theme.good
        case .connecting, .initializing, .reconnecting, .starting: Theme.accent
        case .failed, .permissionDenied: Theme.danger
        default: Theme.tertiary
        }
    }

    private var statusText: String {
        if controller.isReplay { return "Replay · read-only" }
        switch controller.phase {
        case .connected:
            if let level = controller.state.battery.headlineLevel { return "Connected · \(level)%" }
            return "Connected"
        case .connecting, .initializing: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .waiting: return "Not connected"
        case .failed: return "Connection problem"
        case .permissionNeeded, .permissionDenied: return "Needs Bluetooth access"
        case .bluetoothOff: return "Bluetooth is off"
        case .noHeadphones: return "No headphones"
        case .starting: return "Starting…"
        }
    }
}

struct ConnectionFooter: View {
    @Environment(HeadphoneController.self) private var controller

    var body: some View {
        HStack(spacing: 8) {
            if controller.isReplay {
                Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 10)).foregroundStyle(Theme.warning)
                Text("Recorded session — not live").font(.caption11).foregroundStyle(Theme.warning)
                Spacer()
            } else if controller.isConnected {
                if controller.hasPendingWrites {
                    ProgressView().controlSize(.mini)
                    Text("Applying…").font(.caption11).foregroundStyle(Theme.secondary)
                } else {
                    Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Theme.tertiary)
                    Text("Local Bluetooth").font(.caption11).foregroundStyle(Theme.tertiary)
                }
                Spacer()
                Button { controller.refreshStatus() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.secondary)
                .help("Refresh battery and status (⌘R)")
                .accessibilityLabel("Refresh")
            } else if let address = controller.selectedAddress, !controller.phase.isBusy {
                Button {
                    controller.connect(address: address, initiate: true)
                } label: {
                    Label("Connect", systemImage: "headphones").font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .foregroundStyle(Theme.onAccent)
            }
        }
    }
}

struct ToastView: View {
    @Environment(HeadphoneController.self) private var controller
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let toast = controller.toast {
                HStack(spacing: 10) {
                    Image(systemName: symbol(toast.style)).foregroundStyle(color(toast.style))
                    Text(toast.message).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16).padding(.vertical, 11)
                .frame(maxWidth: 560)
                .background(
                    Capsule(style: .continuous).fill(Theme.cardRaised)
                        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.08)))
                        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
                )
                .padding(.bottom, 22)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .padding(.leading, 228)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: controller.toast)
    }

    private func symbol(_ style: Toast.Style) -> String {
        switch style {
        case .info: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private func color(_ style: Toast.Style) -> Color {
        switch style {
        case .info: Theme.good
        case .warning: Theme.warning
        case .error: Theme.danger
        }
    }
}

/// Persistent, unmissable marker for developer replay mode. Replay shows frames recorded from real hardware;
/// it is never live and nothing can be sent.
struct ReplayNotice: View {
    @Environment(HeadphoneController.self) private var controller
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "play.rectangle.on.rectangle.fill")
                .foregroundStyle(Theme.onAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text("READ-ONLY REPLAY — NOT LIVE")
                    .font(.system(size: compact ? 10.5 : 11.5, weight: .bold)).tracking(0.6)
                if !compact {
                    Text("Showing frames recorded from real headphones (\(controller.replaySource ?? "file")\(controller.lastRefresh.map { ", " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")). Changes, scenes and automations are disabled; nothing is sent over Bluetooth.")
                        .font(.system(size: 11))
                        .lineLimit(2)
                }
            }
            .foregroundStyle(Theme.onAccent)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, compact ? 10 : 18)
        .padding(.vertical, compact ? 7 : 9)
        .frame(maxWidth: .infinity)
        .background(compact ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(Theme.warning.gradient))
        .clipShape(RoundedRectangle(cornerRadius: compact ? 8 : 0, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Read-only replay of a recorded session. Not live. Nothing is sent to headphones.")
    }
}
