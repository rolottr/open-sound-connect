import AppKit
import Observation
import ServiceManagement

/// Open at Login, backed by `SMAppService.mainApp`, plus the one-time offer shown after the first connection.
@MainActor
@Observable
final class LoginItem {
    enum Status: Equatable {
        case enabled, requiresApproval, disabled, unavailable
    }

    private(set) var status: Status = .disabled
    private(set) var error: String?
    /// Set once the person answers the offer either way (or turns the setting on themselves); it is never shown again.
    private(set) var offerAnswered = UserDefaults.standard.bool(forKey: LoginItem.offerAnsweredKey)

    private static let offerAnsweredKey = "loginItemOfferAnswered"

    init() { refresh() }

    var isEnabled: Bool { status == .enabled }

    /// The offer is for people who have already got something working; developer and snapshot runs never see it.
    var shouldOffer: Bool {
        !offerAnswered && status == .disabled && !LaunchContext.isDeveloperRun
    }

    func refresh() {
        status = switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .disabled
        case .notFound: .unavailable
        @unknown default: .disabled
        }
    }

    func setEnabled(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
        if on { answerOffer() }
    }

    func answerOffer() {
        offerAnswered = true
        UserDefaults.standard.set(true, forKey: Self.offerAnsweredKey)
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// How this process was started.
@MainActor
enum LaunchContext {
    /// True when macOS opened the app from the Open at Login list. Only meaningful while
    /// `applicationDidFinishLaunching` runs, because that is when the open-application event is current.
    static func wasLaunchedAtLogin() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// `--background` starts the app the way a login launch does: menu bar only, no window.
    static var requestsBackground: Bool { CommandLine.arguments.contains("--background") }

    static var isDeveloperRun: Bool {
        let arguments = CommandLine.arguments
        return arguments.contains("--replay") || arguments.contains("--snapshot-dir")
    }
}
