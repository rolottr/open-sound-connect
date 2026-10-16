import SwiftUI

/// Floating, dismissible cards in the main window's bottom-right corner. They stack, newest concern on top.
struct OfferStack: View {
    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            UpdateOffer()
            LoginItemOffer()
        }
        .padding(22)
    }
}

/// The shared look: accent icon, title, message and a right-aligned row of buttons.
struct FloatingOffer<Buttons: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Theme.accent))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(message).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                buttons
            }
            .controlSize(.regular)
        }
        .padding(16)
        .frame(width: 360)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.cardRaised)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
                .shadow(color: .black.opacity(0.45), radius: 22, y: 10)
        )
        .accessibilityElement(children: .contain)
    }
}

private struct OfferTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let shown: Bool

    func body(content: Content) -> some View {
        content
            .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.85), value: shown)
    }
}

private struct PrimaryOfferButton: ViewModifier {
    func body(content: Content) -> some View {
        content.buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(Theme.onAccent)
    }
}

/// A one-time, dismissible offer to open at login, shown a moment after the first connection — once the app has
/// proved useful — rather than on first launch. The same choice lives in Settings.
struct LoginItemOffer: View {
    @Environment(LoginItem.self) private var loginItem
    @Environment(HeadphoneController.self) private var controller
    @State private var visible = false

    var body: some View {
        let shown = visible && loginItem.shouldOffer
        ZStack {
            if shown {
                FloatingOffer(symbol: "power", title: "Open Sound Connect at login?",
                              message: "It starts quietly in the menu bar, so your controls and scene automations are ready when you are. You can change this in Settings.") {
                    Button("Not Now") { loginItem.answerOffer() }
                    Button("Open at Login") { accept() }.modifier(PrimaryOfferButton())
                }
            }
        }
        .modifier(OfferTransition(shown: shown))
        .task(id: controller.isConnected) {
            guard controller.isConnected, loginItem.shouldOffer, !controller.isReplay else { return }
            // Let the first connection settle before asking for anything.
            try? await Task.sleep(for: .seconds(3))
            visible = true
        }
    }

    private func accept() {
        loginItem.setEnabled(true)
        switch loginItem.status {
        case .enabled:
            controller.showToast(.info, "Sound Connect will open at login.")
        case .requiresApproval:
            controller.showToast(.warning, "Allow Sound Connect in System Settings to finish turning on Open at Login.")
            loginItem.openSystemSettings()
        case .disabled, .unavailable:
            controller.showToast(.error, loginItem.error ?? "Open at Login isn’t available for this copy of Sound Connect.")
        }
    }
}

/// Shown when an automatic check finds a newer release.
struct UpdateOffer: View {
    @Environment(UpdateChecker.self) private var updates

    var body: some View {
        let release = updates.offered
        ZStack {
            if let release {
                FloatingOffer(symbol: "arrow.down.circle", title: "Sound Connect \(release.version) is available",
                              message: "You have \(updates.currentVersion). Download it from the GitHub release page, then replace the app in your Applications folder.") {
                    Button("Skip This Version") { updates.skip(release) }
                    Button("Later") { updates.dismissOffer() }
                    Button("Download") {
                        updates.download(release)
                        updates.dismissOffer()
                    }
                    .modifier(PrimaryOfferButton())
                }
            }
        }
        .modifier(OfferTransition(shown: release != nil))
    }
}
